-- ea_apply_all.sql — one-shot setup for the Executive Assistant (agent 2).
--
-- Paste this whole file into the Supabase SQL Editor and run once. It is
-- idempotent (safe to re-run) and covers BOTH schemas (crm_dev = dev, crm = prod)
-- plus the attention RLS fix the EA depends on.
--
-- It creates: ea_actions (approve->send queue), ea_rules (standing rules), and
-- enables RLS on attention. No anon policies anywhere — the dashboard reads/writes
-- server-side with the service-role key, which bypasses RLS (same posture as
-- follow_up_drafts / pending_ingest).

do $$
declare s text;
begin
  foreach s in array array['crm_dev','crm'] loop

    -- ea_actions ------------------------------------------------------------
    execute format($f$
      create table if not exists %I.ea_actions (
        id            uuid        primary key default gen_random_uuid(),
        agent         text        not null default 'executive-assistant',
        type          text        not null,
        mode          text        not null default 'approve'
                                  check (mode in ('auto','approve','report')),
        status        text        not null default 'proposed'
                                  check (status in ('proposed','approved','sent','executed','discarded','error')),
        account       text        check (account in
                                  ('givesendgo','gmail','outlook','nextcloud','fourth','calendar','other')),
        priority      integer     not null default 3,
        summary       text        not null,
        detail        text,
        payload       jsonb       not null default '{}'::jsonb,
        source_message_id text,
        dedup_key     text        unique,
        executed_at   timestamptz,
        error         text,
        created_at    timestamptz not null default now(),
        updated_at    timestamptz not null default now()
      );$f$, s);
    execute format('create index if not exists idx_%s_ea_actions_pending on %I.ea_actions (status, priority, created_at);', s, s);
    execute format('alter table %I.ea_actions enable row level security;', s);

    -- ea_rules --------------------------------------------------------------
    execute format($f$
      create table if not exists %I.ea_rules (
        id          uuid        primary key default gen_random_uuid(),
        match_type  text        not null default 'email'
                                check (match_type in ('email','domain','pattern')),
        match_value text        not null,
        force_route text        check (force_route in ('reply','review','task','fyi','ignore')),
        tone_notes  text,
        enabled     boolean     not null default true,
        notes       text,
        created_at  timestamptz not null default now(),
        updated_at  timestamptz not null default now(),
        unique (match_type, match_value)
      );$f$, s);
    execute format('create index if not exists idx_%s_ea_rules_lookup on %I.ea_rules (enabled, match_type, match_value);', s, s);
    execute format('alter table %I.ea_rules enable row level security;', s);

    -- attention: close the open-RLS hole (table already exists) --------------
    execute format('alter table if exists %I.attention enable row level security;', s);

    -- ea_decisions: the correction-signal log (see schemas/ea_feedback.sql) ---
    execute format($f$
      create table if not exists %I.ea_decisions (
        id           uuid        primary key default gen_random_uuid(),
        action_id    uuid,
        agent        text        not null default 'executive-assistant',
        type         text        not null,
        account      text        check (account in
                                 ('givesendgo','gmail','outlook','nextcloud','fourth','calendar','other')),
        sender       text,
        decision     text        not null
                                 check (decision in
                                 ('approved_clean','approved_edited','rejected','auto_executed')),
        draft_payload jsonb      not null default '{}'::jsonb,
        final_payload jsonb,
        edit_note    text,
        decided_by   text        not null default 'human',
        decided_at   timestamptz not null default now()
      );$f$, s);
    execute format('create index if not exists idx_%s_ea_decisions_rollup on %I.ea_decisions (type, account, decided_at);', s, s);
    execute format('create index if not exists idx_%s_ea_decisions_sender on %I.ea_decisions (sender, decided_at);', s, s);
    execute format('alter table %I.ea_decisions enable row level security;', s);

    -- ea_rules: learning provenance (manual vs proposed-by-the-loop) ----------
    execute format($f$alter table %I.ea_rules add column if not exists created_from text not null default 'manual' check (created_from in ('manual','learned'));$f$, s);
    execute format('alter table %I.ea_rules add column if not exists evidence_count integer not null default 0;', s);

    -- ea_trust: the graduation view (report -> approve -> auto) ---------------
    execute format($f$
      create or replace view %I.ea_trust as
      select type, account,
        count(*)                                             as n_total,
        count(*) filter (where decision = 'approved_clean')  as n_clean,
        count(*) filter (where decision = 'approved_edited') as n_edited,
        count(*) filter (where decision = 'rejected')        as n_rejected,
        round(count(*) filter (where decision = 'approved_clean')::numeric
              / nullif(count(*),0), 2)                       as clean_rate,
        case when count(*) filter (where decision = 'approved_clean') >= 12
              and count(*) filter (where decision = 'rejected') = 0
              and count(*) filter (where decision = 'approved_edited') = 0
              and count(*) filter (where decision = 'approved_clean')::numeric
                  / nullif(count(*),0) >= 0.90
             then 'auto' else 'approve' end                  as suggested_mode
      from %I.ea_decisions
      where decided_at > now() - interval '60 days'
      group by type, account;$f$, s, s);

    -- ea_rule_candidates: senders the EA keeps getting wrong ------------------
    execute format($f$
      create or replace view %I.ea_rule_candidates as
      select sender,
        count(*) filter (where decision = 'rejected')        as n_rejected,
        count(*) filter (where decision = 'approved_edited') as n_edited,
        case when count(*) filter (where decision = 'rejected') >= 3
              and count(*) filter (where decision in ('approved_clean','approved_edited')) = 0
             then 'fyi' else null end                        as suggested_route,
        max(decided_at)                                      as last_seen
      from %I.ea_decisions
      where sender is not null and decided_at > now() - interval '90 days'
      group by sender
      having count(*) filter (where decision = 'rejected') >= 3
          or count(*) filter (where decision = 'approved_edited') >= 4;$f$, s, s);

  end loop;
end $$;
