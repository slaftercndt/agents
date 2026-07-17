-- send_accounts — the sender "taxonomy" for the approve->send loop.
--
-- One row per identity the dashboard is allowed to send AS. The dashboard reads
-- this to (a) build the "From" dropdown at approve time and (b) route each send
-- to the right transport. Adding a new sender (e.g. a 4th account) is a single
-- INSERT here + its creds in Vercel — no code change, no redeploy.
--
-- Sending happens in the agents-dashboard (Vercel), NOT n8n and NOT here. This
-- table only carries the routing metadata; the actual SMTP app passwords / Graph
-- creds live in Vercel env, keyed by cred_ref. Never put secrets in this table.
--
-- Apply in the Supabase SQL Editor for BOTH schemas (idempotent).

do $$
declare s text;
begin
  foreach s in array array['crm_dev','crm'] loop

    -- which identity a queued action should be sent as. NULL => the dashboard
    -- falls back to the row's own `account`. Surfaced as a dropdown at approve.
    execute format('alter table if exists %I.ea_actions       add column if not exists send_as text', s);
    execute format('alter table if exists %I.follow_up_drafts add column if not exists send_as text', s);

    execute format($q$
      create table if not exists %I.send_accounts (
        account      text primary key,          -- matches brief_items / ea_actions.account
        display_name text not null,              -- label shown in the picker
        from_address text not null,              -- the actual From header
        transport    text not null
                       check (transport in ('graph','gmail_smtp','gmail_oauth')),
        cred_ref     text,                       -- Vercel env prefix for this sender's creds
        enabled      boolean not null default true,
        sort_order   int not null default 100,   -- GiveSendGo first, per house rule
        created_at   timestamptz not null default now()
      )$q$, s);

    -- RLS with no policy: the dashboard reads/writes server-side with the
    -- service-role key (bypasses RLS), same pattern as ea_actions / follow_up_drafts.
    execute format('alter table %I.send_accounts enable row level security', s);

    -- Seed the live senders. VERIFY from_address + cred_ref match reality before
    -- the first send — a wrong From goes out under the wrong identity.
    execute format($q$
      insert into %I.send_accounts (account, display_name, from_address, transport, cred_ref, sort_order) values
        ('givesendgo','GiveSendGo','nathan@givesendgo.org','graph',null,1),
        ('commissioned','Commissioned','nslafter@commissioned.io','gmail_smtp','COMMISSIONED',2),
        ('gmail','Personal','nslafter@gmail.com','gmail_smtp','GMAIL',3)
      on conflict (account) do nothing$q$, s);

  end loop;
end $$;
