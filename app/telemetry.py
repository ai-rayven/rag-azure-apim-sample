"""The one central spot that owns trace routing.

Instrument once with OpenTelemetry; export to a single sink — App Insights (the shared Log
Analytics workspace).
"""
from __future__ import annotations
import json

from azure.monitor.opentelemetry.exporter import AzureMonitorTraceExporter
from opentelemetry import trace
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

from config import settings


def setup_telemetry(tracer_name: str) -> trace.Tracer:
    """Build the TracerProvider, wire the App Insights sink, instrument httpx.

    service.name (App Insights cloud role name) is read from OTEL_SERVICE_NAME in the environment.
    With no App Insights connection string (e.g. local dev) nothing is exported at all.
    """
    provider = TracerProvider(resource=Resource.create())

    if settings.applicationinsights_connection_string:
        azure = AzureMonitorTraceExporter(connection_string=settings.applicationinsights_connection_string)
        provider.add_span_processor(BatchSpanProcessor(azure))

    trace.set_tracer_provider(provider)
    HTTPXClientInstrumentor().instrument()
    return trace.get_tracer(tracer_name)


def record_content(name: str, payload) -> None:
    """Attach NON-PII content to the current span as a `gen_ai.content.*` event.

    `payload` is JSON-serialized into the event. Only use this for content we are willing to see in
    App Insights verbatim — e.g. the retrieved corpus docs. PII/PHI-bearing conversation text (the
    user's message, the model's completion, chat history) must NOT be recorded here; it belongs only
    in the Cosmos history store.
    """
    trace.get_current_span().add_event(name, {"content": json.dumps(payload, default=str)})
