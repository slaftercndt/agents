# EA feedback loop — teaching the Executive Assistant

How the EA gets better without ever retraining a model. This builds on the three
mechanisms already in `docs/ea-runbook.md` (standing rules, few-shot from sent
bodies, outcome capture) and adds the two pieces that were missing: **capturing
the correction signal** and **graduating action types down the trust ladder**.

> Phase note: this is the **EA (agent 2)**. The Chief of Staff stays read-only
> (`report`-only) — it does not draft, approve, or send. The CoS's only job here
> is to keep producing clean `brief_items` so the EA has good signal to learn from.

## The one idea: the `mode` ladder *is* the learning curve

The shared action schema's `mode: report → approve → auto` is not just an
execution flag — it is a graduation ladder for trust, applied **per (type,
account)**:

| mode | meaning | who lives here |
|---|---|---|
| `report` | observe and tell you | Chief of Staff, phase 1 |
| `approve` | propose a concrete action; you say yes / edit / no | the EA today |
| `auto` | proven right enough times that you stop being asked | the EA, *earned* per type+account |

"Teaching the EA" = moving specific action types down this ladder **as evidence
accumulates**, and never wholesale. `email.draft` for GiveSendGo can reach `auto`
long before `email.send` for a cold outbound ever should.

## Apply the schema

```sql
-- Supabase SQL Editor, run once. Either:
--   schemas/ea_feedback.sql   (run as-is for crm_dev, then again with crm_dev -> crm)
-- or just re-run the one-shot, which now includes it:
--   schemas/ea_apply_all.sql  (covers both schemas in a loop, idempotent)
```

This adds `ea_decisions`, two columns on `ea_rules` (`created_from`,
`evidence_count`), and the `ea_trust` / `ea_rule_candidates` views.

## The loop, end to end

```
EA Router (n8n)          You (dashboard / Telegram)        EA Feedback (n8n, NEW)
───────────────          ──────────────────────────       ──────────────────────
proposes draft     →     approve clean / edit / reject     daily schedule
(mode='approve')         → writes ea_decisions row    →    read ea_trust:
                           (draft snapshot + final)          type+account earned 'auto'?
                                                       →    file "promote?" to attention
        ↑                                                   read ea_rule_candidates:
        │                                              →    insert LEARNED ea_rules
   Fetch Context  ←── ea_rules (incl. learned, once ──┘     (enabled=false) + attention
   injects rules +     you enable) + recent corrections
   corrections         from ea_decisions
```

Two halves: **capture** (event-driven, at the moment you act) and **promotion**
(scheduled mining). Capture is where the signal is created; promotion is where it
turns into proposed behavior change — always human-gated.

---

## Half 1 — Capture (dashboard, `agents-dashboard` repo)

The dashboard already runs the approve→send loop on `ea_actions`. The only change
is to **write an `ea_decisions` row whenever an action resolves**, snapshotting
both the EA's draft and what actually went out. This is the signal we were
throwing away (the edited body currently overwrites the draft in place).

Handoff note for the dashboard session:

> **New: capture decisions.** On every resolution of an `ea_actions` row, also
> `insert into crm_dev.ea_decisions` (service-role, server-side — RLS is on, no
> anon policy, same as `ea_actions`):
>
> | you did | `decision` | `final_payload` |
> |---|---|---|
> | Approve & Send, body unchanged | `approved_clean` | the sent payload |
> | edited then sent | `approved_edited` | the **edited** payload |
> | discarded | `rejected` | `null` |
> | (later) sent automatically on `mode='auto'` | `auto_executed` | the sent payload |
>
> Always set `draft_payload` to the EA's **original** `payload` (snapshot it
> before you let me edit), plus `type`, `account`, and `sender` (the counterparty
> address — `payload.to[0]` for a reply). Keep saving the final edited body back
> to `ea_actions` too; that still feeds the few-shot. `ea_decisions` is the new,
> non-destructive record of the *delta*.

A lightweight alternative capture surface (no dashboard change) is **Telegram
inline buttons** on the queued-draft notification (✅ / ✏️ / ❌) whose callback
writes the same `ea_decisions` row. Use whichever you'll actually click; the
dashboard is recommended because it's already the approve→send surface.

