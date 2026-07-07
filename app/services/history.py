from __future__ import annotations
import uuid
from datetime import datetime, timezone

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

from config import settings


class HistoryStore:
    """Chat history in a Cosmos DB (NoSQL) container — one document per message.

    Keyless: DefaultAzureCredential selects the app UAMI and the SDK exchanges it for a Cosmos
    data-plane token (the account has local auth disabled). The `messages` container — partition
    key `/session_id` — is provisioned by Bicep, so there is no schema/DDL step at startup.
    """

    def __init__(self) -> None:
        client = CosmosClient(settings.cosmos_endpoint, credential=DefaultAzureCredential())
        db = client.get_database_client(settings.cosmos_db)
        self._container = db.get_container_client("messages")

    def load(self, session_id: str, limit: int = 10) -> list[dict]:
        # Single-partition query (keyed by session_id): newest `limit` messages, returned oldest-first.
        # created_at is an ISO-8601 UTC string, so lexicographic DESC == chronological DESC.
        rows = list(self._container.query_items(
            query=(
                "SELECT c.role, c.content FROM c WHERE c.session_id = @sid "
                "ORDER BY c.created_at DESC OFFSET 0 LIMIT @n"
            ),
            parameters=[{"name": "@sid", "value": session_id}, {"name": "@n", "value": limit}],
            partition_key=session_id,
        ))
        return [{"role": r["role"], "content": r["content"]} for r in reversed(rows)]

    def save(self, session_id: str, role: str, content: str, trace_id: str | None) -> None:
        self._container.create_item({
            "id": str(uuid.uuid4()),
            "session_id": session_id,
            "role": role,
            "content": content,
            "trace_id": trace_id,  # correlates a turn with its App Insights trace
            "created_at": datetime.now(timezone.utc).isoformat(),
        })
