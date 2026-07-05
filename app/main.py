import uuid
from contextlib import asynccontextmanager
from azure.monitor.opentelemetry import configure_azure_monitor
from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

from config import settings
from domain import ChatRequest
from services.chat import ChatService
from services.embeddings import Embedder
from services.history import HistoryStore
from services.search import SearchIndex


def setup_observability() -> trace.Tracer:
    if settings.applicationinsights_connection_string:
        configure_azure_monitor(connection_string=settings.applicationinsights_connection_string)
    HTTPXClientInstrumentor().instrument()
    return trace.get_tracer("rag-chatbot")

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Run one-time startup work: ensure the history schema exists (the app is its Entra admin)."""
    history.migrate()
    yield

history = HistoryStore()
embedder = Embedder()
chat_service = ChatService(history)
index = SearchIndex()

tracer = setup_observability()
app = FastAPI(title="RAG Chatbot Sample", lifespan=lifespan)
FastAPIInstrumentor().instrument_app(app)

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.post("/chat")
def chat(req: ChatRequest):
    """Answer one chat turn, RAG-style, under a single trace. """
    session_id = req.session_id or str(uuid.uuid4())

    with tracer.start_as_current_span("chat") as root:
        root.set_attribute("session.id", session_id)
        trace_id = format(root.get_span_context().trace_id, "032x")

        with tracer.start_as_current_span("retrieve") as ret:
            qvec = embedder.embed([req.message])[0]
            hits = index.vector_search(qvec, k=3)
            ret.set_attribute("retrieval.hits", len(hits))

        with tracer.start_as_current_span("llm-call") as span:
            completion = chat_service.respond(session_id, req.message, hits, trace_id)
            span.set_attribute("gen_ai.system", "azure.ai.openai")
            span.set_attribute("gen_ai.request.model", completion.model)
            span.set_attribute("gen_ai.usage.input_tokens", completion.input_tokens)
            span.set_attribute("gen_ai.usage.output_tokens", completion.output_tokens)

    return {"answer": completion.answer, "trace_id": trace_id, "session_id": session_id,
            "sources": [h.title for h in hits]}

@app.get("/")
def index_page():
    """Serve the single-page chat UI."""
    return FileResponse("static/index.html")
