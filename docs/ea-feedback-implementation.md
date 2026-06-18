# EA feedback loop — implementation cookbook (steps 2 & 4)

Concrete build steps for the two surfaces the feedback loop touches. Design and
rationale live in [`ea-feedback-loop.md`](./ea-feedback-loop.md); schema in
`schemas/ea_feedback.sql` (apply via Supabase SQL Editor — assumed done).

- **Step 2 — capture** lands in the **`agents-dashboard`** repo (Next.js on Vercel).
- **Step 4 — promotion** is a new **n8n** workflow built in the visual editor.

Both read/write the Supabase CRM schema server-side with the **service-role key**
(RLS is on, no anon policy — same posture as `ea_actions` / `follow_up_drafts`).
Use `crm_dev` in dev, `crm` in prod (drive it off an env var).

---

## Step 2 — capture decisions (dashboard repo)

The dashboard already runs approve→send on `ea_actions`. We add one `ea_decisions`
write per resolution, snapshotting the EA's **original** draft and what actually
went out. The one rule that matters: **read the original `payload` before you
overwrite it with the edited version** — that snapshot is the whole signal.

### 2a. Shared helper

```ts
// lib/ea-decisions.ts
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,   // bypasses RLS, server-only
)
const SCHEMA = process.env.CRM_SCHEMA ?? 'crm_dev'   // 'crm' in prod

type Decision = 'approved_clean' | 'approved_edited' | 'rejected' | 'auto_executed'

/** action = the EA's ORIGINAL ea_actions row (payload = the draft, pre-edit). */
export async function recordDecision(args: {
  action: { id: string; type: string; account: string | null; payload: any }
  decision: Decision
  finalPayload?: any | null
  editNote?: string | null
}) {
  const { action, decision, finalPayload = null, editNote = null } = args
  const sender = action.payload?.to?.[0] ?? null      // counterparty, for per-sender learning
  const { error } = await supabase
    .schema(SCHEMA)
    .from('ea_decisions')
    .insert({
      action_id: action.id,
      type: action.type,
      account: action.account,
      sender,
      decision,
      draft_payload: action.payload,   // ORIGINAL proposal — never overwritten
      final_payload: finalPayload,     // what shipped (null when rejected)
      edit_note: editNote,
    })
  if (error) throw error
}
```

### 2b. Approve & Send handler

```ts
// app/api/ea/send/route.ts   (or your existing server action)
import { recordDecision } from '@/lib/ea-decisions'
import { sendViaGraph } from '@/lib/graph'   // the same sender follow-ups use

export async function POST(req: Request) {
  const { id, edited } = await req.json()    // edited = { to, subject, body } from the form

  // 1. Load the ORIGINAL row FIRST — payload here is the EA's draft snapshot.
  const { data: action, error } = await supabase
    .schema(SCHEMA).from('ea_actions')
    .select('id, type, account, payload, source_message_id')
    .eq('id', id).single()
  if (error || !action) return Response.json({ error: 'not found' }, { status: 404 })

  const draft = action.payload
  const final = { ...draft, ...edited }      // what actually goes out (threads via in_reply_to)
  const wasEdited =
    draft.subject !== final.subject ||
    draft.body !== final.body ||
    JSON.stringify(draft.to) !== JSON.stringify(final.to)

  // 2. Send. On failure, mark error and DO NOT record a decision (nothing shipped).
  try {
    await sendViaGraph(final)
  } catch (err: any) {
    await supabase.schema(SCHEMA).from('ea_actions')
      .update({ status: 'error', error: String(err) }).eq('id', id)
    return Response.json({ error: String(err) }, { status: 502 })
  }

  // 3. Mark sent + save the final body back (keeps the existing few-shot working).
  await supabase.schema(SCHEMA).from('ea_actions')
    .update({ status: 'sent', executed_at: new Date().toISOString(), payload: final })
    .eq('id', id)

  // 4. Capture the decision. `action` still holds the ORIGINAL payload in memory.
  await recordDecision({
    action,
    decision: wasEdited ? 'approved_edited' : 'approved_clean',
    finalPayload: final,
  })

  return Response.json({ ok: true })
}
```

### 2c. Discard / reject handler

```ts
// app/api/ea/discard/route.ts
import { recordDecision } from '@/lib/ea-decisions'

export async function POST(req: Request) {
  const { id, reason } = await req.json()
  const { data: action } = await supabase
    .schema(SCHEMA).from('ea_actions')
    .select('id, type, account, payload').eq('id', id).single()
  if (!action) return Response.json({ error: 'not found' }, { status: 404 })

  await supabase.schema(SCHEMA).from('ea_actions')
    .update({ status: 'discarded' }).eq('id', id)
  await recordDecision({ action, decision: 'rejected', finalPayload: null, editNote: reason })
  return Response.json({ ok: true })
}
```

### 2d. Wire the UI

