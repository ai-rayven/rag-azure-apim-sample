from __future__ import annotations
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.queue import QueueClient

from config import settings
from domain import IndexRecord, ParsedDoc, Source, SourceDoc, content_hash
from services.documents import DocumentProcessor
from services.embeddings import Embedder
from services.index import SearchIndex
from services.source import BlobSource
from services.state import IngestionStateStore
from telemetry import setup_telemetry


tracer = setup_telemetry("ingestion")


def drain() -> int:
    client = QueueClient(
        account_url=f"https://{settings.blob_account}.queue.core.windows.net",
        queue_name=settings.queue_name,
        credential=DefaultAzureCredential(),
    )
    drained = 0
    try:
        while True:
            page = list(client.receive_messages(messages_per_page=32, visibility_timeout=60))
            if not page:
                return drained
            for msg in page:
                client.delete_message(msg)
                drained += 1
    except ResourceNotFoundError:
        return drained

def should_skip_doc(doc: SourceDoc, digest: str, known: dict[str, dict]) -> bool:
    return doc.id in known and known[doc.id]["hash"] == digest

def create_index_records(doc: SourceDoc, parsed: ParsedDoc, embedder: Embedder) -> list[IndexRecord]:
    records: list[IndexRecord] = []
    for start in range(0, len(parsed.chunks), settings.embed_batch_size):
        batch = parsed.chunks[start:start + settings.embed_batch_size]
        vectors = embedder.embed([c.text for c in batch])
        for j, (chunk, vector) in enumerate(zip(batch, vectors)):
            records.append(IndexRecord.from_chunk(doc, start + j, chunk, parsed.title, vector))
    return records

def run(source: Source, processor: DocumentProcessor, embedder: Embedder,
        index: SearchIndex, state: IngestionStateStore) -> dict:

    known = state.load()
    index.ensure(dimensions=len(embedder.embed(["dimension probe"])[0]))

    seen: set[str] = set()
    stats = {"scanned": 0, "ingested": 0, "skipped": 0, "chunks": 0, "pruned_docs": 0}

    for doc in source.list():
        stats["scanned"] += 1
        seen.add(doc.id)

        data = source.fetch(doc)

        digest = content_hash(data)
        if should_skip_doc(doc, digest, known):
            stats["skipped"] += 1
            continue

        with tracer.start_as_current_span("ingest-doc") as span:
            span.set_attribute("doc.id", doc.id)

            parsed = processor.process(doc, data)
            if not parsed.chunks:
                # Empty means Docling extracted no embeddable text.
                stats["skipped"] += 1
                continue

            records = create_index_records(doc, parsed, embedder)
            index.upload(records)

            new_chunk_ids = [r.id for r in records]

            stale = set(known.get(doc.id, {}).get("chunk_ids", [])) - set(new_chunk_ids)
            index.delete(list(stale))

            span.set_attribute("doc.chunks", len(new_chunk_ids))
            state.record(doc.id, source.name, digest, new_chunk_ids)

            stats["ingested"] += 1
            stats["chunks"] += len(new_chunk_ids)

    gone = [doc_id for doc_id in known if doc_id not in seen]
    if gone:
        index.delete([cid for doc_id in gone for cid in known[doc_id]["chunk_ids"]])
        state.forget(gone)
        stats["pruned_docs"] = len(gone)

    return stats

def main() -> None:
    drained = drain()
    if drained:
        print(f"drained {drained} blob-created event(s) from the trigger queue")

    source = BlobSource()
    processor = DocumentProcessor()
    embedder = Embedder()
    search_index = SearchIndex()
    ingestion_state = IngestionStateStore()

    try:
        stats = run(source, processor, embedder, search_index, ingestion_state)
    finally:
        search_index.close()
        ingestion_state.close()
    print(f"ingestion complete: {stats}")


if __name__ == "__main__":
    main()
