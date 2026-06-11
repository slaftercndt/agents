-- brief_items — the shared queue at the heart of the Chief of Staff (and the
-- reuse point for agents 2-4). Ingest workflows triage each incoming email and
-- INSERT one row here. The 05:30 brief workflow SELECTs the unbriefed rows,
-- writes one grouped brief, then marks them briefed.
--
-- Apply from ~/Developer/Agents with:
--   docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < schemas/brief_items.sql
-- (or just: docker compose exec -T postgres psql -U n8n -d n8n < schemas/brief_items.sql)

CREATE TABLE IF NOT EXISTS brief_items (
  id             BIGSERIAL   PRIMARY KEY,
  account        TEXT        NOT NULL,           -- givesendgo | gmail | outlook | nextcloud | ...
  priority       INTEGER     NOT NULL DEFAULT 2, -- GiveSendGo = 1 (sorts first)
  from_addr      TEXT,
  subject        TEXT,
  one_line       TEXT,                           -- Haiku's <=12 word summary
  classification TEXT,                           -- needs_reply | fyi
  received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  briefed        BOOLEAN     NOT NULL DEFAULT false
);

-- Fast lookup of the rows the morning brief still needs to include.
CREATE INDEX IF NOT EXISTS idx_brief_items_pending
  ON brief_items (briefed, received_at);
