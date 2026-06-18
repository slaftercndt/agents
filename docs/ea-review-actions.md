# EA review-item actions — draft, forward, edit

Turns a **needs-review** item into something you can act on: AI-draft a reply,
forward the email to your team (and track who owns it), or edit the suggested
action — plus tuning the EA so straightforward mail becomes a **draft** instead
of a review in the first place.

Decisions baked in (from the product call):
- **Draft reply is AI-generated** — reuses the EA's existing Sonnet drafting (your
  voice + few-shot), not a blank template.
- **Forward = "Both"** — sends the original email onward *and* records the owner.
- **Recipients = free entry** — type any address each time; no preset team list.

## The prerequisite that unlocks all of it
A review item must carry the **source email**. Today `crm_dev.attention` stores
only `title` + `body` ("why"). Apply **`schemas/ea_attention_actions.sql`** first
(Supabase SQL Editor, both schemas) — it adds `from_addr / subject / source_body /
source_message_id / account / priority`, an editable `suggested_action`,
`linked_action_id`, and `forwarded_to / forwarded_at / assigned_to`.

---

## Part A — n8n EA Router (so reviews carry the email, and fewer become reviews)

### A1. Make the EA draft more, review less (routing tune)
Right now you have 18 reviews and 0 drafts — the EA is over-routing to `review`.
- **Where:** n8n → EA Router → **Build Route Prompt** (Code node), the `routeSystem` string
- **File path:** built in editor; mirror the change in `docs/ea-runbook.md` prompt block
- Tighten the route definitions so `review` is reserved for genuine decisions:
  ```
  Routes:
  - reply  = you can write a useful response from what's in the email. DEFAULT for
             ordinary correspondence, questions, scheduling, confirmations, intros,
             thank-yous, GiveSendGo donor/charity replies. When in doubt, reply.
  - review = ONLY when a human must decide before any response is safe: contracts,
             money/pricing commitments, legal, or a promise you can't verify.
  - task   = an action that isn't an email.
  - fyi/ignore = no response needed.
  Bias strongly toward `reply`. Most needs_reply mail should produce a draft.
  ```
- Also have the model emit a `suggested_action` for `review` items (one line:
  what it thinks you should do), so the dashboard can show/edit it.

### A2. Write the source email onto review items
- **Where:** n8n → EA Router → **Parse + route** (Code node), the `review` branch
- Add the source fields to the emitted item:
  ```js
  } else if (route === 'review') {
    out.push({ json: Object.assign({}, base, {
      target: 'attention',
      title: o.subject || 'Needs review',
      why: d.why || '',
      from_addr: o.from_addr || '',
      subject: o.subject || '',
      source_body: o.body || '',
      source_message_id: o.message_id || '',
      account: o.account,
      priority: o.priority,
      suggested_action: d.suggested_action || '',
      dedup_key: 'review:' + (o.message_id || o.id) }) });
  }
  ```
- **Where:** n8n → EA Router → **Insert review (attention)** node — widen the INSERT:
  ```sql
  INSERT INTO crm_dev.attention
    (type, title, body, source, dedup_key,
     from_addr, subject, source_body, source_message_id, account, priority, suggested_action)
  SELECT 'review', $1, $2, 'ea', $3, $4, $5, $6, $7, $8, $9, $10
  WHERE $11 = 'attention'
  ON CONFLICT (dedup_key) DO NOTHING;
  ```
  Query params (expression):
  ```
  {{ [$json.title || $json.summary || 'Needs review', $json.why || '', $json.dedup_key || '',
      $json.from_addr || '', $json.subject || '', $json.source_body || '',
      $json.source_message_id || '', $json.account || 'other', $json.priority || 3,
      $json.suggested_action || '', $json.target] }}
  ```
- Then `make export-workflows` and commit `workflows/ea-router.json`.

---

## Part B — dashboard (agents-dashboard repo): three new actions

All server-side with `q` + `schema` from `@/lib/db` and `sendMail` from `@/lib/graph`,
matching `app/api/ea/send/route.ts`. The draft endpoint also calls Anthropic, so
add **`ANTHROPIC_API_KEY`** to the dashboard's Vercel env if it isn't there.

