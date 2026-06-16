// =============================================================================
// scrape-stats — Supabase Edge Function (Deno)
//
// Scrapes the public GiveSendGo campaign page and records fundraising totals
// into the `stats` table. This is a STANDALONE function with NOTHING to do with
// the CRM ingest pipeline — it does not touch `crm` / `crm_dev` or
// `ingest_meeting`. It was previously deployed by mistake under the `crm-ingest`
// slug; it lives under its own `scrape-stats` slug now so the two never collide.
//
// Deploy:  supabase functions deploy scrape-stats --project-ref wxkoetczqcpmnuyhsxvo
// Invoked: on a schedule (pg_cron / pg_net) — sends no Supabase JWT, so
//          verify_jwt = false in config.toml.
// =============================================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
)

const CAMPAIGN_URL = 'https://v2.givesendgo.com/GiverArmyFund'

serve(async () => {
  try {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 5000)

    const html = await fetch(CAMPAIGN_URL, {
      headers: { 'User-Agent': 'GiveSendGoCharities-StatsBot/1.0' },
      signal: controller.signal
    }).then(r => r.text())

    clearTimeout(timeout)

    const totalMatch = html.match(/Total Raised\$([0-9,]+(?:\.\d{2})?)\s*USD/i)
    const monthMatch = html.match(/Raised this month\$([0-9,]+(?:\.\d{2})?)\s*USD/i)
    const giftMatch  = html.match(/Give(\d+)/)

    if (!totalMatch || !monthMatch || !giftMatch) {
      console.error('Parse failed — page structure may have changed')
      console.error('HTML snippet:', html.substring(0, 2000))
      return new Response('Parse failed', { status: 500 })
    }

    const parseDollars = (s: string) =>
      Math.round(parseFloat(s.replace(/,/g, '')) * 100)

    const totalRaisedCents = parseDollars(totalMatch[1])
    const monthRaisedCents = parseDollars(monthMatch[1])
    const giftCount        = parseInt(giftMatch[1], 10)

    const { error } = await supabase.from('stats').insert({
      total_raised_cents: totalRaisedCents,
      month_raised_cents: monthRaisedCents,
      gift_count: giftCount,
      scraped_at: new Date().toISOString(),
    })

    if (error) throw error

    console.log(`Stats scraped: $${totalRaisedCents/100} total, $${monthRaisedCents/100} this month, ${giftCount} gifts`)
    return new Response(
      JSON.stringify({ totalRaisedCents, monthRaisedCents, giftCount }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    console.error('scrape-stats error:', err)
    return new Response('Error: ' + String(err), { status: 500 })
  }
})
