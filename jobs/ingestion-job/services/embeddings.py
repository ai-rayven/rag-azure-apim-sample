from __future__ import annotations
from openai import OpenAI

from config import settings


class Embedder:
    def __init__(self) -> None:
        self._client = OpenAI(
            base_url=settings.apim_base_url,
            api_key="via-apim",
            default_headers={"Ocp-Apim-Subscription-Key": settings.apim_key},
        )

    def embed(self, texts: list[str]) -> list[list[float]]:
        resp = self._client.embeddings.create(model=settings.embed_model, input=texts)
        return [d.embedding for d in resp.data]