### B1. Draft reply (AI) — `app/api/ea/attention/draft/route.ts`
Loads the review's source email → Sonnet draft → new `ea_actions` row → links back.
```ts
import { NextResponse } from "next/server";
import { q, schema } from "@/lib/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SYS =
  "You are an Executive Assistant drafting ONE reply for your principal. " +
  "Output STRICT JSON only: {\"subject\":\"\",\"body\":\"\"}. Match the sender's " +
  "register, be concise, use ONLY facts in the email — never invent commitments, " +
  "dates, numbers, or names. You draft; a human sends.";

export async function POST(req: Request) {
  const { id } = await req.json();
  const rows = await q(
    `select id, from_addr, subject, source_body, source_message_id, account, priority
       from ${schema}.attention where id = $1`, [id]);
  if (rows.length === 0) return NextResponse.json({ ok:false, error:"not found" }, { status:404 });
  const a = rows[0];

  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "Content-Type":"application/json",
               "x-api-key": process.env.ANTHROPIC_API_KEY!,
               "anthropic-version":"2023-06-01" },
    body: JSON.stringify({ model:"claude-sonnet-4-6", max_tokens:1500, system: SYS,
      messages:[{ role:"user", content:
        `From: ${a.from_addr}\nSubject: ${a.subject}\n\n${a.source_body}` }] }),
  });
  const j = await r.json();
  let t = (j.content?.[0]?.text ?? "{}").trim();
  const f = t.indexOf("{"), l = t.lastIndexOf("}"); if (f>=0&&l>=0) t = t.slice(f,l+1);
  let d:any = {}; try { d = JSON.parse(t); } catch {}

  const payload = { to:[a.from_addr], subject: d.subject || ("Re: "+(a.subject||"")),
                    body: d.body || "", in_reply_to: a.source_message_id || null };
  const ins = await q(
    `insert into ${schema}.ea_actions
       (type, mode, account, priority, summary, detail, payload, source_message_id, dedup_key, status)
     values ('email.draft','approve',$1,$2,$3,$4,$5::jsonb,$6,$7,'proposed')
     on conflict (dedup_key) do nothing
     returning id`,
    [a.account, a.priority, ("Reply: "+(a.subject||"")).slice(0,120), payload.body,
     JSON.stringify(payload), a.source_message_id, "reply-from-review:"+id]);
  const actionId = ins[0]?.id ?? null;

  await q(`update ${schema}.attention set linked_action_id = $2, status='drafted' where id = $1`,
          [id, actionId]);
  return NextResponse.json({ ok:true, action_id: actionId });
}
```
The new draft now appears in `/ea` for the normal Approve & Send (with decision
capture already wired). The review item shows as `drafted` and links to it.

### B2. Forward to team ("Both") — `app/api/ea/attention/forward/route.ts`
Free-entry recipients; sends the email AND records the owner.
```ts
import { NextResponse } from "next/server";
import { q, schema } from "@/lib/db";
import { sendMail } from "@/lib/graph";

export async function POST(req: Request) {
  const { id, recipients, note } = await req.json();   // recipients: string[] typed in the UI
  const to = (recipients ?? []).map((s:string)=>s.trim()).filter(Boolean);
  if (to.length === 0) return NextResponse.json({ ok:false, error:"add a recipient" }, { status:422 });

  const rows = await q(
    `select subject, source_body, from_addr from ${schema}.attention where id=$1`, [id]);
  if (rows.length === 0) return NextResponse.json({ ok:false, error:"not found" }, { status:404 });
  const a = rows[0];

  const body = (note ? note + "\n\n---------- Forwarded ----------\n" : "")
             + `From: ${a.from_addr}\nSubject: ${a.subject}\n\n${a.source_body}`;
  try { await sendMail(to, "Fwd: " + (a.subject || ""), body, []); }
  catch (e) { return NextResponse.json({ ok:false, error:String(e) }, { status:502 }); }

  await q(`update ${schema}.attention
             set forwarded_to=$2, forwarded_at=now(), assigned_to=$3, status='forwarded'
           where id=$1`, [id, to, to[0]]);
  return NextResponse.json({ ok:true, forwarded_to: to });
}
```

### B3. Edit action — `app/api/ea/attention/update/route.ts`
```ts
import { NextResponse } from "next/server";
import { q, schema } from "@/lib/db";

export async function POST(req: Request) {
  const { id, suggested_action, status } = await req.json();
  await q(`update ${schema}.attention
             set suggested_action = coalesce($2, suggested_action),
                 status           = coalesce($3, status)
           where id = $1`, [id, suggested_action ?? null, status ?? null]);
  return NextResponse.json({ ok:true });
}
```

### B4. UI — the Needs-Review screen (`app/ea/...` review list)
Per item, alongside the existing Done / Dismiss / Snooze:
- **Draft reply** → `POST /api/ea/attention/draft {id}` → toast "Draft created", item → `drafted`.
- **Forward** → small modal: free-text recipients (comma-separated) + optional note →
  `POST /api/ea/attention/forward {id, recipients, note}`.
- **Edit action** → inline-editable `suggested_action` field → `POST /api/ea/attention/update {id, suggested_action}`.
- Show `from_addr` / `subject` / `suggested_action` on the card (now that they're stored).

---

## Resulting flow

```
inbound email → EA Router
   ├─ reply  → ea_actions (draft)            → /ea → approve & send  (+ decision capture)
   └─ review → attention (carries the email) → Needs Review:
                  • Draft reply (AI) → ea_actions draft → /ea
                  • Forward (email out + assign owner)
                  • Edit action / Done / Dismiss / Snooze
calls/meetings → follow_up_drafts (recap)    → approve & send
```

## Build order
1. **Apply `schemas/ea_attention_actions.sql`** (Supabase). Nothing else works without the columns.
2. **EA Router A1 (routing tune) + A2 (write the email onto reviews)**, export workflow.
3. **Dashboard B1–B4**, add `ANTHROPIC_API_KEY` to Vercel.

A1 alone will start producing real drafts immediately; B1 lets you rescue the
reviews that should have been replies.
