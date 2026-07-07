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
    chat_model: str = "gpt-5-mini"

    applicationinsights_connection_string: str | None = None

    language_endpoint: str

    enable_streaming: bool = True

    @field_validator("search_endpoint")
    @classmethod
    def _strip_trailing_slash(cls, v: str) -> str:
        """Normalize the endpoint so URL joins don't produce a double slash."""
        return v.rstrip("/")


settings = Settings()
