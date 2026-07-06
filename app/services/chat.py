from __future__ import annotations
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
        resp = self._client.chat.completions.create(
            model=settings.chat_model,
            messages=messages,
        )
        completion = Completion(
            answer=resp.choices[0].message.content,
            model=settings.chat_model,
            input_tokens=resp.usage.prompt_tokens,
            output_tokens=resp.usage.completion_tokens,
        )
        record_content("gen_ai.content.completion", completion.answer)
        self._history.save(session_id, "user", message, trace_id)
        self._history.save(session_id, "assistant", completion.answer, trace_id)
        return completion
