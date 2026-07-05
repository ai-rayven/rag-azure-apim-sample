from __future__ import annotations
import psycopg
from azure.identity import DefaultAzureCredential

from config import settings

DDL = """
CREATE TABLE IF NOT EXISTS messages (
    id          BIGSERIAL PRIMARY KEY,
    session_id  UUID        NOT NULL,
    role        TEXT        NOT NULL,
    content     TEXT        NOT NULL,
    trace_id    TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_messages_session ON messages (session_id, created_at);
"""


class HistoryStore:
    def __init__(self) -> None:
        self._cred = DefaultAzureCredential()

    def _connect(self) -> psycopg.Connection:
        scope = "https://ossrdbms-aad.database.windows.net/.default"
        token = self._cred.get_token(scope).token
        return psycopg.connect(
            host=settings.pg_host,
            dbname=settings.pg_db,
            user=settings.pg_user,
            password=token,
            sslmode="require",
        )

    def migrate(self) -> None:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(DDL)

    def load(self, session_id: str, limit: int = 10) -> list[dict]:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT role, content FROM messages WHERE session_id = %s "
                "ORDER BY created_at DESC LIMIT %s",
                (session_id, limit),
            )
            rows = cur.fetchall()
        return [{"role": r, "content": c} for r, c in reversed(rows)]

    def save(self, session_id: str, role: str, content: str, trace_id: str | None) -> None:
        with self._connect() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO messages (session_id, role, content, trace_id) VALUES (%s, %s, %s, %s)",
                (session_id, role, content, trace_id),
            )
