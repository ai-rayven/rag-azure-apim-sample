from __future__ import annotations
from typing import Iterable
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

from config import settings
from domain import SourceDoc


class BlobSource:
    name = "blob"

    def __init__(self) -> None:
        self._container = settings.blob_container
        self._svc = BlobServiceClient(
            account_url=f"https://{settings.blob_account}.blob.core.windows.net",
            credential=DefaultAzureCredential(),
        )

    def list(self) -> Iterable[SourceDoc]:
        client = self._svc.get_container_client(self._container)
        for b in client.list_blobs():
            yield SourceDoc(id=f"{self.name}:{b.name}", uri=f"{self._container}/{b.name}")

    def fetch(self, doc: SourceDoc) -> bytes:
        blob_name = doc.uri.split("/", 1)[1]
        return self._svc.get_container_client(self._container).download_blob(blob_name).readall()
