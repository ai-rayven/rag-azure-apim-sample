from __future__ import annotations
import io
import re
import tiktoken
from docling.chunking import HybridChunker
from docling.datamodel.base_models import DocumentStream
from docling.document_converter import DocumentConverter
from docling_core.transforms.chunker.tokenizer.openai import OpenAITokenizer

from config import settings
from domain import Chunk, ParsedDoc, SourceDoc


class DocumentProcessor:
    def __init__(self) -> None:
        self._converter = DocumentConverter()
        self._chunker = HybridChunker(
            tokenizer=OpenAITokenizer(
                tokenizer=tiktoken.encoding_for_model(settings.embed_model),
                max_tokens=settings.chunk_max_tokens,
            )
        )

    def _derive_title(self, uri: str, headings: list[str]) -> str:
        """Pick a display title: the document's first heading, else a cleaned-up filename."""
        if headings:
            return headings[0]
        name = uri.rsplit("/", 1)[-1]
        return re.sub(r"\.[^.]+$", "", name).replace("_", " ").replace("-", " ").strip() or uri

    def process(self, doc: SourceDoc, data: bytes) -> ParsedDoc:
        name = doc.uri.rsplit("/", 1)[-1]
        source = DocumentStream(name=name, stream=io.BytesIO(data))
        parsed = self._converter.convert(source).document
        chunks: list[Chunk] = []
        for c in self._chunker.chunk(dl_doc=parsed):
            text = self._chunker.contextualize(chunk=c)
            if text.strip():
                chunks.append(Chunk(text=text, headings=list(c.meta.headings or [])))
        title = self._derive_title(doc.uri, chunks[0].headings if chunks else [])
        return ParsedDoc(title=title, chunks=chunks)
