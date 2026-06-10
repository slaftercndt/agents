# Agents — self-hosted n8n AI agent stack

Infrastructure and version-controlled workflow exports for a four-agent system
on self-hosted **n8n**. **Phase 1 builds Agent 1, the Chief of Staff**: a daily
05:30 morning brief that reads four email accounts + the calendar, triages, and
writes one grouped brief (GiveSendGo Charities first), delivered to
Telegram/WhatsApp and Notion. **Read-only** in this phase — it reports, it does
not act.

> New here? Read [`CLAUDE.md`](./CLAUDE.md) for the full vision, conventions,
> and hard rules (the big one: **credentials and API keys never go in Git**).

## Stack

| Component  | Role                                              |
|------------|---------------------------------------------------|
| PostgreSQL | n8n's database (not SQLite) — shared by all agents |
| n8n        | workflow engine + Claude API orchestration        |
| Caddy      | automatic-HTTPS reverse proxy in front of n8n      |

Local dev (MacBook/Docker) and production (Ubuntu VPS) run the **same**
`docker-compose.yml`. The only difference is the gitignored `.env`.

---

## Local development (MacBook)

```bash
cp .env.example .env          # then edit .env:
                              #   N8N_HOST=n8n.localhost
                              #   set POSTGRES_PASSWORD (openssl rand -base64 24)
                              #   set N8N_ENCRYPTION_KEY (openssl rand -hex 32)
make up                       # start n8n + Postgres + Caddy
```

Open **https://n8n.localhost**. Caddy serves a local-CA cert, so your browser
warns once — trust it, or run `make trust-local-cert` (macOS) to silence it.
Create the n8n owner account, build the workflow, then:

```bash
make export-workflows         # write secret-free JSON into ./workflows/
git add workflows/ && git commit -m "chief of staff workflow"
```

---

## Production runbook (in order)

Do these steps in sequence. **Do not put any credential on the box until after
hardening (step 2).**

### 1. Provision the VPS
Rent an Ubuntu VPS. Create a non-root sudo user and copy your SSH key up:

```bash
ssh-copy-id youruser@<vps-ip>     # MUST succeed before step 2
```

### 2. Harden the box (before any secret touches it)
Copy the repo (or just `harden.sh`) to the VPS and run it as root:

```bash
sudo ./harden.sh
```

This sets up:
- **UFW**: allow only SSH (22) + HTTP (80) + HTTPS (443), deny everything else.
- **SSH**: key-only auth, password auth disabled, `PermitRootLogin no`. (The
  script refuses to disable passwords unless it finds your key first, so you
  can't lock yourself out.)
- **fail2ban**: bans SSH brute-forcers.

**Open a fresh SSH session to confirm you still have access before closing the
current one.**

### 3. Tailscale
Put the VPS on your tailnet so you administer it privately (n8n's admin UI is
reached over Tailscale; only 80/443 are public, for Caddy's certs):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Note the VPS's Tailscale name/IP — put it in `VPS_SSH` in your **local** `.env`
for `make deploy`.

### 4. Bring up the stack
On the VPS, clone the repo and create the **production** `.env`:

```bash
git clone <repo-url> ~/agents && cd ~/agents
cp .env.example .env          # edit: real domain in N8N_HOST, real ACME_EMAIL,
                              # strong POSTGRES_PASSWORD, real N8N_ENCRYPTION_KEY
```

Point your domain's DNS A/AAAA record at the VPS, then:

```bash
make up
```

Caddy fetches a Let's Encrypt cert automatically. Visit `https://<your-domain>`.

> From now on, deploy from your MacBook with `make deploy` (SSH → `git pull` →
> `docker compose pull` → `up -d`). Secrets are never transmitted — the VPS
> keeps its own `.env`.

### 5. Enable n8n 2FA
In the n8n UI: create the owner account → **Settings → enable two-factor
authentication**. Do this before adding any credentials.

### 6. Set the Claude API spend cap
In the **Anthropic Console**, set a monthly spend limit / budget alert on the
API key *before* wiring it into n8n. The Chief of Staff makes many Haiku calls;
the cap is your safety net.

### 7. Import the workflow
Once `chief-of-staff.json` is in `workflows/`:

```bash
make import-workflow WORKFLOW=chief-of-staff.json
```

### 8. Connect the credentials (in the n8n UI — never in Git)
Add these as n8n credentials. They're stored encrypted in Postgres:

1. **Gmail / Google Workspace** (email account 1)
2. **Microsoft 365 / Outlook** (email account 2)
3. **NextCloud / IMAP** (email account 3) — plus the fourth account
4. **Calendar**, **Telegram/WhatsApp** (delivery), **Notion** (brief page), and
   the **Claude API key** (one key; Haiku for triage, Sonnet for synthesis).

Re-open the imported workflow and attach each credential where prompted.

---

## Everyday commands

```bash
make up                 # start the stack
make down               # stop (keeps data)
make logs               # tail logs
make ps                 # service status
make backup             # timestamped pg_dump -> ./backups/ (gitignored)
make import-workflow WORKFLOW=chief-of-staff.json
make export-workflows   # pull workflows out of n8n into ./workflows (secret-free)
make deploy             # ship to the VPS over SSH/Tailscale
```

## Backups & disaster recovery

- `make backup` dumps Postgres to `./backups/<timestamp>.sql.gz`. Postgres holds
  your workflows AND the encrypted credential store.
- **Back up `N8N_ENCRYPTION_KEY` separately** (it's in `.env`, which is *not* in
  Git). Without it, a restored DB can't decrypt credentials.
- Caddy's certs live in the `caddy_data` volume; they regenerate automatically
  if lost.
