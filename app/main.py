import json
import uuid
from collections.abc import Iterator
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from config import settings
from domain import ChatRequest
from services.chat import ChatService
from services.embeddings import Embedder
from services.history import HistoryStore
from services.search import SearchIndex
from telemetry import record_content, setup_telemetry


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Run one-time startup work: ensure the history schema exists (the app is its Entra admin)."""
    history.migrate()
    yield

history = HistoryStore()
embedder = Embedder()
chat_service = ChatService(history)
index = SearchIndex()

tracer = setup_telemetry("rag-chatbot")
app = FastAPI(title="RAG Chatbot Sample", lifespan=lifespan)
FastAPIInstrumentor().instrument_app(app)

app.mount("/static", StaticFiles(directory="static"), name="static")


def _sse(event: str, data) -> str:
    """One server-sent event. Data is JSON-encoded so multi-line token text can't break framing."""
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


def _retrieve(message: str):
    """The RAG retrieve step under its own span. Shared by the streaming and non-streaming paths."""
    with tracer.start_as_current_span("retrieve") as ret:
        qvec = embedder.embed([message])[0]
        hits = index.vector_search(qvec, k=3)
        ret.set_attribute("retrieval.hits", len(hits))
        record_content("gen_ai.content.retrieval",
                       [{"title": h.title, "content": h.content, "url": h.url} for h in hits])
    return hits


def _set_llm_attrs(span, completion) -> None:
    span.set_attribute("gen_ai.system", "azure.ai.openai")
    span.set_attribute("gen_ai.request.model", completion.model)
    span.set_attribute("gen_ai.usage.input_tokens", completion.input_tokens)
    span.set_attribute("gen_ai.usage.output_tokens", completion.output_tokens)


@app.post("/chat")
def chat(req: ChatRequest):
    """Answer one chat turn, RAG-style, under a single trace.

    ENABLE_STREAMING flips the transport: on -> tokens streamed to the client over SSE; off -> one
    JSON blob (the gateway is then on a tier that can't hold a long-lived streaming connection).
    """
    session_id = req.session_id or str(uuid.uuid4())

    if settings.enable_streaming:
        return StreamingResponse(_chat_stream(req, session_id), media_type="text/event-stream")

    with tracer.start_as_current_span("chat") as root:
        root.set_attribute("session.id", session_id)
        trace_id = format(root.get_span_context().trace_id, "032x")
        hits = _retrieve(req.message)
        with tracer.start_as_current_span("llm-call") as span:
            completion = chat_service.respond(session_id, req.message, hits, trace_id)
            _set_llm_attrs(span, completion)

    return {"answer": completion.answer, "trace_id": trace_id, "session_id": session_id,
            "sources": [h.title for h in hits]}


def _chat_stream(req: ChatRequest, session_id: str) -> Iterator[str]:
    """SSE body: leading `meta` event, then one `token` event per delta, then `done`.

    The trace spans live inside this generator, not the handler, so they stay open for the whole
    stream — FastAPI runs it while the body is sent, and `gen_ai.usage.*` is set from the final chunk.
    """
    with tracer.start_as_current_span("chat") as root:
        root.set_attribute("session.id", session_id)
        trace_id = format(root.get_span_context().trace_id, "032x")
        hits = _retrieve(req.message)

        # Lead with the metadata the UI needs before any token arrives.
        yield _sse("meta", {"session_id": session_id, "trace_id": trace_id,
                            "sources": [h.title for h in hits]})

        with tracer.start_as_current_span("llm-call") as span:
            stream = chat_service.respond_stream(session_id, req.message, hits, trace_id)
            while True:
                try:
                    yield _sse("token", next(stream))
                except StopIteration as done:
                    completion = done.value  # the finished Completion (answer + usage)
                    break
            _set_llm_attrs(span, completion)

        yield _sse("done", {})

@app.get("/")
def index_page():
    """Serve the single-page chat UI."""
    return FileResponse("static/index.html")
