from __future__ import annotations
from collections.abc import Iterator
from pathlib import Path
from openai import OpenAI

from config import settings
from domain import Completion, Hit
from services.history import HistoryStore
from telemetry import record_content


class ChatService:
    def __init__(self, history: HistoryStore) -> None:
        self._history = history
        self._client = OpenAI(
            base_url=settings.apim_base_url,
            api_key="via-apim",
            default_headers={"Ocp-Apim-Subscription-Key": settings.apim_key},
        )
        self.system_prompt = (Path(__file__).parent.parent / "prompts" / "system.md").read_text(encoding="utf-8").strip()

    def respond(self, session_id: str, message: str, hits: list[Hit], trace_id: str) -> Completion:
        """Non-streaming turn: one blocking call, the whole answer at once.

        Used when ENABLE_STREAMING is off (the APIM gateway is then on a tier that can't hold the
        long-lived SSE connection, so we must NOT send stream=true upstream).
        """
        messages = self._prepare(session_id, message, hits)
        resp = self._client.chat.completions.create(model=settings.chat_model, messages=messages)
        completion = Completion(
            answer=resp.choices[0].message.content,
            model=settings.chat_model,
            input_tokens=resp.usage.prompt_tokens,
            output_tokens=resp.usage.completion_tokens,
        )
        self._finish(session_id, message, trace_id, completion)
        return completion

    def respond_stream(self, session_id: str, message: str, hits: list[Hit], trace_id: str) -> Iterator[str]:
        """Streaming turn: yield each content delta as it arrives.

        The generator's *return value* (captured via `StopIteration.value`) is the finished
        `Completion` — full answer plus token usage from the stream's final chunk. Persistence and
        completion-content capture run once the stream drains, so history + telemetry still see the
        whole turn.
        """
        messages = self._prepare(session_id, message, hits)
        # stream=True turns the call into SSE (relayed untouched through the APIM gateway);
        # include_usage adds a final usage-only chunk so we still get token counts for telemetry.
        stream = self._client.chat.completions.create(
            model=settings.chat_model,
            messages=messages,
            stream=True,
            stream_options={"include_usage": True},
        )
        parts: list[str] = []
        usage = None
        for chunk in stream:
            if chunk.usage:  # final usage-only chunk (choices is empty here)
                usage = chunk.usage
            if chunk.choices:
                delta = chunk.choices[0].delta.content
                if delta:
                    parts.append(delta)
                    yield delta

        completion = Completion(
            answer="".join(parts),
            model=settings.chat_model,
            input_tokens=usage.prompt_tokens if usage else 0,
            output_tokens=usage.completion_tokens if usage else 0,
        )
        self._finish(session_id, message, trace_id, completion)
        return completion

    def _prepare(self, session_id: str, message: str, hits: list[Hit]) -> list[dict]:
        """Build the message list and record the (decomposed, PII-marked) prompt. Shared by both paths."""
        history = self._history.load(session_id)
        context = "\n\n".join(f"[{h.title}]\n{h.content}" for h in hits)
        messages = [
            {"role": "system", "content": self.system_prompt},
            *history,
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {message}"},
        ]
        # Capture the prompt decomposed so only the user's own text is PII-scrubbed (in the exporter).
        # The system prompt, retrieved context (your documents — de-identify those at ingestion), and
        # prior history are exported as-is.
        record_content(
            "gen_ai.content.prompt",
            {"system_prompt": self.system_prompt, "history": history,
             "context": context, "user_message": message},
            scrub=("user_message",),
        )
        return messages

    def _finish(self, session_id: str, message: str, trace_id: str, completion: Completion) -> None:
        """Record the completion content and persist the turn. Shared by both paths."""
        record_content("gen_ai.content.completion", completion.answer)
        self._history.save(session_id, "user", message, trace_id)
        self._history.save(session_id, "assistant", completion.answer, trace_id)
