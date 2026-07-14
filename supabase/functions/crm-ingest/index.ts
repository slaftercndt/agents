// =============================================================================
// crm-ingest — Supabase Edge Function (Deno)
//
// Fireflies webhook -> fetch transcript -> Claude synthesis ->
// crm_dev.ingest_meeting(jsonb). Hosted in Supabase; fires on "Summarized".
//
// HARDENED:
//   - Never writes a hollow meeting. If Fireflies has neither a summary nor
//     transcript sentences yet (call still processing), the row is left in
//     pending_ingest and a 202 "not ready" is returned; the 5-min pg_cron
//     sweep retries later.
//   - Claude output is coerced to a well-formed object before we stamp it,
//     so a non-object / empty model reply can't produce a null-source row.
//   - Falls back to Fireflies' own summary overview as the interaction
//     summary when Claude leaves it blank.
// =============================================================================

import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

const FIREFLIES_API_KEY = Deno.env.get("FIREFLIES_API_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;
const DB_URL = Deno.env.get("CRM_DB_URL") ?? Deno.env.get("SUPABASE_DB_URL")!;
const WEBHOOK_SECRET = Deno.env.get("FIREFLIES_WEBHOOK_SECRET");

const TRANSCRIPT_CHAR_CAP = 14000;

const sql = postgres(DB_URL, { prepare: false });

const json = (b: unknown, status: number) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

async function queue(meetingId: string) {
  await sql`insert into crm_dev.pending_ingest (fireflies_id) values (${meetingId})
            on conflict (fireflies_id) do nothing`;
}

const SUMMARY_QUERY = `
  query($id: String!) {
    transcript(id: $id) {
      id title date duration organizer_email
      meeting_attendees { displayName email }
      summary { overview action_items keywords }
    }
  }`;

const SENTENCES_QUERY = `
  query($id: String!) {
    transcript(id: $id) {
      id title date duration organizer_email
      meeting_attendees { displayName email }
      sentences { speaker_name text }
    }
  }`;

async function ff(query: string, id: string) {
  const res = await fetch("https://api.fireflies.ai/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${FIREFLIES_API_KEY}`,
    },
    body: JSON.stringify({ query, variables: { id } }),
  });
  const j = await res.json();
  if (j.errors) throw new Error("Fireflies: " + JSON.stringify(j.errors));
  return j.data.transcript;
}

function overviewText(t: any): string {
  return (t?.summary?.overview ?? "").toString().trim();
}

function summaryIsEmpty(t: any): boolean {
  const s = t.summary ?? {};
  const overview = (s.overview ?? "").toString().trim();
  const actions = (Array.isArray(s.action_items) ? s.action_items.join("") : (s.action_items ?? "")).toString().trim();
  const keywords = (Array.isArray(s.keywords) ? s.keywords.join("") : (s.keywords ?? "")).toString().trim();
  return !overview && !actions && !keywords;
}

function attendeesBlock(t: any): string {
  return (t.meeting_attendees ?? [])
    .map((a: any) => `- ${a.displayName ?? ""} <${a.email ?? ""}>`).join("\n");
}

function userFromSummary(t: any): string {
  const s = t.summary ?? {};
  const actions = Array.isArray(s.action_items) ? s.action_items.join("\n") : (s.action_items ?? "");
  const keywords = Array.isArray(s.keywords) ? s.keywords.join(", ") : (s.keywords ?? "");
  return `Source: Fireflies AI summary
Meeting: ${t.title ?? "(untitled)"}
Organizer: ${t.organizer_email ?? ""}
Attendees:
${attendeesBlock(t)}

Overview:
${s.overview ?? ""}

Action items:
${actions}

Keywords: ${keywords}`;
}

function userFromSentences(t: any): string {
  const body = (t.sentences ?? [])
    .map((x: any) => `${x.speaker_name ?? ""}: ${x.text ?? ""}`)
    .join("\n")
    .slice(0, TRANSCRIPT_CHAR_CAP);
  return `Source: raw transcript (no AI summary was available)
Meeting: ${t.title ?? "(untitled)"}
Organizer: ${t.organizer_email ?? ""}
Attendees:
${attendeesBlock(t)}

Transcript (may be truncated):
${body}`;
}

const SYNTH_SYSTEM = `You convert meeting input into a STRICT JSON object for a CRM. Output JSON ONLY - no prose, no markdown fences.

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
- ref / org_ref / person_ref / owner_ref / participant_refs are YOUR OWN labels wiring records together inside this one JSON. Use "me" as owner_ref for tasks the user owns.
- Use ONLY attendees and emails present in the input. Never invent people, emails, or facts.
- decisions / discussion_points / key_points are arrays of short strings.
- If the input is a raw transcript, write a tight "summary" yourself from it.
- recap_email is a concise post-meeting recap addressed to the other attendees (to_person_refs).
- If something is unknown, use "" or [] - never guess.`;

