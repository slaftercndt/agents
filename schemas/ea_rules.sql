-- ea_rules — the Executive Assistant's standing rules (the "learning" you can
-- actually trust: deterministic and auditable, not a training loop).
--
-- Before routing/drafting an email, the EA looks up rules matching the sender
-- (exact email, or domain, or a substring pattern) and injects them into the
-- prompt: force a route and/or add tone guidance. You curate these from the
-- dashboard; the EA obeys them.
--
-- Lives in Supabase alongside the rest of the EA/CRM backbone. Apply in the
-- Supabase SQL Editor for BOTH schemas: run as-is for crm_dev, then with
-- crm_dev -> crm for prod.

create table if not exists crm_dev.ea_rules (
  id          uuid        primary key default gen_random_uuid(),
  match_type  text        not null default 'email'
                          check (match_type in ('email','domain','pattern')),
  match_value text        not null,                  -- e.g. 'jane@acme.com' | 'acme.com' | 'invoice'
  force_route text        check (force_route in
                          ('reply','review','task','fyi','ignore')),  -- null = no forced route
  tone_notes  text,                                  -- free-text style guidance for drafts
  enabled     boolean     not null default true,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (match_type, match_value)
);

create index if not exists idx_ea_rules_lookup
  on crm_dev.ea_rules (enabled, match_type, match_value);

-- RLS on, no anon policy — dashboard reads/writes server-side with the
-- service-role key (same posture as ea_actions / follow_up_drafts).
alter table crm_dev.ea_rules enable row level security;
