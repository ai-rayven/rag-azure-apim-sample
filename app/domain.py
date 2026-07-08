from __future__ import annotations
from dataclasses import dataclass
from pydantic import BaseModel

class ChatRequest(BaseModel):
    message: str
    session_id: str | None = None
    model: str | None = None  # picker selection; validated against the allowlist server-side

@dataclass
class Hit:
    title: str
    content: str
    url: str

@dataclass
class Completion:
    answer: str
    model: str
    input_tokens: int
    output_tokens: int
