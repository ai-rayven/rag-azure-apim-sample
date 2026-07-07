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
    search_batch_size: int = 500

    pg_host: str
    pg_db: str
    pg_user: str

    blob_account: str
    blob_container: str = "documents"
    queue_name: str = "ingest-events"

    embed_model: str = "text-embedding-3-large"
    embed_batch_size: int = 64
    chunk_max_tokens: int = 1024

    applicationinsights_connection_string: str | None = None

    language_endpoint: str

    @field_validator("search_endpoint")
    @classmethod
    def _strip_trailing_slash(cls, v: str) -> str:
        """Normalize the endpoint so URL joins don't produce a double slash."""
        return v.rstrip("/")


settings = Settings()
