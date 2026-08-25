-- CRM insight views — relationship_decay + follow_up_aging.
--
-- Read-only views over the CRM backbone that turn it from a passive archive
-- into a prompt: who is going quiet, and what drafted follow-ups are rotting
-- unapproved. Consumed by the agents-dashboard and by the Chief of Staff
-- morning brief (n8n reads them like any other table).
--
-- Apply in the Supabase SQL Editor for BOTH schemas (idempotent).

do $$
declare s text;
begin
  foreach s in array array['crm_dev','crm'] loop

    -- People going quiet: last touch = max(interaction, people.last_contact),
    -- 45+ days silent, active relationships only, longest-silent first.
    -- People with no recorded touch at all are excluded (nothing to decay from).
    execute format($q$
      create or replace view %I.relationship_decay as
      select p.id as person_id, p.full_name, p.primary_email, p.relationship_status, p.tags,
             greatest(
               coalesce(max(i.occurred_at), 'epoch'::timestamptz),
               coalesce(p.last_contact,      'epoch'::timestamptz)
             ) as last_touch,
             (now() - greatest(
               coalesce(max(i.occurred_at), 'epoch'::timestamptz),
               coalesce(p.last_contact,      'epoch'::timestamptz)
             ))::text as silence
      from %I.people p
      left join %I.interaction_participants ip on ip.person_id = p.id
      left join %I.interactions i on i.id = ip.interaction_id
      where coalesce(p.primary_email,'') <> ''
        and coalesce(p.relationship_status,'') not in ('archived','dormant','do_not_contact')
      group by p.id
      having greatest(
               coalesce(max(i.occurred_at), 'epoch'::timestamptz),
               coalesce(p.last_contact,      'epoch'::timestamptz)
             ) < now() - interval '45 days'
         and greatest(
               coalesce(max(i.occurred_at), 'epoch'::timestamptz),
               coalesce(p.last_contact,      'epoch'::timestamptz)
             ) > 'epoch'::timestamptz
      order by 6 desc
    $q$, s, s, s, s);

    -- Drafts rotting in the approval queue: unsent, older than 3 days.
    execute format($q$
      create or replace view %I.follow_up_aging as
      select d.id as draft_id, d.kind, d.subject, p.full_name as person,
             d.created_at, (now() - d.created_at)::text as age,
             d.status, d.send_as
      from %I.follow_up_drafts d
      left join %I.people p on p.id = d.person_id
      where d.sent_at is null
        and d.status not in ('sent','dismissed','rejected')
        and d.created_at < now() - interval '3 days'
      order by d.created_at
    $q$, s, s, s);

  end loop;
end $$;

-- One-glance pipeline status (crm_dev only — pending_ingest/ingest_runtime are
-- ingest-side singletons). THE first thing to check when data looks stale:
-- stale data is almost always queued>0 + paused_until in the future, which
-- means an upstream quota/budget limit — not a broken pipeline.
create or replace view crm_dev.pipeline_health as
select
  (select count(*) from crm_dev.pending_ingest)                               as queued,
  (select min(received_at) from crm_dev.pending_ingest)                       as oldest_queued,
  (select max(created_at) from crm_dev.interactions where source='fireflies') as last_successful_ingest,
  (select rate_limited_until from crm_dev.ingest_runtime where id)            as paused_until,
  (select count(*) from crm_dev.follow_up_aging)                              as aging_drafts;
