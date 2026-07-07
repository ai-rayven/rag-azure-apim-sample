"""The one central spot that owns trace routing and content de-identification.

Instrument once with OpenTelemetry; export to a single sink — App Insights (the shared Log
Analytics workspace). A /chat turn captures its prompt/retrieval/completion as `gen_ai.content.*`
span events. Only the parts we explicitly mark are PII-scrubbed on the way out; everything else is
exported as-is.

Today the only marked field is the **user's own message** — the one bit of unpredictable, user-authored
input. It's scrubbed by Azure AI Language (NER-based, `syntheticReplacement` policy: PII is swapped for
realistic fakes, `John Doe` → `Sam Johnson`) using the app's managed identity (keyless). The retrieved
documents are *your* corpus (de-identify those at ingestion, not here), and the system prompt and prior
history pass through unchanged — see `docs/observability.md`.

`record_content(payload, scrub=(...))` names which top-level payload keys to scrub; the exporter
scrubs just those and re-serializes the rest verbatim. Fail-closed: if the Language call can't run,
the marked field is **withheld** (replaced with a marker), never exported raw.

Scrubbing runs inside the exporter, on the BatchSpanProcessor's background thread, so the Azure
Language round-trip never touches the request path.
"""
from __future__ import annotations
import json
import logging
from typing import Sequence

import httpx
from azure.identity import DefaultAzureCredential
from azure.monitor.opentelemetry.exporter import AzureMonitorTraceExporter
from opentelemetry import trace
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.utils import suppress_instrumentation
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import Event, ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SpanExporter, SpanExportResult

from config import settings

logger = logging.getLogger(__name__)

# Content lives in span events under this prefix (aligned with the OTEL GenAI convention). Each event
# names the payload keys to scrub in a sibling `scrub_keys` attribute; the rest of the payload passes
# through. Emitted in place of a marked field whenever the scrub can't run — fail closed.
CONTENT_EVENT_PREFIX = "gen_ai.content"
SCRUB_KEYS_ATTR = "scrub_keys"
WITHHELD = "[content withheld: PII redaction unavailable]"

# Azure Language: keyless (Entra token) call to the analyze-text endpoint, using the preview
# syntheticReplacement policy (realistic fake values), so we pin the preview API version.
#
# A synchronous PII request is capped at 5,120 characters/document and 5 documents/request, so
# `redact()` splits long input into <=5,000-char chunks (headroom under 5,120), sends them 5 at a
# time, and stitches the redacted pieces back together. We only scrub the user's own message now —
# usually short — but a user can paste something large, so the chunking still earns its keep.
_LANG_API_VERSION = "2025-11-15-preview"
_LANG_SCOPE = "https://cognitiveservices.azure.com/.default"
_REDACTION_POLICY = "syntheticReplacement"
_LANG_MAX_DOC = 5_000  # chars/chunk, under the 5,120 per-document limit
_LANG_BATCH = 5        # chunks/request, the PII per-request document cap


class PiiScrubber:
    """Redact PII from text with Azure AI Language (keyless, via managed identity).

    NER-based, so it catches contextual PII (names, addresses) that patterns can't; `syntheticReplacement`
    swaps each entity for a realistic random stand-in. The HTTP client + credential are built lazily on
    first use and reused. Returns None on any failure (throttle, outage, misconfig, over-length, or no
    endpoint) so the caller can fail closed rather than leak raw text. Runs on the exporter's background
    thread, so its latency never reaches a request.
    """

    def __init__(self, endpoint: str | None) -> None:
        self._endpoint = endpoint.rstrip("/") if endpoint else None
        self._cred: DefaultAzureCredential | None = None
        self._http: httpx.Client | None = None

    def _ensure(self) -> bool:
        if not self._endpoint:
            return False
        if self._http is None:
            self._cred = DefaultAzureCredential()
            self._http = httpx.Client(timeout=10.0)
        return True

    def _redact_batch(self, texts: list[str], token: str) -> list[str] | None:
        body = {
            "kind": "PiiEntityRecognition",
            "parameters": {
                "modelVersion": "latest",
                "redactionPolicies": [{"policyKind": _REDACTION_POLICY}],
            },
            "analysisInput": {
                "documents": [{"id": str(i), "language": "en", "text": t} for i, t in enumerate(texts)]
            },
        }
        # suppress_instrumentation: this POST runs on the exporter thread; without it the globally
        # instrumented httpx client would emit a dependency span for every scrub call (noise, and it
        # would loop back through this exporter).
        with suppress_instrumentation():
            resp = self._http.post(
                f"{self._endpoint}/language/:analyze-text",
                params={"api-version": _LANG_API_VERSION},
                headers={"Authorization": f"Bearer {token}"},
                json=body,
            )
        resp.raise_for_status()
        results = resp.json()["results"]
        if results.get("errors"):
            return None
        by_id = {d["id"]: d.get("redactedText") for d in results["documents"]}
        out = [by_id.get(str(i)) for i in range(len(texts))]
        return out if all(r is not None for r in out) else None  # fail closed on any missing doc

    def redact(self, text: str) -> str | None:
        if not self._ensure():
            return None
        chunks = [text[i:i + _LANG_MAX_DOC] for i in range(0, len(text), _LANG_MAX_DOC)] or [""]
        try:
            token = self._cred.get_token(_LANG_SCOPE).token  # DefaultAzureCredential caches/refreshes
            out: list[str] = []
            for start in range(0, len(chunks), _LANG_BATCH):
                redacted = self._redact_batch(chunks[start:start + _LANG_BATCH], token)
                if redacted is None:
                    return None
                out.extend(redacted)
            return "".join(out)
        except Exception:
            logger.warning("Azure Language PII scrub failed; content will be withheld", exc_info=True)
            return None


