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

    pg_host: str
    pg_db: str
    pg_user: str

    embed_model: str = "text-embedding-3-large"
    chat_model: str = "gpt-5-mini"

    # Stream the chat answer token-by-token over SSE. Must stay in lockstep with the APIM SKU the
    # infra provisions (Developer/v2 tiers can hold the long-lived streaming connection; Consumption
    # cannot) — the bicep ENABLE_STREAMING param sets both this env var and the SKU together.
    enable_streaming: bool = True

    applicationinsights_connection_string: str | None = None

    # Azure AI Language endpoint used to PII-scrub the user's message before it's exported to App
    # Insights. Keyless (managed identity). Required — the deployment always provisions it (the
    # multi-service Foundry account) and provides it via env in Azure and via the generated `.env`
    # locally (`azd env get-values`), so we never silently run without the scrubber. See
    # telemetry.py / docs/observability.md.
    language_endpoint: str

    @field_validator("search_endpoint")
    @classmethod
    def _strip_trailing_slash(cls, v: str) -> str:
        """Normalize the endpoint so URL joins don't produce a double slash."""
        return v.rstrip("/")


settings = Settings()
