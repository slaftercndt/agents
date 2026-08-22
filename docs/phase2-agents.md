# Phase 2 build specs — EA replies, robust Chief of Staff, Media agent

The n8n flows below are built in the **visual editor** (per CLAUDE.md), then
exported to `workflows/`. This doc is the paint-by-numbers spec: node order,
exact SQL, prompts, and the data contracts each flow must honor. The backbone
pieces they depend on (`send_accounts`, `send_as`, `recipients`,
`relationship_decay`, `follow_up_aging`, `crm-backfill`) are already live.

Conventions that hold everywhere:

- **Model split**: Haiku for per-item triage/classification, ONE Sonnet pass
  per flow for synthesis. Never Sonnet-per-item.
- **Everything outbound is `mode: approve`** in phase 2. No agent sends
  anything without a human yes in the dashboard. (`report` stays for briefs.)
- **GiveSendGo Charities sorts first** in every brief and every queue.
- Credentials live in the n8n UI / Vercel — never in exported JSON.

---

## 1. Executive Assistant — reply drafter (build FIRST)

**What it does:** every email Haiku triages as `needs_reply` gets a
Sonnet-drafted reply written into `ea_actions` as an approvable action. The
dashboard already has the send rails (send_accounts routing, Gmail SMTP +
Graph); this flow is the producer.

**Where it lives:** extends the existing Chief of Staff workflow — branch off
after the Haiku triage node (do NOT re-fetch or re-triage).

**Flow (n8n):**

1. **IF node** after triage: `classification == "needs_reply"`.
2. **Collect** the needs_reply items into one list (Merge/Aggregate node).
3. **One Claude (Sonnet) call** with all items batched. System prompt core:

   > You draft email replies for Nathan Slafter. For each input email, write a
   > reply he could send with at most one small edit. Match the sender's
   > formality. Be concise; propose concrete next steps or times when asked.
   > Never invent facts, commitments, or prices. If a reply genuinely can't be
   > drafted without information you don't have, output an empty body and a
   > `blocking_question` instead. Output STRICT JSON:
   > `{"replies":[{"source_message_id":"","account":"","to":"","subject":"","body":"","blocking_question":""}]}`

4. **Postgres node** — insert one row per reply into the CRM backbone
   (`crm_dev.ea_actions` in dev, `crm.ea_actions` in prod):

   ```sql
   insert into crm_dev.ea_actions
     (agent, type, mode, status, account, priority, summary, detail, payload,
      source_message_id, dedup_key, send_as)
   values
     ('ea', 'email_reply', 'approve', 'proposed',
      {{account}}, {{priority}},                -- from the ingest tagging
      {{'Re: ' + subject}}, {{blocking_question or ''}},
      {{ jsonb payload: {to, subject, body, in_reply_to: source_message_id} }},
      {{source_message_id}},
      'reply:' || {{source_message_id}},        -- dedup: one draft per email ever
      {{account}})                              -- default From = receiving account
   on conflict (dedup_key) do nothing;
   ```

   The `on conflict do nothing` on `dedup_key` is what makes re-runs safe.

5. Morning brief gains one line per account section: "N replies drafted,
   waiting in the dashboard."

**Dashboard side (agents-dashboard repo):** an "Inbox replies" section listing
`ea_actions where status='proposed' and type='email_reply'`, with the
`send_as` dropdown (from `send_accounts`) → approve → route by transport →
mark `status='executed', executed_at=now()`. Same router as recap sends.

**Cost:** ~10–30 Haiku items + one Sonnet batch per run. Pennies.

---

## 2. Chief of Staff — from one brief to a living loop

### 2a. Midday delta brief (12:30)

Clone of the 05:30 workflow with two changes:

- Pre-filter adds `received > today 05:30` — only NEW items since the morning
  brief. Calendar node pulls remaining-today events only.
