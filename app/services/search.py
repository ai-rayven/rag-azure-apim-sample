from __future__ import annotations
import logging
import httpx
from azure.identity import DefaultAzureCredential
from opentelemetry import trace

from config import settings
from domain import Hit

logger = logging.getLogger(__name__)


class SearchIndex:
    def __init__(self) -> None:
        self._cred = DefaultAzureCredential()

    def _headers(self) -> dict:
        scope = "https://search.azure.com/.default"
        token = self._cred.get_token(scope).token
        return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    def vector_search(self, qvec: list[float], k: int = 3) -> list[Hit]:
        body = {
            "vectorQueries": [{"kind": "vector", "vector": qvec, "fields": "vector", "k": k}],
            "select": "title,content,url",
        }
        with httpx.Client() as c:
            r = c.post(
                f"{settings.search_endpoint}/indexes/{settings.search_index}/docs/search?api-version={settings.search_api_version}",
                json=body, headers=self._headers(),
            )
        if r.status_code == 404:
            # Index doesn't exist yet — ingestion hasn't run. Degrade to no-context RAG (answer
            # without sources) instead of 500-ing the whole chat turn. Surfaced on the trace so the
            # missing index is still diagnosable in App Insights.
            logger.warning("search index %r returned 404; answering without retrieval", settings.search_index)
            trace.get_current_span().add_event("search.index_missing", {"search.index": settings.search_index})
            return []
        r.raise_for_status()
        return [
            Hit(title=v.get("title", ""), content=v.get("content", ""), url=v.get("url", ""))
            for v in r.json().get("value", [])
        ]
