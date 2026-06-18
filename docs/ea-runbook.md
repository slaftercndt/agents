# EA runbook — Executive Assistant (agent 2)

The EA is a **router**, not just a drafter. It reads the emails the Chief of Staff
already flagged `needs_reply` and decides, per item, what should happen — then
writes to the matching table. It is **approve-only** for anything that leaves the
building (it drafts/proposes; a human sends). Calendar is phase 2 (bottom).

Spam / no-response-needed never reaches the EA: the **free pre-filter** (drops
read/newsletter) and **Haiku triage** (`ignore`) in the CoS ingest already remove
them, so the EA only spends model budget on items that survived triage.

## The routing decision

One Sonnet pass per surviving email picks exactly one route and produces its
payload. Each route already has a home in the Supabase backbone:

| Route | Meaning | Lands in | Mode |
|---|---|---|---|
| `reply`  | a straightforward email response | `crm_dev.ea_actions` (`type=email.draft`) | approve→send |
| `review` | needs a human decision (proposal, contract, anything judgement-heavy) | `crm_dev.attention` | surfaced, you act |
| `task`   | an action to do that isn't an email | `crm_dev.tasks` | tracked |
| `fyi`    | worth seeing, no action | (left to the brief) | — |
| `ignore` | EA-level false positive | (mark drafted, drop) | — |

Replies are drafted in the **same** pass. The EA never sends; it queues a draft
for approval, files a review item, or opens a task.

## Data flow

```
CoS Ingest (n8n)                 EA Router (n8n, NEW)                  Dashboard
─────────────────                ─────────────────────────           ─────────
email in → triage (Haiku)        Schedule (e.g. */30 work hrs)        /ea  → ea_actions (drafts)
→ store row in brief_items   →   read brief_items needs_reply,    →   /attention → review items
  (now incl. body+message_id)      ea_drafted=false                   tasks view → to-dos
                                 → pull ea_rules + recent approved
                                   sends for that sender (few-shot)
                                 → Sonnet: ROUTE + (if reply) draft
                                 → write to ea_actions | attention
                                   | tasks  (mode='approve' on sends)
                                 → mark brief_items.ea_drafted=true
```

Two databases, both already wired: the EA **reads** n8n's Postgres (`brief_items`,
host `postgres`) and **writes** Supabase (`crm_dev.*`, the pooler cred). EA output
lands in Supabase because that's where the dashboard reads.

## Prereqs (run once)

1. **Supabase SQL Editor** — create the queue (both schemas):
   `schemas/ea_actions.sql` as-is for `crm_dev`, then again with `crm_dev`→`crm`.
2. **n8n Postgres** — add the EA columns to `brief_items`:
   `[WHERE: ~/Developer/Agents]`
   ```bash
   docker compose exec -T postgres psql -U n8n -d n8n < schemas/brief_items.sql
   ```
   (the file is idempotent — re-running only adds the new `body` / `message_id` /
   `ea_drafted` columns).

## CoS Ingest change (so the EA has something to draft from)

`brief_items` didn't store the email body or a message id. Add both at ingest so
the EA can draft a reply and the dashboard can thread it onto the original.

- **Parse Triage** — normalize two more fields next to `from_addr` (shapes differ
  by source, same lesson as `from_addr`):
  ```js
  const body =
    typeof e.text === 'string'     ? e.text :
    e.body?.content                ? e.body.content :        // Outlook / Graph
    e.textHtml || e.html || '';
  const message_id =
    e.internetMessageId ?? e.messageId ?? e.id ?? '';        // Graph / IMAP
  ```
- **Save to Postgres** (still Execute Query — never the column mapper):
  ```sql
  INSERT INTO brief_items (account, priority, from_addr, subject, one_line, classification, body, message_id)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8);
  ```
  Params (expression mode, 8-element array):
  ```
  {{ [$json.account, $json.priority, $json.from_addr, $json.subject, $json.one_line, $json.classification, $json.body, $json.message_id] }}
  ```

## EA workflow (n8n) — node by node