- Sonnet prompt: "This is a MIDDAY DELTA, not a full brief. Only what changed:
  new needs_reply, new meetings/moves, anything urgent. If nothing meaningful
  changed, output exactly: NO_DELTA." → IF node drops NO_DELTA (no message).

Silence is a feature: no delta, no ping.

### 2b. Pre-meeting briefs (the CRM payoff)

**Flow (n8n), schedule every 15 min, 07:00–18:00:**

1. Calendar node: events starting in the next 30–45 min with ≥1 external
   attendee (domain != your accounts).
2. Dedup guard (workflow static data or a `briefed_events` table) so each
   event briefs once.
3. **Postgres node** against the CRM backbone, per attendee email:

   ```sql
   select p.full_name, p.relationship_notes, p.relationship_status,
          i.occurred_at, i.summary, i.decisions,
          t.title as open_task, t.due_date,
          d.subject as pending_draft
   from crm_dev.people p
   left join crm_dev.interaction_participants ip on ip.person_id = p.id
   left join crm_dev.interactions i on i.id = ip.interaction_id
   left join crm_dev.tasks t on t.person_id = p.id and t.status = 'open'
   left join crm_dev.follow_up_drafts d on d.person_id = p.id and d.sent_at is null
   where lower(p.primary_email) = any({{attendee_emails}})
   order by i.occurred_at desc
   limit 12;
   ```

4. **One Sonnet call**: "Prep Nathan for this meeting in under 150 words:
   who they are, where the relationship stands, what was last discussed/decided,
   open loops (tasks, unsent follow-ups), and the one thing to accomplish."
5. Telegram/WhatsApp: `📋 In 30 min: {title} — {brief}`.

First-time attendees (no CRM row) get: "No history — first contact." That is
itself useful signal.

### 2c. Morning brief additions (SQL only, no new flow)

Append to the 05:30 synthesis input, from the backbone:

- `select * from crm_dev.follow_up_aging limit 10` → "N drafts waiting >3
  days — oldest: X (Nathan Slafter <> Y)".
- `select full_name, silence from crm_dev.relationship_decay limit 5` →
  "Going quiet: ..." (weekly on Monday is enough if daily is noisy).

---

## 3. Media & Positioning — weekly digest agent

**What it does:** turns the week's actual activity into content raw material.
Read-only + `approve` drafts; posting stays manual in phase 2.

**Flow (n8n), Friday 15:00:**

1. **Postgres**: the week's meetings —
   `select summary, key_points, decisions from crm_dev.interactions
    where occurred_at > now() - interval '7 days' order by occurred_at`.
2. **One Sonnet call** (this agent earns a bigger single pass):

   > From this week's meeting record, produce: (1) three insight/story
   > candidates worth telling publicly — for each: the hook, the audience, and
   > which platform (LinkedIn / X / newsletter); (2) one drafted LinkedIn post
   > in Nathan's voice for the strongest candidate; (3) any positioning risks
   > observed this week. NEVER include confidential specifics: no dollar
   > amounts, no unannounced partnerships, no names of private individuals
   > without clear public context. Flag anything borderline instead of using it.

3. Insert the drafted post into `crm_dev.ea_actions`
   (`agent='media', type='content_draft', mode='approve'`), full digest to
   Telegram + Notion.

The confidentiality clause in the prompt is load-bearing: this agent reads
private meeting data and writes for public channels. Everything it emits goes
through the approve queue, never auto-post.

---

## Build order & effort

| # | Piece | Where | Effort |
|---|-------|-------|--------|
| 1 | EA reply drafter | n8n (extend CoS flow) + dashboard section | ~half day |
| 2 | Pre-meeting briefs | n8n new flow | ~2 hrs |
| 3 | Morning brief additions (2c) | n8n SQL nodes | ~30 min |
| 4 | Midday delta | n8n clone | ~1 hr |
| 5 | Media weekly digest | n8n new flow | ~2 hrs |

Each lands independently. After each build: `make export-workflows` and commit.
