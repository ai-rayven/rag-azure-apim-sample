from __future__ import annotations
import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Protocol


@dataclass
class SourceDoc:
    """A document discovered in a source, before its bytes are fetched.

    Attributes:
        id: Stable and unique within the source; the index doc's parent key derives from it.
        uri: Where it came from — stored as metadata for citations.
    """

    id: str
    uri: str


class Source(Protocol):
    """A connector that lists documents and fetches their bytes.

    Adding a new source (SharePoint, a database, a web crawl) means writing another class with these
    two methods; nothing else in the pipeline changes.
    """

    name: str

    def list(self) -> Iterable[SourceDoc]:
        """Yield every document currently in the source."""
        ...

    def fetch(self, doc: SourceDoc) -> bytes:
        """Return the raw bytes of ``doc``."""
        ...


@dataclass
class Chunk:
    """One chunk ready to embed.

    Attributes:
        text: The heading-contextualized text — exactly what we embed and store.
        headings: The section path the chunk came from, e.g. ``["X200 Ventilator", "Error E42"]``.
    """

    text: str
    headings: list[str]


@dataclass
class ParsedDoc:
    """The result of parsing one source document: its display title and its chunks.

    The processor produces this — it's the one component that actually parsed the document, so it's
    the natural place for the title (derived from the first heading, else the filename) to come from.

    Attributes:
        title: Display title for citations, shared by every chunk of the document.
        chunks: The heading-contextualized chunks, ready to embed.
    """

    title: str
    chunks: list[Chunk]


@dataclass
class IndexRecord:
    """One record written to the search index: a chunk's text and vector plus retrieval metadata.

    The metadata carries what retrieval filters and citations need. ``section`` is the real section a
    passage came from (Docling's heading-path), not just an ordinal. ``id`` hashes the parent id and
    suffixes the chunk number, so a doc's chunks share a stable, derivable prefix used for targeted
    deletes — Azure Search keys may contain only letters, digits, ``_``, ``-``, ``=``. To carry more,
    add a field here and a matching field to the index schema in ``services/index.py``.
    """

    id: str
    parent_id: str
    title: str
    section: str
    content: str
    url: str
    source: str
    updated_at: str
    vector: list[float]

    @classmethod
    def from_chunk(cls, doc: SourceDoc, chunk_index: int, chunk: Chunk, title: str,
                   vector: list[float]) -> "IndexRecord":
        """Build the index record for chunk ``chunk_index`` of ``doc``."""
        parent_key = hashlib.sha1(doc.id.encode()).hexdigest()
        section = " > ".join(chunk.headings) if chunk.headings else f"chunk {chunk_index}"
        return cls(
            id=f"{parent_key}-{chunk_index}",
            parent_id=doc.id,
            title=title,
            section=section,
            content=chunk.text,
            url=doc.uri,
            source=doc.id.split(":", 1)[0],  # e.g. "blob"
            updated_at=datetime.now(timezone.utc).isoformat(),
            vector=vector,
        )


def content_hash(data: bytes) -> str:
    """Stable fingerprint of a source document — the idempotency key (unchanged bytes => skip)."""
    return hashlib.sha256(data).hexdigest()


