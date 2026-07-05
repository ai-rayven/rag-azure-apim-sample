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
        messages = self._messages(session_id, message, hits)
        record_content("gen_ai.content.prompt", messages)
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

    def _messages(self, session_id: str, message: str, hits: list[Hit]) -> list[dict]:
        context = "\n\n".join(f"[{h.title}]\n{h.content}" for h in hits)
        return [
            {"role": "system", "content": self.system_prompt},
            *self._history.load(session_id),
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {message}"},
        ]
