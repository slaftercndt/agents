# CLAUDE.md — project context for AI coding sessions

Read this first. It captures the things that aren't obvious from the file tree.

## What this repo is

Infrastructure + version-controlled workflow exports for a system of **four
AI agents** running on **self-hosted n8n**. The agents share one n8n instance,
one Postgres database, and one shared "action schema" convention.

The **reasoning layer is the Claude API** (one API key, stored in n8n on the
server — never in this repo). Triage runs on a cheap model (**Haiku**),
synthesis on a stronger model (**Sonnet**).

## The four agents

Only **Agent 1 is being built**. Agents 2–4 are context — design so they slot
in later **without rework** (same n8n, same Postgres, same action schema), but
**do not build them now**.

1. **Chief of Staff** — *BUILD NOW.* A daily **05:30** morning brief. Reads four
   email accounts + the calendar, triages, and writes **one grouped brief**.
   **Read-only in this phase**: it reports, it does not send or act. Delivered
   to **Telegram/WhatsApp** and a **Notion** page.
2. **Executive Assistant** — *(later)* email/calendar drafting + actions.
3. **CRM / Relationship** — *(later)* meeting notes, minutes, relationship tracking.
4. **Media & Positioning** — *(later)* content drafting + posting.

## Chief of Staff workflow shape (what the infra serves)

Four email accounts — one **Gmail/Workspace**, one **Microsoft 365/Outlook**,
one **NextCloud/IMAP**, and a fourth — each input node tags items with
`{account, priority}`. They merge into one list → a **free pre-filter** drops
read/newsletter items **before any API call** → **Haiku** triages each item
(`needs_reply | fyi | ignore`) → **one Sonnet synthesis pass** writes the brief
in sections **grouped by account** → delivered to Telegram/WhatsApp + Notion.
**One reasoning pass, grouped output.** Keep the pre-filter free to control cost.

## Conventions that MUST hold

- **GiveSendGo Charities is the priority account.** It is `priority: 1` and
  **sorts first in every brief**, ahead of all other accounts. This is a
  product requirement, not a nicety.
- **Shared action schema** (`schemas/action.schema.json`): every agent emits a
  batch of actions, each tagged `mode: auto | approve | report`.
  - `auto` — executes without asking.
  - `approve` — waits for an explicit human yes.
  - `report` — informational only; **the Chief of Staff emits only these** in
    phase 1 (read-only). Emitting in this shape now is what lets agents 2–4
    reuse the approval pipeline unchanged.
- **Model split**: cheap model (Haiku) for per-item triage, stronger model
  (Sonnet) for the single synthesis pass.

## Hard rules (do not violate)

- **Credentials and API keys NEVER go in the repo.** Real secrets live only in
  a **gitignored `.env`**; `.env.example` holds placeholders. Application
  credentials (4 email accounts, Telegram/WhatsApp, Notion, the **Claude API
  key**) are entered in the **n8n UI** and stored encrypted in Postgres — not
  in `.env` and not in any file.
- **Exported workflow JSON must contain no secrets.** n8n strips credentials on
  export; keep it that way. `make export-workflows` is the safe path.
- **Local and prod run the SAME `docker-compose.yml`.** What you test ships.
  Environment differences live only in `.env`.

## Environments

- **Dev**: MacBook, n8n via Docker Desktop. Local repo lives at
  `~/Developer/Agents` (run all `make` commands from there).
  `N8N_HOST=n8n.localhost` → Caddy serves an internal-CA cert (no public DNS).
- **Prod**: rented Ubuntu **VPS**, reached over **Tailscale**, n8n behind
  **Caddy** for automatic HTTPS (Let's Encrypt on a real domain).
- **Git is the source of truth** for BOTH the infrastructure AND the exported
  workflow JSON. Deploy = push to Git, then `make deploy` (SSH → `git pull` →
  `compose up`) on the VPS.

## Layout

```
docker-compose.yml   n8n + Postgres + Caddy (one file, both environments)
Caddyfile            automatic-HTTPS reverse proxy for n8n
.env.example         every variable the stack needs (placeholders only)
harden.sh            VPS hardening: UFW + SSH lockdown + fail2ban (idempotent)
Makefile             make up / deploy / backup / import-workflow / export-workflows
schemas/             shared action schema (the auto|approve|report contract)
workflows/           exported workflow JSON (chief-of-staff.json, etc.)
README.md            the setup runbook, in order
```

## When building the workflow

The n8n nodes are built in the **visual editor** by the user, then exported to
`workflows/`. Don't hand-author node JSON unless asked. Around the workflow,
keep the infra and conventions above intact.
