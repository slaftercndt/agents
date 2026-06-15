// =============================================================================
// crm-ingest — Supabase Edge Function (Deno)
//
// Fireflies webhook -> fetch transcript summary -> Claude synthesis ->
// crm_dev.ingest_meeting(jsonb). Runs hosted INSIDE Supabase and fires the
// moment a call's transcript is summarized. No n8n and no laptop in this path.
//
// This is the CRM/relationship backbone's ingest (agent 3). It lives here in the
// `agents` repo (backend), NOT in the dashboard repo — the Next.js build can't
// type-check Deno URL imports, so keeping it out of the frontend keeps that
// build green.
//
// Deploy (from the repo root, secrets already set on the project):
//   supabase functions deploy crm-ingest --project-ref wxkoetczqcpmnuyhsxvo
// verify_jwt is disabled via supabase/config.toml so Fireflies (which sends no
// Supabase JWT) can reach it.
//
// Secrets (set once on the project, NOT in this repo):
//   supabase secrets set FIREFLIES_API_KEY=... ANTHROPIC_API_KEY=sk-ant-... \
//     CRM_DB_URL=postgresql://postgres.<ref>:<pw>@<pooler-host>:5432/postgres \
//     --project-ref wxkoetczqcpmnuyhsxvo
//   FIREFLIES_WEBHOOK_SECRET is OPTIONAL — if set, x-hub-signature is verified.
// =============================================================================

import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

const FIREFLIES_API_KEY = Deno.env.get("FIREFLIES_API_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const DB_URL = Deno.env.get("CRM_DB_URL") ?? Deno.env.get("SUPABASE_DB_URL")!;
const WEBHOOK_SECRET = Deno.env.get("FIREFLIES_WEBHOOK_SECRET"); // optional

// One pooled client, reused across warm invocations. prepare:false keeps it
// compatible with the connection pooler.
const sql = postgres(DB_URL, { prepare: false });

// --- Fireflies: pull ONLY the summary + attendees (not full sentences) ------
// Keeps the Claude call cheap and means the raw transcript never enters our DB.
const TRANSCRIPT_QUERY = `
  query($id: String!) {
    transcript(id: $id) {
      id title date duration organizer_email
      meeting_attendees { displayName email }
      summary { overview action_items keywords }
    }
  }`;

async function fetchTranscript(id: string) {
  const res = await fetch("https://api.fireflies.ai/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${FIREFLIES_API_KEY}`,
    },
    body: JSON.stringify({ query: TRANSCRIPT_QUERY, variables: { id } }),
  });
  const json = await res.json();
  if (json.errors) throw new Error("Fireflies: " + JSON.stringify(json.errors));
  return json.data.transcript;
}

// --- Claude: meeting summary -> strict CRM JSON matching ingest_meeting ------
// NOTE: suggested_relationship_status is deliberately omitted — that column is
// an enum and a hallucinated value would throw. ingest_meeting() treats its
// absence as null.
const SYNTH_SYSTEM = `You convert a meeting summary into a STRICT JSON object for a CRM. Output JSON ONLY — no prose, no markdown fences.

Schema:
{
  "organizations": [{ "ref": "o1", "name": "", "type": "", "notes": "" }],
  "people": [{
    "ref": "p1", "full_name": "", "emails": ["..."],
    "relationship_notes": "",
    "organizations": [{ "org_ref": "o1", "role": "", "is_primary": true }]
  }],
  "interaction": {
    "type": "meeting", "summary": "",
    "decisions": ["..."], "discussion_points": ["..."], "key_points": ["..."],
    "notes": "", "organization_ref": "o1", "participant_refs": ["p1","p2"]
  },
  "tasks": [{
    "title": "", "description": "", "status": "open",
    "due_date": "YYYY-MM-DD or empty", "priority": "high|medium|low or empty",
    "person_ref": "p1", "owner_ref": "me"
  }],
  "recap_email": { "subject": "", "body": "", "to_person_refs": ["p1"] }
}

Rules:
- ref / org_ref / person_ref / owner_ref / participant_refs are YOUR OWN labels that wire records together inside this one JSON. Use "me" as owner_ref for tasks the user owns.
- Use ONLY attendees and emails present in the input. Never invent people, emails, or facts.
- decisions / discussion_points / key_points are arrays of short strings.
- recap_email is a concise post-meeting recap the user could send, addressed to the other attendees (to_person_refs).
- If something is unknown, use "" or [] — never guess.`;

function buildSynthUser(t: any) {
  const attendees = (t.meeting_attendees ?? [])
    .map((a: any) => `- ${a.displayName ?? ""} <${a.email ?? ""}>`).join("\n");
  const s = t.summary ?? {};
  const actions = Array.isArray(s.action_items) ? s.action_items.join("\n") : (s.action_items ?? "");
  const keywords = Array.isArray(s.keywords) ? s.keywords.join(", ") : (s.keywords ?? "");
  return `Meeting: ${t.title ?? "(untitled)"}
Organizer: ${t.organizer_email ?? ""}
Attendees:
${attendees}

Overview:
${s.overview ?? ""}

Action items:
${actions}

Keywords: ${keywords}`;
}

async function synthesize(t: any) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 3000,
      system: SYNTH_SYSTEM,
      messages: [{ role: "user", content: buildSynthUser(t) }],
    }),
  });
  const json = await res.json();
  if (json.type === "error") throw new Error("Anthropic: " + JSON.stringify(json.error));
  let text = (json.content?.[0]?.text ?? "{}").trim();
  // Be forgiving: extract the outermost { ... } in case of fences/prose.
  const first = text.indexOf("{"), last = text.lastIndexOf("}");
  if (first !== -1 && last !== -1) text = text.slice(first, last + 1);
  return JSON.parse(text);
}

// --- optional Fireflies signature verification ------------------------------
async function signatureOk(rawBody: string, header: string | null) {
  if (!WEBHOOK_SECRET) return true;     // not configured -> skip
  if (!header) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return header === hex || header === `sha256=${hex}`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });

  const raw = await req.text();
  if (!(await signatureOk(raw, req.headers.get("x-hub-signature")))) {
    return new Response("bad signature", { status: 401 });
  }

  let body: any = {};
  try { body = JSON.parse(raw); } catch { /* ignore */ }

  // We subscribe to Fireflies' "Summarized" event only, so every webhook that
  // arrives is one we want. Process whenever a meetingId is present.
  const meetingId = body.meetingId;
  if (!meetingId) return new Response("ignored: no meetingId", { status: 200 });

  try {
    const t = await fetchTranscript(meetingId);
    const payload = await synthesize(t);

    // Deterministic meta — never trust the model for these. fireflies_id is the
    // idempotency key ingest_meeting() de-dupes on.
    payload.interaction = payload.interaction ?? {};
    payload.interaction.source = "fireflies";
    payload.interaction.occurred_at = t.date
      ? new Date(t.date).toISOString() : new Date().toISOString();
    payload.interaction.custom = {
      ...(payload.interaction.custom ?? {}),
      fireflies_id: t.id,
      title: t.title ?? null,
      duration: t.duration ?? null,
    };

    const [{ interaction_id }] = await sql`
      select crm_dev.ingest_meeting(${ JSON.stringify(payload) }::jsonb) as interaction_id`;

    return new Response(JSON.stringify({ ok: true, interaction_id }),
      { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("crm-ingest failed:", e);
    return new Response(JSON.stringify({ ok: false, error: String(e) }),
      { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
