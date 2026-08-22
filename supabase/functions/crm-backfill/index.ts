// =============================================================================
// crm-backfill — Supabase Edge Function (Deno)
//
// Reconciliation sweep: webhooks are best-effort, so calls can be lost (e.g.
// the Aug 2026 Fireflies 429 storm dropped weeks of meetings). This function
// lists recent Fireflies transcripts, diffs them against what the CRM has
// actually ingested, and enqueues anything missing into pending_ingest — the
// regular pg_cron sweep + crm-ingest then do the real work (throttling,
// rate-limit cooldown, Claude synthesis, recap drafts) exactly as for a live
// webhook. Idempotent: already-ingested and already-queued ids are no-ops.
//
// Runs nightly at 00:35 UTC (just after Fireflies' daily quota reset) via
// pg_cron, and can be invoked manually with ?days=N to look further back.
// =============================================================================

import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

const FIREFLIES_API_KEY = Deno.env.get("FIREFLIES_API_KEY")!;
const DB_URL = Deno.env.get("CRM_DB_URL") ?? Deno.env.get("SUPABASE_DB_URL")!;

const sql = postgres(DB_URL, { prepare: false });

const json = (b: unknown, status: number) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

const LIST_QUERY = `
  query($limit: Int, $skip: Int, $fromDate: DateTime) {
    transcripts(limit: $limit, skip: $skip, fromDate: $fromDate) { id title date }
  }`;

Deno.serve(async (req) => {
  const days = Math.min(90, Math.max(1, Number(new URL(req.url).searchParams.get("days") ?? "30")));

  // Honor the shared Fireflies cooldown — never spend quota while rate-limited.
  const [{ rate_limited_until }] = await sql`
    select rate_limited_until from crm_dev.ingest_runtime where id`;
  if (rate_limited_until && new Date(rate_limited_until) > new Date()) {
    return json({ ok: false, skipped: "rate_limited", until: rate_limited_until }, 202);
  }

  try {
    const fromDate = new Date(Date.now() - days * 86400e3).toISOString();
    const found: { id: string; title: string }[] = [];

    // Page through recent transcripts (few cheap list calls, capped defensively).
    for (let skip = 0; skip < 500; skip += 50) {
      const res = await fetch("https://api.fireflies.ai/graphql", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${FIREFLIES_API_KEY}`,
        },
        body: JSON.stringify({ query: LIST_QUERY, variables: { limit: 50, skip, fromDate } }),
      });
      const j = await res.json();
      if (j.errors) throw new Error("Fireflies: " + JSON.stringify(j.errors));
      const batch = j.data?.transcripts ?? [];
      found.push(...batch);
      if (batch.length < 50) break;
    }

    if (!found.length) return json({ ok: true, checked: 0, missing: 0 }, 200);

    const ids = found.map((t) => t.id);
    const have = new Set(
      (await sql`
        select custom->>'fireflies_id' as fid from crm_dev.interactions
        where source='fireflies' and custom->>'fireflies_id' = any(${ids})`)
        .map((r: any) => r.fid),
    );
    const missing = found.filter((t) => !have.has(t.id));

    for (const t of missing) {
      await sql`insert into crm_dev.pending_ingest (fireflies_id) values (${t.id})
                on conflict (fireflies_id) do nothing`;
    }

    console.log(`crm-backfill: checked ${ids.length}, queued ${missing.length}`,
      missing.map((t) => t.title).slice(0, 20));
    return json({
      ok: true, checked: ids.length, missing: missing.length,
      titles: missing.map((t) => t.title),
    }, 200);
  } catch (e) {
    const msg = String(e);
    // A 429 here means quota is already gone today — set the shared cooldown
    // so the ingest sweep also backs off, and try again tomorrow night.
    if (/too_many_requests|too many requests|\b429\b/i.test(msg)) {
      const epoch = msg.match(/"retryAfter":(\d+)/);
      const until = epoch
        ? new Date(Number(epoch[1])).toISOString()
        : new Date(Date.now() + 60 * 60 * 1000).toISOString();
      await sql`update crm_dev.ingest_runtime set rate_limited_until = ${until} where id`;
      return json({ ok: false, skipped: "rate_limited", until }, 202);
    }
    console.error("crm-backfill failed:", e);
    return json({ ok: false, error: msg }, 500);
  }
});
