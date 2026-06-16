-- ea_actions — the Executive Assistant's proposed-action queue (agent 2).
--
-- This is the EA's equivalent of the Chief of Staff's brief_items, but it lives
-- in the **Supabase** CRM project (NOT n8n's Postgres) because that is where the
-- dashboard's approve->send loop already reads from. The EA (an n8n workflow)
-- reads needs_reply rows out of n8n's brief_items, drafts a reply with Sonnet,
-- and INSERTs one row here per proposed action. The dashboard surfaces these and,
-- on an explicit human yes, executes them via MS Graph (reusing the same sender
-- the CRM follow-ups already use).
--
-- Each row mirrors one entry of the shared action envelope
-- (schemas/action.schema.json): agent / type / mode / account / priority /
-- summary / detail / payload. The rest are operational columns.
--
-- Phase-1 EA is APPROVE-ONLY for sends: nothing leaves without a human yes
-- (mode defaults to 'approve'; 'auto' exists for later, lower-risk action types).
--
-- Apply in the Supabase SQL Editor for BOTH schemas: run as-is for crm_dev (dev),
-- then again with crm_dev -> crm for prod.

create table if not exists crm_dev.ea_actions (
  id            uuid        primary key default gen_random_uuid(),
  agent         text        not null default 'executive-assistant',
  type          text        not null,                      -- email.draft | email.send | calendar.create | calendar.move
  mode          text        not null default 'approve'
                            check (mode in ('auto','approve','report')),
  status        text        not null default 'proposed'
                            check (status in ('proposed','approved','sent','executed','discarded','error')),
  account       text        check (account in
                            ('givesendgo','gmail','outlook','nextcloud','fourth','calendar','other')),
  priority      integer     not null default 3,            -- GiveSendGo = 1 (sorts first)
  summary       text        not null,                      -- one-line, human-readable
  detail        text,                                      -- the draft body / longer text
  payload       jsonb       not null default '{}'::jsonb,  -- to/cc/subject/body, or event fields
  -- operational / idempotency --------------------------------------------------
  source_message_id text,                                  -- the email this replies to (for threading)
  dedup_key     text        unique,                        -- so a scheduled run never re-proposes the same action
  executed_at   timestamptz,
  error         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Fast lookup of the actions the dashboard still needs to show / act on.
create index if not exists idx_ea_actions_pending
  on crm_dev.ea_actions (status, priority, created_at);

-- RLS: enable with NO anon/authenticated policy. The dashboard reads/writes this
-- table server-side with the service-role key (which bypasses RLS), exactly like
-- follow_up_drafts. Leaving it without policies keeps the anon key locked out.
alter table crm_dev.ea_actions enable row level security;
