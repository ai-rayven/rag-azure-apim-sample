CREATE TABLE IF NOT EXISTS ingest_state (
    doc_id       TEXT PRIMARY KEY,    
    source       TEXT        NOT NULL, 
    content_hash TEXT        NOT NULL, 
    chunk_ids    TEXT[]      NOT NULL, 
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
