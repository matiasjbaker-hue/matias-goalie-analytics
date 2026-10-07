// ============================================================
// What an AI call cost, and the ledger it's written to
// ============================================================
// Every Anthropic answer reports its token counts (`usage`). Pricing
// them here means a video's cost is known as soon as its AI work is
// done, instead of waiting for the console's daily total. Rows go to
// public.ai_usage (supabase/migrations/20261008_ai_costs.sql) with the
// service key; if that table isn't there yet, the AI still works and
// the cost is just not recorded.
//
// USD per million tokens, from Anthropic's pricing page. Update this
// table when prices change; the Batches API is half of these.

import { SUPABASE_URL } from "./supabase.js";

const PRICES = {
  "claude-fable-5-1": { input: 10, output: 50 },
  "claude-opus-5-5": { input: 4, output: 20 },
  "claude-opus-5": { input: 5, output: 25 },
  "claude-sonnet-5-5": { input: 2, output: 10 },
  "claude-sonnet-5": { input: 2, output: 10 },
};

// Longest matching name first, so "claude-opus-5" doesn't price an
// "claude-opus-5-5" answer.
const NAMES = Object.keys(PRICES).sort((a, b) => b.length - a.length);

function priceFor(model) {
  const m = String(model || "");
  const name = NAMES.find(n => m === n || m.startsWith(`${n}-`) || m.startsWith(`${n}@`));
  return name ? PRICES[name] : null;
}

export function tokensOf(usage) {
  const u = usage || {};
  return {
    input: Number(u.input_tokens) || 0,
    output: Number(u.output_tokens) || 0,
    cacheRead: Number(u.cache_read_input_tokens) || 0,
    cacheWrite: Number(u.cache_creation_input_tokens) || 0,
  };
}

export function addTokens(a, b) {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheRead: a.cacheRead + b.cacheRead,
    cacheWrite: a.cacheWrite + b.cacheWrite,
  };
}

export const NO_TOKENS = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

// Dollars for these tokens, or null if the model's price isn't listed.
export function costOf(model, tokens, batch = false) {
  const p = priceFor(model);
  if (!p) return null;
  const perToken = (tokens.input + tokens.cacheWrite * 1.25 + tokens.cacheRead * 0.1) * p.input + tokens.output * p.output;
  return Math.round(perToken / 1e6 * (batch ? 0.5 : 1) * 1e6) / 1e6;
}

// Writes one ledger row. Never throws: a missing table or a hiccup must
// not fail the AI call it describes.
export async function logAiUsage({ gameVideoId, requestedBy, kind, model, batch = false, batchId = null, tokens }) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const usd = costOf(model, tokens, batch);
  if (!key) return usd;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/ai_usage${batchId ? "?on_conflict=batch_id" : ""}`, {
      method: "POST",
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
        Prefer: batchId ? "resolution=ignore-duplicates,return=minimal" : "return=minimal",
      },
      body: JSON.stringify({
        game_video_id: Number.isInteger(Number(gameVideoId)) && gameVideoId !== null ? Number(gameVideoId) : null,
        requested_by: requestedBy || null,
        kind,
        model: model || null,
        batch,
        batch_id: batchId,
        input_tokens: tokens.input,
        output_tokens: tokens.output,
        cache_read_tokens: tokens.cacheRead,
        cache_write_tokens: tokens.cacheWrite,
        usd,
      }),
    });
    if (!res.ok) console.warn(`AI cost not recorded (ai_usage ${res.status}): ${(await res.text()).slice(0, 200)}`);
  } catch (error) {
    console.warn("AI cost not recorded:", error.message);
  }
  return usd;
}
