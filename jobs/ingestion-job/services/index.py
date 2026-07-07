from __future__ import annotations
from dataclasses import asdict
import httpx
from azure.identity import DefaultAzureCredential

from config import settings
from domain import IndexRecord


class _EntraAuth(httpx.Auth):
    def __init__(self, cred: DefaultAzureCredential) -> None:
        self._cred = cred
        self._scope = "https://search.azure.com/.default"

    def auth_flow(self, request: httpx.Request):
        request.headers["Authorization"] = f"Bearer {self._cred.get_token(self._scope).token}"
        yield request


class SearchIndex:
    def __init__(self) -> None:
        self._path = f"/indexes/{settings.search_index}"
        self._client = httpx.Client(
            base_url=settings.search_endpoint,
            params={"api-version": settings.search_api_version},
            auth=_EntraAuth(DefaultAzureCredential()),
        )

    def ensure(self, dimensions: int) -> None:
        """Create or update the index, sizing the vector field to the given embedding dimension."""
        index_def = {
            "name": settings.search_index,
            "fields": [
                {"name": "id", "type": "Edm.String", "key": True},
                {"name": "parent_id", "type": "Edm.String", "filterable": True},
                {"name": "title", "type": "Edm.String", "searchable": True},
                {"name": "section", "type": "Edm.String"},
                {"name": "content", "type": "Edm.String", "searchable": True},
                {"name": "url", "type": "Edm.String", "filterable": True},
                {"name": "source", "type": "Edm.String", "filterable": True, "facetable": True},
                {"name": "updated_at", "type": "Edm.DateTimeOffset", "filterable": True, "sortable": True},
                {"name": "vector", "type": "Collection(Edm.Single)", "searchable": True,
                 "dimensions": dimensions, "vectorSearchProfile": "vp"},
            ],
            "vectorSearch": {
                "algorithms": [{"name": "hnsw", "kind": "hnsw"}],
                "profiles": [{"name": "vp", "algorithm": "hnsw"}],
            },
        }
        self._client.put(self._path, json=index_def).raise_for_status()

    def upload(self, records: list[IndexRecord]) -> None:
        """Upsert chunk records into the index (mergeOrUpload)."""
        self._batched_action([{**asdict(r), "@search.action": "mergeOrUpload"} for r in records])

    def delete(self, chunk_ids: list[str]) -> None:
        """Delete the given chunk keys from the index; a no-op when the list is empty."""
        if chunk_ids:
            self._batched_action([{"@search.action": "delete", "id": k} for k in chunk_ids])

    def _batched_action(self, docs: list[dict]) -> None:
        """POST index actions to Search in batches to stay under the per-request cap."""
        for i in range(0, len(docs), settings.search_batch_size):
            payload = {"value": docs[i:i + settings.search_batch_size]}
            self._client.post(f"{self._path}/docs/index", json=payload).raise_for_status()

    def close(self) -> None:
        """Close the underlying HTTP client."""
        self._client.close()
