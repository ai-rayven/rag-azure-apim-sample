CREATE TABLE IF NOT EXISTS messages (
    id          BIGSERIAL PRIMARY KEY,
    session_id  UUID        NOT NULL,
    role        TEXT        NOT NULL,     -- 'user' | 'assistant'
    content     TEXT        NOT NULL,
    trace_id    TEXT,                     -- correlates a turn with its App Insights trace
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_messages_session ON messages (session_id, created_at);