---

## Half 2 — Promotion (new n8n workflow: `ea-feedback`)

A scheduled workflow that reads the two views and **proposes** changes. It writes
nothing that acts on its own — promotions land in `attention` for your yes, and
learned rules land in `ea_rules` **disabled**. Node by node:

1. **Schedule Trigger** — daily, e.g. 06:00 (after the brief, before the workday).
   Keep it off the EA Router's 30-min clock; learning is a slow loop.

2. **Read trust** (Supabase cred, Execute Query):
   ```sql
   SELECT type, account, n_total, n_clean, n_edited, n_rejected, clean_rate
   FROM crm_dev.ea_trust
   WHERE suggested_mode = 'auto'
   ORDER BY account, type;
   ```

3. **File promotion suggestion** (Supabase cred, Execute Query) — one `attention`
   item per earned type+account, idempotent so a daily re-run never double-files:
   ```sql
   INSERT INTO crm_dev.attention (type, title, body, source, dedup_key)
   SELECT 'promote',
          'Promote ' || $1 || ' / ' || $2 || ' to auto?',
          $1 || ' for ' || $2 || ' has ' || $3 || ' clean approvals, 0 edits, 0 rejections. '
              || 'Approving flips new actions of this type+account to mode=auto.',
          'ea-feedback',
          'promote:' || $1 || ':' || $2
   ON CONFLICT (dedup_key) DO NOTHING;
   ```
   Params: `{{ [$json.type, $json.account, $json.n_clean] }}`.
   You adopt a promotion from the dashboard's review screen; adopting it sets the
   EA Router to stamp `mode='auto'` for that (type, account) — see the Router
   change below. (A demotion is automatic the moment an `auto_executed` row turns
   into a reject: `suggested_mode` drops back to `approve` on the next run.)

4. **Read rule candidates** (Supabase cred, Execute Query):
   ```sql
   SELECT sender, n_rejected, n_edited, suggested_route FROM crm_dev.ea_rule_candidates;
   ```

5. **Insert learned rules, disabled** (Supabase cred, Execute Query) — proposed,
   not active; you flip `enabled=true` in the dashboard's `ea_rules` screen to
   adopt:
   ```sql
   INSERT INTO crm_dev.ea_rules
     (match_type, match_value, force_route, tone_notes, enabled, created_from, evidence_count, notes)
   SELECT 'email', $1, $2,
          CASE WHEN $2 IS NULL THEN 'EA keeps editing replies to this sender — add tone guidance' END,
          false, 'learned', $3,
          'Proposed by ea-feedback from ' || $3 || ' corrections'
   ON CONFLICT (match_type, match_value) DO UPDATE
     SET evidence_count = EXCLUDED.evidence_count, updated_at = now();
   ```
   Params: `{{ [$json.sender, $json.suggested_route, ($json.n_rejected + $json.n_edited)] }}`.
   `ON CONFLICT … DO UPDATE` just refreshes the evidence count on an existing
   candidate so it never duplicates and you can see the case strengthen.

This workflow **slots in without touching `ea-router.json`**: it reads the same
tables the Router writes, and only the two tiny Router/dashboard hooks below
change.

### Two small hooks that close the loop

