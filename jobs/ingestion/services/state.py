from __future__ import annotations
import hashlib
from datetime import datetime, timezone

from azure.cosmos import CosmosClient, exceptions
from azure.identity import DefaultAzureCredential

from config import settings


def _item_id(doc_id: str) -> str:
    """A Cosmos item id can't contain '/', '\\', '#' or '?', but doc ids look like "blob:path/to.pdf".

    Hash to a safe, deterministic id — the same sha1 scheme the search index uses for its parent keys
    (domain.IndexRecord.from_chunk) — while the raw doc_id stays in the partition-key field.
    """
    return hashlib.sha1(doc_id.encode()).hexdigest()


class IngestionStateStore:
    """Ingestion dedup state in a Cosmos DB (NoSQL) container — one document per source doc.

    Keyless via DefaultAzureCredential (the account has local auth disabled). The `ingest_state`
    container — partition key `/doc_id` — is provisioned by Bicep, so there is no DDL here.
    `chunk_ids` is stored as a native JSON array.
    """

    def __init__(self) -> None:
        client = CosmosClient(settings.cosmos_endpoint, credential=DefaultAzureCredential())
        db = client.get_database_client(settings.cosmos_db)
        self._container = db.get_container_client("ingest_state")

    def load(self) -> dict[str, dict]:
        # Scan the whole (small) dedup table -> {doc_id: {hash, chunk_ids}}. No partition key is
        # given, so this fans out across partitions — which this SDK requires be opted into explicitly.
        rows = self._container.query_items(
            query="SELECT c.doc_id, c.content_hash, c.chunk_ids FROM c",
            enable_cross_partition_query=True,
        )
        return {r["doc_id"]: {"hash": r["content_hash"], "chunk_ids": r["chunk_ids"]} for r in rows}

    def record(self, doc_id: str, source: str, content_hash: str, chunk_ids: list[str]) -> None:
        # upsert = the old INSERT ... ON CONFLICT DO UPDATE: create or fully replace the doc's state.
        self._container.upsert_item({
            "id": _item_id(doc_id),
            "doc_id": doc_id,
            "source": source,
            "content_hash": content_hash,
            "chunk_ids": chunk_ids,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        })

    def forget(self, doc_ids: list[str]) -> None:
        for doc_id in doc_ids:
            try:
                self._container.delete_item(item=_item_id(doc_id), partition_key=doc_id)
            except exceptions.CosmosResourceNotFoundError:
                pass  # already gone — nothing to prune

    def close(self) -> None:
        # The Cosmos client makes a fresh HTTP request per call; there's no pooled connection to close.
        pass
