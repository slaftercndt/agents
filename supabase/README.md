# Supabase — CRM/relationship backbone (agent 3)

This directory holds the **edge functions** for the CRM backbone. The database
itself (schemas `crm` + `crm_dev`, the `ingest_meeting(jsonb)` function, tables)
lives in the hosted Supabase project — it is **not** version-controlled here;
apply SQL through the Supabase SQL Editor.

> This is a **separate Postgres** from the n8n database in `docker-compose.yml`.
> n8n's DB backs the Chief of Staff brief queue; Supabase is the CRM source of
> truth that the dashboard and (later) the Chief of Staff read from.

## crm-ingest

`functions/crm-ingest/` — Fireflies webhook → fetch transcript summary → Claude
synthesis → `crm_dev.ingest_meeting(jsonb)`. Hosted in Supabase; fires when a
call is **Summarized**. See the header of `index.ts` for the full flow.

It lives in **this** repo (backend), not the dashboard repo: the Next.js build
type-checks `*.ts` and chokes on Deno URL imports, so keeping it here keeps the
frontend build green.

### Deploy

```bash
# from the repo root (Supabase CLI + login required)
supabase functions deploy crm-ingest --project-ref wxkoetczqcpmnuyhsxvo
```

`verify_jwt = false` is set in `config.toml`, so no `--no-verify-jwt` flag is
needed and Fireflies (which sends no Supabase JWT) can reach the endpoint.

### Secrets (set once on the project — NEVER commit these)

```bash
supabase secrets set \
  FIREFLIES_API_KEY=... \
  ANTHROPIC_API_KEY=sk-ant-... \
  CRM_DB_URL=postgresql://postgres.wxkoetczqcpmnuyhsxvo:<pw>@aws-1-us-west-2.pooler.supabase.com:5432/postgres \
  --project-ref wxkoetczqcpmnuyhsxvo
# Optional: FIREFLIES_WEBHOOK_SECRET=... to verify the x-hub-signature header.
```

### Webhook

Register this URL in Fireflies → Developer Settings → Webhooks (event:
**Summarized**):

```
https://wxkoetczqcpmnuyhsxvo.supabase.co/functions/v1/crm-ingest
```
