-- ea_feedback — the Executive Assistant's feedback loop (the missing half of
-- "learning"). ea_rules already captures standing rules you curate by hand, and
-- ea_actions already few-shots off bodies you sent. What neither captures is the
-- CORRECTION SIGNAL — the difference between what the EA proposed and what you
-- actually did (sent clean / edited / rejected) — and the COUNTS that decide when
-- an action type has earned its way down the report -> approve -> auto ladder.
--
-- This file adds:
--   1. ea_decisions      — one row per resolved ea_action: the outcome + a snapshot
--                          of the draft and the final, so corrections are not lost.
--   2. ea_rules.* (alter) — created_from / evidence_count, so a rule the loop
--                          PROPOSES (learned) is distinguishable from one you wrote
--                          (manual) and starts disabled until you confirm it.
--   3. ea_trust          — view: per (type, account) over a trailing window, the
--                          clean/edited/rejected counts and a suggested_mode. This
--                          is what the ea-feedback workflow reads to ask
--                          "promote this to auto?".
--   4. ea_rule_candidates — view: senders the EA keeps getting wrong, surfaced as
--                          learned-rule candidates for you to confirm.
--
-- Nothing here ever changes behavior on its own: promotions and learned rules are
-- only ever PROPOSED into `attention`/`ea_rules(enabled=false)`. A human still says
-- yes — the report -> approve -> auto discipline, applied to the rules themselves.
--
-- Lives in Supabase alongside the rest of the EA/CRM backbone. Apply in the
-- Supabase SQL Editor for BOTH schemas: run as-is for crm_dev, then again with
-- crm_dev -> crm for prod. Idempotent (safe to re-run). RLS on, no anon policy —
-- the dashboard and n8n read/write server-side with the service-role key (same
-- posture as ea_actions / ea_rules / follow_up_drafts).

-- 1. ea_decisions ------------------------------------------------------------
create table if not exists crm_dev.ea_decisions (
  id           uuid        primary key default gen_random_uuid(),
  action_id    uuid        references crm_dev.ea_actions (id) on delete set null,
  agent        text        not null default 'executive-assistant',
  type         text        not null,                       -- denormalized so aggregation survives the action row
  account      text        check (account in
                           ('givesendgo','gmail','outlook','nextcloud','fourth','calendar','other')),
  sender       text,                                       -- the counterparty (to/from), for per-relationship learning
  decision     text        not null
                           check (decision in
                           ('approved_clean','approved_edited','rejected','auto_executed')),
  --  approved_clean  = you sent it untouched          (strong positive)
  --  approved_edited = you sent it after editing       (correction signal — learn the delta)
  --  rejected        = you discarded it                (negative — the EA should not have proposed this)
  --  auto_executed   = it went out on mode='auto'      (monitor; one bad one demotes the type)
  draft_payload jsonb      not null default '{}'::jsonb,   -- what the EA proposed (snapshot, never overwritten)
  final_payload jsonb,                                     -- what actually went out (null when rejected)
  edit_note    text,                                       -- optional one-line "what you changed and why"
  decided_by   text        not null default 'human',
  decided_at   timestamptz not null default now()
);

create index if not exists idx_ea_decisions_rollup
  on crm_dev.ea_decisions (type, account, decided_at);
create index if not exists idx_ea_decisions_sender
  on crm_dev.ea_decisions (sender, decided_at);

alter table crm_dev.ea_decisions enable row level security;

-- 2. ea_rules — distinguish a rule the loop proposed from one you wrote --------
alter table crm_dev.ea_rules add column if not exists created_from   text not null default 'manual'
                             check (created_from in ('manual','learned'));
alter table crm_dev.ea_rules add column if not exists evidence_count integer not null default 0;
-- (learned rules are INSERTed with enabled=false; you flip them on to adopt them.)

-- 3. ea_trust — the graduation view ------------------------------------------
-- Counts the last 60 days of decisions per (type, account) and suggests a mode.
-- Thresholds are deliberately conservative and visible here so you can tune them:
--   auto      <- >= 12 clean approvals, ZERO rejected, ZERO edited, >= 90% clean
--   approve   <- everything else (the safe default)
-- "edited" counts against auto on purpose: if you keep editing, the EA is close
-- but not trusted to go untouched yet.
create or replace view crm_dev.ea_trust as
select
  type,
  account,
  count(*)                                            as n_total,
  count(*) filter (where decision = 'approved_clean') as n_clean,
  count(*) filter (where decision = 'approved_edited')as n_edited,
  count(*) filter (where decision = 'rejected')       as n_rejected,
  round(
    count(*) filter (where decision = 'approved_clean')::numeric
    / nullif(count(*), 0), 2)                         as clean_rate,
  case
    when count(*) filter (where decision = 'approved_clean') >= 12
     and count(*) filter (where decision = 'rejected') = 0
     and count(*) filter (where decision = 'approved_edited') = 0
     and count(*) filter (where decision = 'approved_clean')::numeric
         / nullif(count(*), 0) >= 0.90
    then 'auto'
    else 'approve'
  end                                                 as suggested_mode
from crm_dev.ea_decisions
where decided_at > now() - interval '60 days'
group by type, account;

-- 4. ea_rule_candidates — senders the EA keeps getting wrong -------------------
-- Surfaces a sender + a suggested forced route the loop can propose as a LEARNED,
-- disabled ea_rule. Conservative: repeated rejections -> stop drafting ('fyi');
-- repeated edits -> a tone rule is warranted (route left null, you add the note).
create or replace view crm_dev.ea_rule_candidates as
select
  sender,
  count(*) filter (where decision = 'rejected')        as n_rejected,
  count(*) filter (where decision = 'approved_edited') as n_edited,
  case
    when count(*) filter (where decision = 'rejected') >= 3
     and count(*) filter (where decision in ('approved_clean','approved_edited')) = 0
    then 'fyi'                                          -- you never want a draft here
    else null                                          -- edits -> tone rule, you supply tone_notes
  end                                                  as suggested_route,
  max(decided_at)                                      as last_seen
from crm_dev.ea_decisions
where sender is not null
  and decided_at > now() - interval '90 days'
group by sender
having count(*) filter (where decision = 'rejected') >= 3
    or count(*) filter (where decision = 'approved_edited') >= 4;
