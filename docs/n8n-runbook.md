# n8n runbook — hard-won decisions (don't re-derive these)

This file pins decisions that were already settled through painful trial-and-error.
If you (human or AI) are about to "figure out" one of these again, stop and read.

## Chief of Staff — workflow shape

- **Two workflows:**
  - **Ingest** — triggered by **incoming email** (IMAP / Outlook email-trigger nodes,
    one per account). Tags `{account, priority}` → pre-filter → Haiku triage →
    Parse Triage → writes to `brief_items`.
  - **Brief** — **Schedule trigger, daily 05:30.** Reads `brief_items` (unbriefed) →
    one Sonnet synthesis → Telegram + Notion → marks rows briefed.
- The CRM meeting ingest (Fireflies) is **NOT** in n8n — it's the Supabase Edge
  Function `supabase/functions/crm-ingest`. Don't rebuild it here.

## The four email accounts

| Account | Node type | priority | Notes |
|---|---|---|---|
| GiveSendGo (`nathan@givesendgo.org`) | **Microsoft Outlook** (OAuth2) | **1** (sorts first) | M365 has IMAP/basic-auth disabled → must use Graph OAuth, NOT IMAP |
| Gmail (new) | IMAP + app password | 2 | 2-Step Verification required to mint an app password |
| Gmail (`nslafter@gmail.com`) | IMAP + app password | 3 | host `imap.gmail.com`, port 993, SSL |
| NextCloud | IMAP + password | 4 | host/port from the mail provider |

## `Save to Postgres` node — USE EXECUTE QUERY (not the column mapper)

The column mapper auto-includes `id` and sends `id=0` → **duplicate key** error.
Settled solution: **Execute Query**.

- **Operation:** Execute Query
- **Query:**
  ```sql
  INSERT INTO brief_items (account, priority, from_addr, subject, one_line, classification)
  VALUES ($1, $2, $3, $4, $5, $6);
  ```
- **Query Parameters** (expression mode, must be a 6-element **array** — a
  comma-separated string sends only `$1` and throws "there is no parameter $2"):
  ```
  {{ [$json.account, $json.priority, $json.from_addr, $json.subject, $json.one_line, $json.classification] }}
  ```
- Leave `id` (BIGSERIAL), `received_at` (default now()), `briefed` (default false)
  **unmapped** — they fill themselves.

## `from_addr` normalization — handle BOTH shapes

The sender field differs by source. IMAP gives a string; Microsoft Outlook/Graph
gives a nested object. Normalize in Parse Triage so `from_addr` is always a string:

```js
const f = e.from;
const from_addr =
  typeof f === 'string'    ? f :
  f?.emailAddress?.address ? f.emailAddress.address :   // Outlook / Graph
  f?.value?.[0]?.address   ? f.value[0].address     :   // IMAP parsed
  f?.text || '';
```

An empty `from_addr` does NOT break the INSERT (stores `""`) — so it won't block a
test run; it just means the normalization missed that source's shape.

## n8n Postgres credential (its own DB, for `brief_items`)

- **Host:** `postgres` (the Docker **service name** — NOT `localhost`, NOT the
  public domain). n8n and Postgres share the compose network.
- **Database:** `n8n` · **User:** `n8n` · **Port:** `5432` · **SSL:** Disable.
- The Supabase CRM DB is a **separate** credential (host
  `aws-1-...pooler.supabase.com`, user `postgres.<ref>`, SSL on) — only needed when
  the brief starts reading `crm.tasks`.

## Migration / ops gotchas (VPS)

- **Moving n8n between machines: migrate the DATABASE, don't rebuild.**
  `pg_dump` the source n8n DB → restore into the target → done. Fresh-start means
  re-importing workflows and re-entering every credential; only choose it if there's
  nothing to keep.
- **Encryption key must match the data.** Credentials are encrypted with
  `N8N_ENCRYPTION_KEY`. It lives in BOTH the env var and `/home/node/.n8n/config`;
  if they disagree n8n won't boot ("Mismatching encryption keys") — delete the
  config file so it regenerates from the env var. To migrate credentials, the target
  key must equal the source key. (Current key is the insecure placeholder
  `change-me-...` — **rotate it** once stable.)
- **`docker compose restart` does NOT reload `.env`.** Use
  `docker compose up -d --force-recreate <svc>` to pick up changed env values.
- **Postgres password desync** ("password authentication failed for user n8n"):
  the data volume keeps the password from its FIRST init; if `.env` changed later,
  re-sync the role:
  ```bash
  PW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
  docker compose exec -T postgres psql -U n8n -d n8n -c "ALTER USER n8n WITH PASSWORD '$PW';"
  docker compose up -d --force-recreate n8n
  ```
- **`make` must be installed** on the VPS (`sudo apt install -y make`); Docker group
  membership needs a re-login before `docker` works without sudo (verify with
  `docker run --rm hello-world`, not `docker compose version`).
- **Safe Browsing:** `avodah.cloud` was flagged "Dangerous" (false positive on a
  fresh domain / recycled IP). It breaks OAuth callbacks (n8n "OAuth callback state
  is invalid"). To complete an OAuth connect, temporarily set Chrome Safe Browsing to
  "No protection", finish, re-enable. False-positive reports filed; clears on Google's
  timeline.

## Entra app (shared)

One app registration (`27dc90ff-...`, tenant `8292e2c5-...`) serves both:
- **app-only `Mail.Send`** → dashboard's approve→send (client credentials).
- **delegated `Mail.Read` / `Calendars.Read`** → n8n reading the GiveSendGo mailbox.
- Set to **Multiple Entra ID tenants** (n8n's OAuth uses the `/common` endpoint;
  single-tenant throws AADSTS50194). Redirect URI:
  `https://n8n.avodah.cloud/rest/oauth2-credential/callback`.