- **EA Router — stamp the earned mode.** Today the Router inserts every reply at
  the table default (`mode='approve'`). To honor an adopted promotion, look up the
  earned mode when building the row. Add to `Fetch Context`:
  ```sql
  , (SELECT 'auto' FROM crm_dev.ea_trust t
       WHERE t.type='email.draft' AND t.account = $2 AND t.suggested_mode='auto'
       LIMIT 1) AS earned_mode
  ```
  (param `$2` = the email's `account`) and pass `coalesce(earned_mode,'approve')`
  into the `ea_actions` INSERT's `mode`. Gate it behind your adoption so only
  promotions you accepted take effect — e.g. an `ea_adopted_modes` flag table the
  promotion approval writes to, checked here. Until you adopt anything, everything
  stays `approve`; nothing auto-sends by surprise.
- **Dashboard — write the decision.** Covered in Half 1.

---

## The enhanced prompt-injection block

The Router's `Fetch Context` already injects matching `ea_rules` and the last 3
sent bodies. Two upgrades make corrections part of the prompt, and keep your
priority convention (GiveSendGo first) explicit. Replace the `Fetch Context`
query's subqueries with:

```sql
SELECT
  -- standing rules: learned ones included only once you've enabled them;
  -- ordered so manual rules (yours) win ties over learned ones.
  (SELECT string_agg(
       '- ' || coalesce(force_route,'') || ' ' || coalesce(tone_notes,''),
       E'\n' ORDER BY created_from DESC)               -- 'manual' > 'learned'
     FROM crm_dev.ea_rules r
     WHERE r.enabled
       AND ( (r.match_type='email'   AND r.match_value = $1)
          OR (r.match_type='domain'  AND $1 LIKE '%' || r.match_value)
          OR (r.match_type='pattern' AND $1 ILIKE '%' || r.match_value || '%') )
  ) AS rules,
  -- few-shot of GOOD examples: bodies you sent untouched are the cleanest signal.
  (SELECT string_agg(left(coalesce(d.final_payload->>'body', a.detail), 500), E'\n---\n')
     FROM crm_dev.ea_decisions d
     JOIN crm_dev.ea_actions a ON a.id = d.action_id
    WHERE d.decision = 'approved_clean' AND d.sender = $1
    ORDER BY d.decided_at DESC LIMIT 3
  ) AS examples,
  -- corrections: where you EDITED the draft. The draft->final delta is the lesson.
  (SELECT string_agg(
       'DRAFTED: ' || left(d.draft_payload->>'body', 300) ||
       E'\nYOU SENT: ' || left(d.final_payload->>'body', 300), E'\n===\n')
     FROM crm_dev.ea_decisions d
    WHERE d.decision = 'approved_edited' AND d.sender = $1
    ORDER BY d.decided_at DESC LIMIT 2
  ) AS corrections;
-- params: [ from_addr, account ]   ($2 = account, used by the earned_mode lookup)
```

Then in `Build Route Prompt`, append a corrections block to the system prompt so
the model learns from what you changed, not just what you accepted:

```js
const corrections = c.corrections || '';
// ...after the existing "Standing rules" + examples blocks:
const routeSystem = baseSystem +
  '\nStanding rules (obey these), GiveSendGo first:\n' + rules +
  (corrections
    ? '\n--- Corrections: the principal edited these drafts. Match the SENT ' +
      'version, not the drafted one — internalize the change ---\n' + corrections
    : '');
```

Why this shape: **clean sends** teach voice (positive), **corrections** teach the
specific delta you keep making (the highest-value signal), and **enabled rules**
are hard constraints. All three are deterministic and inspectable — no training,
nothing the model can drift on between runs.

## What to build first (highest ROI)

1. **Capture decisions** in the dashboard (Half 1). You cannot learn from
   corrections you do not record — pure upside even before promotion exists.
2. **Add the corrections block** to `Fetch Context` + the prompt. Once a week or
   two of decisions exist, this alone removes the edits you keep making by hand.
3. **Build `ea-feedback`** (Half 2) to surface promotions and learned rules.
4. **Wire the earned-mode hook** only once a type+account has genuinely earned it
   and you want to stop clicking Approve for it.

## Guardrails (do not skip)

- **Promotion is human-gated, always.** The loop proposes (`attention` /
  disabled `ea_rules`); you adopt. This is the `report → approve → auto`
  discipline applied to the rules themselves — a couple of stray clicks must
  never silently change behavior.
- **`email.send` is not `email.draft`.** Graduate drafting to `auto` freely;
  be far stricter about anything that leaves the building. Consider never letting
  `email.send` auto-fire for `account='givesendgo'` regardless of counts.
- **One bad `auto_executed` demotes the type** — `ea_trust` requires zero
  rejections in the window, so a single bad auto-send drops `suggested_mode` back
  to `approve` on the next daily run. That's the safety valve; keep it.
