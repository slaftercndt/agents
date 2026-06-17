# Notion sync runbook — tasks (phase 1, one-way)

**Principle: Supabase is the source of truth. Notion is a human-facing mirror.**
The EA, the dashboard, and the CRM all read/write Supabase; this workflow projects
`crm.tasks` into a Notion database so you can browse and work them. Notion is never
the master — phase 1 only pushes Supabase → Notion.

## The Notion database you must create first

In your Notion CRM page, create a **database** (table) named e.g. **Tasks**, with
these properties (names + types matter — the workflow maps to them exactly):

| Property | Type | Maps from `crm.tasks` |
|---|---|---|
| `Name` | Title | `title` |
| `Status` | Select | `status` (open / in_progress / waiting / done) |
| `Due` | Date | `due_date` |
| `Priority` | Select | `priority` (low / medium / high) |
| `Source` | Select | `created_from` (ea / fireflies / manual …) |
| `Notes` | Text | `description` |

Add the Select options as you go (Notion auto-creates them on first write in newer
API versions; if yours doesn't, pre-add the values above). Then:

1. **Share the database with your Notion integration** (•••→ Connections → your
   integration) — the same integration token n8n's `notionApi` credential uses.
   Without this the API returns 404/unauthorized.
2. **Get the database id**: open the DB as a full page; the id is the 32-char hex
   in the URL (`notion.so/<workspace>/<DATABASE_ID>?v=…`). Hyphenated or not both work.

## Wiring (n8n) — workflow `Notion Task Sync`

```
Every 15 min → Read dirty tasks → Prep Notion call → Notion upsert → Pair writeback → Write back page id
```

- **Read dirty tasks** (Supabase cred): selects tasks where `notion_page_id IS NULL`
  (never synced) OR `updated_at > last_synced_at` (changed since last sync).
- **Prep Notion call** (Code): builds the Notion `properties` and decides the call —
  `POST /v1/pages` (create) when there's no `notion_page_id`, else
  `PATCH /v1/pages/{id}` (update). No IF node — method/url are computed per task.
- **Notion upsert** (HTTP, `notionApi` cred): one node, dynamic method + url.
- **Pair writeback** (Code): pairs each Notion response `id` back to its `task_id`
  (index-aligned with Prep).
- **Write back page id** (Supabase cred): `UPDATE crm.tasks SET notion_page_id=…,
  last_synced_at=now()` so the link persists and the task stops re-syncing until it
  changes again.

### One-time setup after import

1. `make import-workflow WORKFLOW=notion-task-sync.json` on the VPS.
2. In the workflow, set the database id: open **Prep Notion call** and replace
   `REPLACE_WITH_NOTION_TASKS_DB_ID` with your real DB id.
3. Assign credentials: **Read dirty tasks** + **Write back page id** → **Supabase
   CRM** (pooler); **Notion upsert** → **notionApi**.
4. **Execute Workflow** once; confirm rows appear in the Notion DB and that
   `crm_dev.tasks.notion_page_id` populated. Then **Publish**.

## Phase 2 (later) — two-way "done"

Add a second workflow that polls the Notion DB (or a Notion webhook) for tasks
checked `done`, and flips `status='done'` in `crm.tasks`. Conflict rule stays
simple because each surface owns a field: the EA/CRM own creation + content,
Notion owns the "done" checkbox. Build only after phase 1 is proven.

## Prod cutover

Phase 1 targets `crm_dev`. For prod, switch the two Postgres queries (`Read dirty
tasks`, `Write back page id`) from `crm_dev.tasks` → `crm.tasks`, in lockstep with
the rest of the prod cutover.
