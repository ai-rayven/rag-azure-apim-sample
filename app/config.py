from __future__ import annotations
from pathlib import Path
from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=Path(__file__).resolve().parent.parent / ".env",
        extra="ignore"
    )

    apim_base_url: str
    apim_key: str

    search_endpoint: str
    search_index: str = "ragchat-docs"
    search_api_version: str = "2024-07-01"

    cosmos_endpoint: str
    cosmos_db: str = "ragchat"

    embed_model: str = "text-embedding-3-large"
    # Picker options (CSV of Foundry deployment names), provisioned + injected by azd from main.bicep's
    # single-source `chatModels` list. No default: the deployed models are the source of truth. The
    # gateway routes on the request body's `model`, so every name here works over the one APIM route.
    chat_models: str

    applicationinsights_connection_string: str | None = None

    enable_streaming: bool = True

    @field_validator("search_endpoint")
    @classmethod
    def _strip_trailing_slash(cls, v: str) -> str:
        """Normalize the endpoint so URL joins don't produce a double slash."""
        return v.rstrip("/")

    @property
    def chat_model_options(self) -> list[str]:
        """The picker's allowlist: CHAT_MODELS split into a de-duplicated, order-preserving list.

        Server-side allowlist for the requested model — the name flows to the gateway as the body's
        `model`, so we never forward an arbitrary client string.
        """
        seen: dict[str, None] = {}
        for n in self.chat_models.split(","):
            n = n.strip()
            if n:
                seen.setdefault(n, None)
        return list(seen)

    @property
    def default_chat_model(self) -> str:
        """The default selection: the first picker option (main.bicep's chatModels[0])."""
        return self.chat_model_options[0]


settings = Settings()