async function synthesize(userContent: string): Promise<any> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      // 3000 truncated the JSON on longer meetings, so JSON.parse failed and
      // synthesis silently fell back to {} — no recap_email, no draft. 8000
      // leaves ample room for the full people/tasks/recap payload.
      max_tokens: 8000,
      system: SYNTH_SYSTEM,
      messages: [{ role: "user", content: userContent }],
    }),
  });
  const j = await res.json();
  if (j.type === "error") throw new Error("Anthropic: " + JSON.stringify(j.error));
  let text = (j.content?.[0]?.text ?? "{}").trim();
  const first = text.indexOf("{"), last = text.lastIndexOf("}");
  if (first !== -1 && last !== -1) text = text.slice(first, last + 1);
  try { return JSON.parse(text); } catch { return {}; }
}

async function signatureOk(rawBody: string, header: string | null) {
  if (!WEBHOOK_SECRET) return true;
  if (!header) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return header === hex || header === `sha256=${hex}`;
}

function isPlainObject(v: unknown): v is Record<string, any> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });

  const raw = await req.text();
  if (!(await signatureOk(raw, req.headers.get("x-hub-signature")))) {
    return new Response("bad signature", { status: 401 });
  }

  let body: any = {};
  try { body = JSON.parse(raw); } catch { /* ignore */ }

  // Accept the meeting id under any of the shapes Fireflies has used, so a
  // payload-format change can't silently drop every webhook. Log the shape when
  // we still can't find one, so the next bad payload is visible in the logs.
  const meetingId = body.meetingId ?? body.meeting_id
    ?? body?.data?.meetingId ?? body?.data?.meeting_id ?? body?.id;
  if (!meetingId) {
    console.log("crm-ingest: no meetingId; keys=", JSON.stringify(Object.keys(body ?? {})),
      "eventType=", body?.eventType);
    return json({ ok: false, ignored: "no meetingId" }, 200);
  }

  const ev = (body.eventType ?? "").toString().toLowerCase();
  const isFallback   = ev.includes("fallback");
  // "TranscriptFallback" (the sweep's retry event) contains "transcri", so it
  // MUST be excluded here — otherwise isTranscript wins, the request is merely
  // re-queued, and the sweep can never reach the synthesis path below.
  const isTranscript = ev.includes("transcri") && !ev.includes("summ") && !isFallback;

  if (isTranscript) {
    await queue(meetingId);
    return json({ ok: true, queued: true }, 200);
  }

  try {
    const t = await ff(SUMMARY_QUERY, meetingId);

    let userContent: string;
    let usedFallback = false;

    if (isFallback || summaryIsEmpty(t)) {
      const t2 = await ff(SENTENCES_QUERY, meetingId);
      const hasSentences = Array.isArray(t2.sentences) && t2.sentences.length > 0;
      if (!hasSentences) {
        await queue(meetingId);
        return json({ ok: false, pending: true, reason: "transcript_not_ready" }, 202);
      }
      userContent = userFromSentences({ ...t, sentences: t2.sentences });
      usedFallback = true;
    } else {
      userContent = userFromSummary(t);
    }

    let payload: any = await synthesize(userContent);
    if (!isPlainObject(payload)) payload = {};
    if (!isPlainObject(payload.interaction)) payload.interaction = {};

    if (!String(payload.interaction.summary ?? "").trim()) {
      payload.interaction.summary = overviewText(t);
    }

    const i = payload.interaction;
    const hasContent = !!String(i.summary ?? "").trim()
      || (Array.isArray(i.key_points) && i.key_points.length > 0)
      || (Array.isArray(i.decisions) && i.decisions.length > 0)
      || (Array.isArray(i.discussion_points) && i.discussion_points.length > 0);
    if (!hasContent) {
      await queue(meetingId);
      return json({ ok: false, pending: true, reason: "no_content" }, 202);
    }

    payload.interaction.type = payload.interaction.type ?? "meeting";
    payload.interaction.source = "fireflies";
    payload.interaction.occurred_at = t.date
      ? new Date(t.date).toISOString() : new Date().toISOString();
    payload.interaction.custom = {
      ...(isPlainObject(payload.interaction.custom) ? payload.interaction.custom : {}),
      fireflies_id: t.id,
      title: t.title ?? null,
      duration: t.duration ?? null,
      ingest_source: usedFallback ? "transcript" : "summary",
    };

    const [{ interaction_id }] = await sql`
      select crm_dev.ingest_meeting(${ sql.json(payload) }::jsonb) as interaction_id`;

    await sql`delete from crm_dev.pending_ingest where fireflies_id = ${meetingId}`;

    return json({ ok: true, interaction_id, via: usedFallback ? "transcript" : "summary" }, 200);
  } catch (e) {
    console.error("crm-ingest failed:", e);
    return json({ ok: false, error: String(e) }, 500);
  }
});