class _ScrubbedSpan:
    """Read-only view of a span whose marked `gen_ai.content.*` payload keys are de-identified.

    Everything else — other events, timings, tokens, status — is delegated unchanged.
    """

    def __init__(self, span: ReadableSpan, scrub_text) -> None:
        self._span = span
        self._scrub_text = scrub_text

    @property
    def events(self):
        out = []
        for e in self._span.events:
            keys = self._marked_keys(e)
            if keys is not None and "content" in e.attributes:
                attrs = dict(e.attributes)
                del attrs[SCRUB_KEYS_ATTR]  # internal routing marker — don't export it
                attrs["content"] = self._scrub_keys(attrs["content"], keys)
                out.append(Event(e.name, attrs, timestamp=e.timestamp))
            else:
                out.append(e)
        return tuple(out)

    @staticmethod
    def _marked_keys(e) -> list | None:
        if e.name.startswith(CONTENT_EVENT_PREFIX) and e.attributes and e.attributes.get(SCRUB_KEYS_ATTR):
            try:
                return json.loads(e.attributes[SCRUB_KEYS_ATTR])
            except json.JSONDecodeError:
                return None
        return None

    def _scrub_keys(self, content_json: str, keys: list) -> str:
        try:
            data = json.loads(content_json)
        except json.JSONDecodeError:
            return content_json
        if not isinstance(data, dict):
            return content_json
        for k in keys:
            v = data.get(k)
            if isinstance(v, str):
                data[k] = self._scrub_text(v)
        return json.dumps(data)

    def __getattr__(self, name):
        return getattr(self._span, name)


class RedactingSpanExporter(SpanExporter):
    """Wrap an exporter; de-identify the marked `gen_ai.content.*` payload keys before they leave.

    Redaction is done by Azure AI Language (see PiiScrubber). Fail-closed: if the scrub can't run,
    the marked field is withheld rather than exported raw. Unmarked content is exported as-is.
    """

    def __init__(self, inner: SpanExporter, scrubber: PiiScrubber) -> None:
        self._inner = inner
        self._scrubber = scrubber

    def _scrub_text(self, text: str) -> str:
        redacted = self._scrubber.redact(text)  # Azure Language NER, or None on any failure
        return redacted if redacted is not None else WITHHELD

    @staticmethod
    def _has_marked_event(span: ReadableSpan) -> bool:
        return any(e.attributes and e.attributes.get(SCRUB_KEYS_ATTR) for e in span.events)

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        redacted = [
            _ScrubbedSpan(s, self._scrub_text) if self._has_marked_event(s) else s
            for s in spans
        ]
        return self._inner.export(redacted)

    def shutdown(self) -> None:
        self._inner.shutdown()

    def force_flush(self, timeout_millis: int = 30000) -> bool:
        return self._inner.force_flush(timeout_millis)


def setup_telemetry(tracer_name: str) -> trace.Tracer:
    """Build the TracerProvider, wire the (redacting) App Insights sink, instrument httpx.

    service.name (App Insights cloud role name) is read from OTEL_SERVICE_NAME in the environment.
    With no App Insights connection string (e.g. local dev) nothing is exported at all.
    """
    provider = TracerProvider(resource=Resource.create())

    if settings.applicationinsights_connection_string:
        azure = AzureMonitorTraceExporter(connection_string=settings.applicationinsights_connection_string)
        scrubber = PiiScrubber(settings.language_endpoint)
        provider.add_span_processor(BatchSpanProcessor(RedactingSpanExporter(azure, scrubber)))

    trace.set_tracer_provider(provider)
    HTTPXClientInstrumentor().instrument()
    return trace.get_tracer(tracer_name)


def record_content(name: str, payload, *, scrub: tuple[str, ...] = ()) -> None:
    """Attach content to the current span as a `gen_ai.content.*` event.

    `payload` is JSON-serialized into the event. `scrub` names the top-level payload keys whose string
    values must be PII-scrubbed (by Azure AI Language, in the exporter) before export — everything else
    in the payload is exported verbatim. Pass a dict payload when using `scrub`.
    """
    attrs = {"content": json.dumps(payload, default=str)}
    if scrub:
        attrs[SCRUB_KEYS_ATTR] = json.dumps(list(scrub))
    trace.get_current_span().add_event(name, attrs)
