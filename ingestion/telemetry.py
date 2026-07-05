"""The one central spot that owns trace routing.

Instrument once with OpenTelemetry; fan out to two sinks from a single TracerProvider:

  - Postgres (`spans` table) — the full-fidelity OTEL trace store. This is the portable
    record: raw spans in, so a later move to Langfuse/Phoenix is a replay, not a reshape.
    Swapping providers later == swapping the exporter here, nothing in app code changes.
  - App Insights — the ops skeleton only. Content-bearing `gen_ai.content.*` events are
    stripped on the way out (see RedactingSpanExporter), so sensitive prompt/completion/
    retrieval text never lands in the shared Log Analytics workspace.

Prompt/completion/retrieval content is captured only when `settings.trace_content` is on
(opt-in), and even then only the Postgres sink keeps it.
"""
from __future__ import annotations
import json
import logging
from datetime import datetime, timezone
from typing import Sequence

import psycopg
from azure.identity import DefaultAzureCredential
from azure.monitor.opentelemetry.exporter import AzureMonitorTraceExporter
from opentelemetry import trace
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SpanExporter, SpanExportResult
from psycopg.types.json import Json

from config import settings

logger = logging.getLogger(__name__)

# Content lives in span events under this prefix so a single filter can route it: kept by the
# Postgres sink, dropped before App Insights. (Aligned with the OTEL GenAI content convention.)
CONTENT_EVENT_PREFIX = "gen_ai.content"

SPANS_DDL = """
CREATE TABLE IF NOT EXISTS spans (
    trace_id       TEXT             NOT NULL,
    span_id        TEXT             NOT NULL,
    parent_span_id TEXT,
    name           TEXT             NOT NULL,
    kind           TEXT,
    service_name   TEXT,
    start_time     TIMESTAMPTZ      NOT NULL,
    end_time       TIMESTAMPTZ,
    duration_ms    DOUBLE PRECISION,
    status_code    TEXT,
    attributes     JSONB,
    events         JSONB,
    PRIMARY KEY (trace_id, span_id)
);
CREATE INDEX IF NOT EXISTS ix_spans_trace ON spans (trace_id);
CREATE INDEX IF NOT EXISTS ix_spans_start ON spans (start_time DESC);
"""

INSERT = """
INSERT INTO spans (trace_id, span_id, parent_span_id, name, kind, service_name,
                   start_time, end_time, duration_ms, status_code, attributes, events)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (trace_id, span_id) DO NOTHING
"""


def _ns_to_dt(ns: int | None) -> datetime | None:
    return datetime.fromtimestamp(ns / 1e9, tz=timezone.utc) if ns else None


class PostgresSpanExporter(SpanExporter):
    """Persist raw OTEL spans to the `spans` table (keyless, via the app's managed identity).

    Runs on the BatchSpanProcessor's background thread, so DB latency never touches the request
    path; failures are logged and dropped, never raised. Owns its schema (lazy CREATE on first
    export) so it works for whichever deployable — app or ingestion — writes a span first.
    """

    def __init__(self) -> None:
        self._cred = DefaultAzureCredential()
        self._ready = False

    def _connect(self) -> psycopg.Connection:
        scope = "https://ossrdbms-aad.database.windows.net/.default"
        token = self._cred.get_token(scope).token
        return psycopg.connect(
            host=settings.pg_host, dbname=settings.pg_db, user=settings.pg_user,
            password=token, sslmode="require",
        )

    def _row(self, span: ReadableSpan) -> tuple:
        ctx = span.get_span_context()
        events = [
            {"name": e.name, "timestamp": _ns_to_dt(e.timestamp).isoformat() if e.timestamp else None,
             "attributes": dict(e.attributes or {})}
            for e in span.events
        ]
        start, end = _ns_to_dt(span.start_time), _ns_to_dt(span.end_time)
        return (
            format(ctx.trace_id, "032x"),
            format(ctx.span_id, "016x"),
            format(span.parent.span_id, "016x") if span.parent else None,
            span.name,
            span.kind.name,
            span.resource.attributes.get("service.name"),
            start, end,
            (span.end_time - span.start_time) / 1e6 if span.start_time and span.end_time else None,
            span.status.status_code.name,
            Json(dict(span.attributes or {})),
            Json(events),
        )

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        try:
            with self._connect() as conn, conn.cursor() as cur:
                if not self._ready:
                    cur.execute(SPANS_DDL)
                    self._ready = True
                cur.executemany(INSERT, [self._row(s) for s in spans])
            return SpanExportResult.SUCCESS
        except Exception:
            logger.exception("failed to export %d span(s) to postgres", len(spans))
            return SpanExportResult.FAILURE

    def force_flush(self, timeout_millis: int = 30000) -> bool:
        return True


class _SkeletonSpan:
    """Read-only view of a span with content events hidden — everything else delegated."""

    def __init__(self, span: ReadableSpan) -> None:
        self._span = span

    @property
    def events(self):
        return tuple(e for e in self._span.events if not e.name.startswith(CONTENT_EVENT_PREFIX))

    def __getattr__(self, name):
        return getattr(self._span, name)


class RedactingSpanExporter(SpanExporter):
    """Wrap an exporter, stripping `gen_ai.content.*` events so content never leaves for App Insights."""

    def __init__(self, inner: SpanExporter) -> None:
        self._inner = inner

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        return self._inner.export([_SkeletonSpan(s) for s in spans])

    def shutdown(self) -> None:
        self._inner.shutdown()

    def force_flush(self, timeout_millis: int = 30000) -> bool:
        return self._inner.force_flush(timeout_millis)


def setup_telemetry(tracer_name: str) -> trace.Tracer:
    """Build the TracerProvider, wire both sinks, instrument httpx, and return the tracer.

    service.name (App Insights cloud role name) is read from OTEL_SERVICE_NAME in the environment.
    """
    provider = TracerProvider(resource=Resource.create())

    # Full-fidelity OTEL spans (incl. content when captured) → the portable trace store.
    provider.add_span_processor(BatchSpanProcessor(PostgresSpanExporter()))

    # Ops skeleton → App Insights, with content events redacted out.
    if settings.applicationinsights_connection_string:
        azure = AzureMonitorTraceExporter(connection_string=settings.applicationinsights_connection_string)
        provider.add_span_processor(BatchSpanProcessor(RedactingSpanExporter(azure)))

    trace.set_tracer_provider(provider)
    HTTPXClientInstrumentor().instrument()
    return trace.get_tracer(tracer_name)


def record_content(name: str, payload) -> None:
    """Attach prompt/retrieval/completion content to the current span — only when opted in.

    Emitted as a `gen_ai.content.*` event: kept by Postgres, stripped before App Insights.
    """
    if not settings.trace_content:
        return
    trace.get_current_span().add_event(name, {"content": json.dumps(payload, default=str)})