1. **Schedule Trigger** — e.g. every 30 min, business hours. (Keep it off the
   05:30 brief's clock; the EA consumes rows on its own schedule.)
2. **Postgres — read pending** (n8n Postgres cred, Execute Query):
   ```sql
   SELECT id, account, priority, from_addr, subject, body, message_id
   FROM brief_items
   WHERE classification = 'needs_reply' AND ea_drafted = false
   ORDER BY priority ASC, received_at ASC
   LIMIT 20;
   ```
   `priority ASC` keeps **GiveSendGo (1) first** — same rule as the brief.
3. **Build Draft Prompt** (Code node) — see prompt below; one item per email.
4. **Anthropic — draft** (Sonnet, `claude-sonnet-4-6`): system + user from step 3.
   Sonnet for the writing pass; triage already happened on Haiku at ingest.
5. **Parse Draft** (Code node) — pull strict JSON, build the row + `dedup_key`.
6. **Supabase — insert action** (Supabase pooler cred, Execute Query):
   ```sql
   INSERT INTO crm_dev.ea_actions
     (type, account, priority, summary, detail, payload, source_message_id, dedup_key)
   VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8)
   ON CONFLICT (dedup_key) DO NOTHING;
   ```
   Params (8-element array; `payload` is a JSON **string** cast to jsonb):
   ```
   {{ ['email.draft', $json.account, $json.priority, $json.summary, $json.reply_body, JSON.stringify($json.payload), $json.source_message_id, $json.dedup_key] }}
   ```
   `ON CONFLICT (dedup_key) DO NOTHING` makes re-runs safe — the EA never
   re-proposes a reply it already queued (idempotency lesson from crm-ingest).
7. **Postgres — mark drafted** (n8n Postgres cred, Execute Query):
   ```sql
   UPDATE brief_items SET ea_drafted = true WHERE id = $1;
   ```
   Params: `{{ [$json.id] }}`.

### Routing + drafting prompt (Code node → Sonnet)

One call both routes and (when `route=reply`) drafts. `ea_rules` and recent
approved sends are injected so the decision respects your standing rules and the
draft matches your voice (see **Learning**, below).

```js
const it = $json;
const rules    = it.rules    || '(none yet)';   // from the ea_rules lookup
const examples = it.examples || '(none yet)';   // last approved sends to this sender
const routeSystem =
  'You are an Executive Assistant triaging and handling one email for your ' +
  'principal. Decide ONE route, then act. Output STRICT JSON only — no prose, ' +
  'no fences:\n' +
  '{ "route": "reply|review|task|fyi|ignore",\n' +
  '  "summary": "<=12 words",\n' +
  '  "reply_subject": "", "reply_body": "",   // only when route=reply\n' +
  '  "task_title": "", "due_date": "YYYY-MM-DD or empty",  // only when route=task\n' +
  '  "why": "" }                              // only when route=review, what needs a human\n' +
  'Routes: reply = a straightforward response you can draft; review = needs a ' +
  'human decision (proposal, contract, money, commitments); task = a to-do that ' +
  'is not an email; fyi = no action; ignore = not actually actionable.\n' +
  'Drafting rules: match the sender\'s register and the EXAMPLES of how the ' +
  'principal writes; be concise; use ONLY facts in the email — never invent ' +
  'commitments, dates, numbers, or names. You DRAFT/PROPOSE only; a human sends.\n' +
  'Standing rules (obey these):\n' + rules;
const routeUser =
  `From: ${it.from_addr || ''}\nSubject: ${it.subject || ''}\n\n${it.body || ''}\n\n` +
  `--- How the principal has replied to this sender before ---\n${examples}`;
return [{ json: { ...it, routeSystem, routeUser } }];
```

### Parse + route (Code node)

Emits one item tagged with `target` so an n8n **Switch** sends it to the right
INSERT (ea_actions / attention / tasks) — or to "mark drafted" for fyi/ignore.

```js
let text = ($json.content?.[0]?.text ?? $json.text ?? '{}').trim();
const a = text.indexOf('{'), b = text.lastIndexOf('}');
if (a !== -1 && b !== -1) text = text.slice(a, b + 1);
const d = JSON.parse(text);
const src = $json;                        // carries id/account/priority/from_addr/message_id
const route = (d.route || 'fyi').toLowerCase();

const base = { id: src.id, account: src.account, priority: src.priority,
               summary: d.summary || '', source_message_id: src.message_id || '' };

if (route === 'reply') {
  return [{ json: { ...base, target: 'ea_actions',
    reply_body: d.reply_body || '',
    payload: { to: [src.from_addr],
               subject: d.reply_subject || ('Re: ' + (src.subject || '')),
               body: d.reply_body || '', in_reply_to: src.message_id || null },
    dedup_key: 'reply:' + (src.message_id || src.id) }}];
}
if (route === 'review') {
  return [{ json: { ...base, target: 'attention',
    title: src.subject || 'Needs review', why: d.why || '',
    dedup_key: 'review:' + (src.message_id || src.id) }}];
}
if (route === 'task') {
  return [{ json: { ...base, target: 'tasks',
    task_title: d.task_title || (src.subject || 'Follow up'),
    due_date: d.due_date || null }}];
}
return [{ json: { ...base, target: 'none' }}];   // fyi / ignore → just mark drafted
```

The `review` and `task` INSERTs use the same Execute-Query pattern against
`crm_dev.attention` / `crm_dev.tasks` (both already exist). Use
`ON CONFLICT (dedup_key) DO NOTHING` on attention via its existing `dedup_key`
column so a re-run never double-files the same review item.

## Learning (a feedback loop, not a training loop)

The EA does **not** retrain itself. It gets better through three deterministic,
inspectable mechanisms, wired as a single `Fetch Context` node (Supabase cred)
between `EA Read` and `Build Route Prompt`. The query returns **one row per
email** (scalar subqueries) so it stays index-aligned with the email stream:

```sql
SELECT
  (SELECT string_agg(coalesce(force_route,'') || ' ' || coalesce(tone_notes,''), '; ')
     FROM crm_dev.ea_rules r
     WHERE r.enabled
       AND ( (r.match_type='email'   AND r.match_value = $1)
          OR (r.match_type='domain'  AND $1 LIKE '%' || r.match_value)
          OR (r.match_type='pattern' AND $1 ILIKE '%' || r.match_value || '%') )
  ) AS rules,
  (SELECT string_agg(left(detail, 500), E'\n---\n')
     FROM (SELECT detail FROM crm_dev.ea_actions a
            WHERE a.status = 'sent' AND a.payload->>'to' ILIKE '%' || $1 || '%'
            ORDER BY a.executed_at DESC LIMIT 3) ex
  ) AS examples;
-- params: [ from_addr ]
```

`Build Route Prompt` (mode: Run Once for All Items) pairs `$('EA Read').all()[i]`
with `$('Fetch Context').all()[i]` and injects `rules` / `examples` into the prompt.

1. **Standing rules** — `crm_dev.ea_rules` (see `schemas/ea_rules.sql`): per
   sender/domain/pattern, force a route (`always_ignore | review | …`) and add tone
   notes. Curated from the dashboard; the `Fetch Context` query injects matches.
2. **Few-shot from your own approved sends** — the second subquery feeds the last
   3 `ea_actions` rows for that sender with `status='sent'` as EXAMPLES. The more
   you approve, the more drafts sound like you — no training.
3. **Outcome capture** — the dashboard saves the final edited body back to the row
   before marking it `sent`, so #2 learns from what you actually sent.

These three make the EA better at *drafting*. The next loop — capturing the
**correction signal** (draft vs. what you sent, plus rejections) and **graduating**
an action type from `approve` to `auto` once it's earned it — is the
report→approve→auto ladder applied to the EA itself. See
[`ea-feedback-loop.md`](./ea-feedback-loop.md) (schema: `schemas/ea_feedback.sql`).

## Handoff to the dashboard session

The EA needs three surfaces + one execute path in the **agents-dashboard** repo:

> **New: EA router output.** The EA now writes to three tables in `crm_dev`
> (read/write server-side with the service-role key — RLS is on, no anon policy,
> same as `follow_up_drafts`):
>
> 1. **`ea_actions`** — proposed email replies (`status='proposed'`,
>    `mode='approve'`, `type='email.draft'`). Mirror `/drafts` as `/ea`: list
>    `proposed` rows sorted `priority ASC` (GiveSendGo first), let me edit
>    To/Subject/Body (`payload`), **Approve & Send** via the existing MS Graph
>    sender (`lib/graph.ts`). On send: `status='sent'`, `executed_at=now()`; on
>    failure: `status='error'`, `error=...`. If `payload.in_reply_to` is set,
>    thread the reply. **Save the final edited body back to the row** before
>    sending — the EA few-shots off sent bodies.
> 2. **`attention`** — review items the EA filed (proposals/decisions). Surface as
>    a "Needs review" list (it has `title/body/priority/due_at/status/action_*`);
>    let me mark `done`/`dismissed`/`snoozed`.
> 3. **`ea_rules`** — a small CRUD screen so I can add standing rules
>    (`match_type/match_value` → `force_route` + `tone_notes`). This is how I
>    "teach" the EA.
>
> Tasks the EA opens go into the existing `tasks` table — no new screen needed if
> tasks are already shown.

## Phase 2 — calendar (deferred, needs new consent)

Reading the calendar uses the delegated `Calendars.Read` you already granted.
**Moving/creating events needs `Calendars.ReadWrite` added to the shared Entra
app (`27dc90ff-…`) + admin consent in Azure** — do that before wiring calendar
actions. Those actions reuse the same `ea_actions` queue with
`type='calendar.create'|'calendar.move'`, `account='calendar'`, and a `payload`
of event fields; the dashboard executes them via Graph just like email sends.