- The `/ea` list's **Approve & Send** button → `POST /api/ea/send` with `{ id, edited }`
  (`edited` = current form values for to/subject/body).
- A **Discard** button → `POST /api/ea/discard` with `{ id, reason? }`.
- `auto_executed` is not written here — it's emitted later by whatever path
  actually auto-sends, once a type+account is promoted. Leave it out for now.

### 2e. Verify

After approving one clean and editing one, in the SQL Editor:

```sql
select decision, type, account, sender,
       left(draft_payload->>'body',40)  as drafted,
       left(final_payload->>'body',40)  as sent
from crm_dev.ea_decisions order by decided_at desc limit 5;
```

You should see one `approved_clean` (drafted == sent) and one `approved_edited`
(drafted != sent). That's the loop capturing signal — **everything downstream
depends only on this table.**

---

## Step 4 — the `ea-feedback` n8n workflow (visual editor)

A daily job that reads the `ea_trust` / `ea_rule_candidates` views and **proposes**
changes — promotions into `attention`, learned rules into `ea_rules(enabled=false)`.
It never acts on its own. It reads tables the EA Router already writes, so
**`ea-router.json` needs no changes** to stand this up.

Build it as two short branches off one trigger:

1. **New workflow** → name `EA Feedback`.

2. **Schedule Trigger** — interval, daily at 06:00 (after the brief, before the
   workday). Keep it off the Router's 30-min clock; learning is a slow loop.

3. **Branch A — promotions.** Off the trigger, add **Postgres → Execute Query**
   (Supabase pooler cred), name `Read trust`:
   ```sql
   SELECT type, account, n_clean
   FROM crm_dev.ea_trust
   WHERE suggested_mode = 'auto'
   ORDER BY account, type;
   ```
   Then **Postgres → Execute Query**, name `File promotion` (runs once per row):
   ```sql
   INSERT INTO crm_dev.attention (type, title, body, source, dedup_key)
   SELECT 'promote',
          'Promote ' || $1 || ' / ' || $2 || ' to auto?',
          $1 || ' for ' || $2 || ' has ' || $3
              || ' clean approvals, 0 edits, 0 rejections.',
          'ea-feedback',
          'promote:' || $1 || ':' || $2
   ON CONFLICT (dedup_key) DO NOTHING;
   ```
   Query params (expression): `{{ [$json.type, $json.account, $json.n_clean] }}`.
   Connect `Read trust → File promotion`.

4. **Branch B — learned rules.** Also off the trigger, add **Postgres → Execute
   Query**, name `Read candidates`:
   ```sql
   SELECT sender, suggested_route, (n_rejected + n_edited) AS evidence
   FROM crm_dev.ea_rule_candidates;
   ```
   Then **Postgres → Execute Query**, name `Insert learned rule` (once per row):
   ```sql
   INSERT INTO crm_dev.ea_rules
     (match_type, match_value, force_route, tone_notes,
      enabled, created_from, evidence_count, notes)
   SELECT 'email', $1, $2,
          CASE WHEN $2 IS NULL
               THEN 'EA keeps editing replies to this sender — add tone guidance' END,
          false, 'learned', $3,
          'Proposed by ea-feedback from ' || $3 || ' corrections'
   ON CONFLICT (match_type, match_value) DO UPDATE
     SET evidence_count = EXCLUDED.evidence_count, updated_at = now();
   ```
   Query params: `{{ [$json.sender, $json.suggested_route, $json.evidence] }}`.
   Connect `Read candidates → Insert learned rule`.

   > The Schedule Trigger's single output fans out to **both** `Read trust` and
   > `Read candidates` — drag two connections from the trigger.

5. **Test** — *Execute Workflow* manually. With little/no data the reads return
   zero rows and nothing is written (correct). Seed a fake run if you want to see
   it fire: temporarily insert 12 `approved_clean` `ea_decisions` for one
   type+account, execute, confirm one `attention` row appears, then delete the
   fakes.

6. **Activate** the workflow, then **export**: `make export-workflows` →
   commit `workflows/ea-feedback.json`. (Build in the editor, export to the repo —
   never hand-edit the JSON.)

### Adopting a promotion (only when you're ready)

The workflow *proposes*; adopting is a deliberate act. When you accept a
"Promote X to auto?" item, the EA Router must start stamping `mode='auto'` for
that (type, account). Wire that only at adoption time:

- Add a tiny `crm_dev.ea_adopted_modes (type, account, mode, adopted_at)` table;
  the dashboard's "Adopt" action inserts a row.
- In the Router's `Fetch Context`, look it up and pass `coalesce(adopted_mode,
  'approve')` into the `ea_actions` INSERT's `mode` (snippet in
  `ea-feedback-loop.md`).

Until you adopt anything, every action stays `approve` — nothing auto-sends by
surprise. Keep `email.send` (especially `account='givesendgo'`) on `approve`
regardless of counts.
