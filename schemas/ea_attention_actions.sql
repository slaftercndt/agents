-- ea_attention_actions — enrich review (attention) items so they can become
-- drafts, be forwarded, and carry an editable action.
--
-- Why: a review item today stores only a title + the "why". To AI-draft a reply,
-- forward the email, or act on it, the row must carry the SOURCE EMAIL (the EA
-- Router has it in hand at routing time — it just wasn't writing it). This adds
-- those columns plus forwarding/ownership and a link to any draft spawned from
-- the review.
--
-- Apply in the Supabase SQL Editor. Covers BOTH schemas (crm_dev, crm).
-- Idempotent (add column if not exists). RLS is already enabled on attention.

do $$
declare s text;
begin
  foreach s in array array['crm_dev','crm'] loop

    -- source email — so a review can be drafted/forwarded without re-fetching
    execute format('alter table %I.attention add column if not exists from_addr         text;', s);
    execute format('alter table %I.attention add column if not exists subject           text;', s);
    execute format('alter table %I.attention add column if not exists source_body       text;', s);
    execute format('alter table %I.attention add column if not exists source_message_id text;', s);
    execute format('alter table %I.attention add column if not exists account           text;', s);
    execute format('alter table %I.attention add column if not exists priority          integer not null default 3;', s);

    -- editable suggested next-action (what the EA proposes you do)
    execute format('alter table %I.attention add column if not exists suggested_action  text;', s);

    -- review -> draft: link to the ea_actions row the "Draft reply" action creates
    execute format('alter table %I.attention add column if not exists linked_action_id  uuid;', s);

    -- forwarding ("Both": send the email out AND track who owns it now)
    execute format('alter table %I.attention add column if not exists forwarded_to      text[];', s);
    execute format('alter table %I.attention add column if not exists forwarded_at      timestamptz;', s);
    execute format('alter table %I.attention add column if not exists assigned_to       text;', s);

  end loop;
end $$;

-- NOTE: if attention already has action_* columns serving as "the suggested
-- action", point the dashboard at those instead of suggested_action and skip
-- that one ALTER. Run `\d crm_dev.attention` (or the columns query) first if unsure.
