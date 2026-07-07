from __future__ import annotations
import psycopg
from azure.identity import DefaultAzureCredential

from config import settings


DDL = """
CREATE TABLE IF NOT EXISTS ingest_state (
    doc_id       TEXT PRIMARY KEY,
    source       TEXT        NOT NULL,
    content_hash TEXT        NOT NULL,
    chunk_ids    TEXT[]      NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


class IngestionStateStore:
    def __init__(self) -> None:
        scope = "https://ossrdbms-aad.database.windows.net/.default"
        token = DefaultAzureCredential().get_token(scope).token
        self._conn = psycopg.connect(
            host=settings.pg_host,
            dbname=settings.pg_db,
            user=settings.pg_user,
            password=token,
            sslmode="require",
            autocommit=True,
        )
        self._conn.execute(DDL)

    def load(self) -> dict[str, dict]:
        rows = self._conn.execute("SELECT doc_id, content_hash, chunk_ids FROM ingest_state").fetchall()
        return {r[0]: {"hash": r[1], "chunk_ids": r[2]} for r in rows}

    def record(self, doc_id: str, source: str, content_hash: str, chunk_ids: list[str]) -> None:
        self._conn.execute(
            """
            INSERT INTO ingest_state (doc_id, source, content_hash, chunk_ids, updated_at)
            VALUES (%s, %s, %s, %s, now())
            ON CONFLICT (doc_id) DO UPDATE
              SET content_hash = EXCLUDED.content_hash,
                  chunk_ids    = EXCLUDED.chunk_ids,
                  updated_at   = now()
            """,
            (doc_id, source, content_hash, chunk_ids),
        )

    def forget(self, doc_ids: list[str]) -> None:
        if doc_ids:
            self._conn.execute("DELETE FROM ingest_state WHERE doc_id = ANY(%s)", (doc_ids,))

    def close(self) -> None:
        self._conn.close()
