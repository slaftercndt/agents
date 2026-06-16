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

-- --- Executive Assistant (agent 2) reuse ------------------------------------
-- The EA drafts replies to needs_reply items. To draft (and to thread the reply
-- onto the right message) it needs the email body and a stable message id, which
-- the Chief of Staff ingest now also stores. ea_drafted lets the EA track its own
-- progress independently of `briefed` (the brief and the EA consume rows on
-- different clocks). These are added idempotently so existing rows keep working.
ALTER TABLE brief_items ADD COLUMN IF NOT EXISTS body        TEXT;
ALTER TABLE brief_items ADD COLUMN IF NOT EXISTS message_id  TEXT;
ALTER TABLE brief_items ADD COLUMN IF NOT EXISTS ea_drafted  BOOLEAN NOT NULL DEFAULT false;

-- The rows the EA still needs to draft a reply for.
CREATE INDEX IF NOT EXISTS idx_brief_items_ea_pending
  ON brief_items (ea_drafted, classification, received_at);
