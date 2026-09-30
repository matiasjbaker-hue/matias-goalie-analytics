// ============================================================
// BILLING HELPERS (shared by api/stripe/*)
// ============================================================
// Files under api/_lib are not deployed as endpoints (leading "_").
//
// Talks to Stripe's REST API with fetch (no SDK dependency) and to
// Supabase two ways:
//   - with the caller's own token, to prove who they are;
//   - with the SERVICE ROLE key, only to write goalie_access after a
//     verified Stripe event. The service key never reaches the browser.
//
// Vercel environment variables:
//   STRIPE_SECRET_KEY          sk_test_... / sk_live_...
//   STRIPE_WEBHOOK_SECRET      whsec_... (from the webhook endpoint)
//   STRIPE_PRICE_IDS           price_...,price_... (plans to offer, in order)
//   SUPABASE_SERVICE_ROLE_KEY  Supabase -> Project Settings -> API keys
//   SITE_URL                   https://goalieiqanalytics.com

import crypto from "crypto";

export const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
export const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

// Keep access for a couple of days past the billing date so a renewal
// that's a few hours late (or a card retry) never locks a goalie out.
const GRACE_SECONDS = 3 * 24 * 60 * 60;

export function stripeConfigured() {
  return !!process.env.STRIPE_SECRET_KEY;
}

export function configuredPriceIds() {
  return String(process.env.STRIPE_PRICE_IDS || "")
    .split(",")
    .map(s => s.trim())
    .filter(Boolean);
}

export function siteUrl(req) {
  const fromEnv = String(process.env.SITE_URL || "").trim().replace(/\/+$/, "");
  if (fromEnv) return fromEnv;
  const host = req && req.headers && (req.headers["x-forwarded-host"] || req.headers.host);
  return host ? `https://${host}` : "https://goalieiqanalytics.com";
}

// Stripe wants application/x-www-form-urlencoded with bracketed keys:
// { line_items: [{ price: "p", quantity: 1 }] } -> line_items[0][price]=p&...
export function encodeForm(obj, prefix = "", out = []) {
  for (const [key, value] of Object.entries(obj)) {
    if (value === undefined || value === null) continue;
    const name = prefix ? `${prefix}[${key}]` : key;
    if (Array.isArray(value)) {
      value.forEach((item, i) => {
        if (item !== null && typeof item === "object") {
          encodeForm(item, `${name}[${i}]`, out);
        } else {
          out.push(`${encodeURIComponent(`${name}[${i}]`)}=${encodeURIComponent(item)}`);
        }
      });
    } else if (typeof value === "object") {
      encodeForm(value, name, out);
    } else {
      out.push(`${encodeURIComponent(name)}=${encodeURIComponent(value)}`);
    }
  }
  return out.join("&");
}

export async function stripe(method, path, params) {
  const url = `https://api.stripe.com/v1${path}`;
  const opts = {
    method,
    headers: {
      Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}`,
    },
  };
  let finalUrl = url;
  if (params && method === "GET") {
    finalUrl += (url.includes("?") ? "&" : "?") + encodeForm(params);
  } else if (params) {
    opts.headers["Content-Type"] = "application/x-www-form-urlencoded";
    opts.body = encodeForm(params);
  }
  const res = await fetch(finalUrl, opts);
  const data = await res.json();
  if (!res.ok) {
    const msg = data && data.error && data.error.message ? data.error.message : `Stripe error ${res.status}`;
    throw new Error(msg);
  }
  return data;
}

export async function verifyUser(accessToken) {
  if (!accessToken) return null;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) return null;
  const data = await res.json();
  return data && data.id ? data : null;
}

function serviceHeaders(extra = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
}

export async function serviceSelect(table, query) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${encodeURIComponent(table)}?${query}`, {
    headers: serviceHeaders(),
  });
  if (!res.ok) throw new Error(`Supabase ${res.status} reading ${table}`);
  return res.json();
}

export async function getAccessRow(userId) {
  const rows = await serviceSelect("goalie_access", `select=*&user_id=eq.${encodeURIComponent(userId)}`);
  return rows[0] || null;
}

export async function getProfile(userId) {
  const rows = await serviceSelect("profiles", `select=id,role,full_name&id=eq.${encodeURIComponent(userId)}`);
  return rows[0] || null;
}

export async function upsertAccess(row) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/goalie_access?on_conflict=user_id`, {
    method: "POST",
    headers: serviceHeaders({
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates,return=minimal",
    }),
    body: JSON.stringify({ ...row, updated_at: new Date().toISOString() }),
  });
  if (!res.ok) {
    throw new Error(`Supabase ${res.status} writing goalie_access: ${await res.text()}`);
  }
}

// Newer Stripe API versions moved current_period_end onto the
// subscription item; older ones have it on the subscription.
function periodEnd(sub) {
  if (sub.current_period_end) return sub.current_period_end;
  const item = sub.items && sub.items.data && sub.items.data[0];
  return item && item.current_period_end ? item.current_period_end : null;
}

// Stripe subscription -> goalie_access fields. Returns null when the
// subscription shouldn't change access yet (e.g. first payment still
// processing), so an incomplete checkout never revokes a free account.
export function accessFromSubscription(sub) {
  const end = periodEnd(sub);
  const until = end ? new Date((end + GRACE_SECONDS) * 1000).toISOString() : null;
  const price = sub.items && sub.items.data && sub.items.data[0] && sub.items.data[0].price;
  const plan = price ? (price.nickname || (price.product && price.product.name) || price.id) : null;

  switch (sub.status) {
    case "active":
    case "trialing":
    case "past_due":
      return { status: "active", access_until: until, plan };
    case "canceled":
    case "unpaid":
    case "incomplete_expired":
      return { status: "canceled", access_until: null, plan };
    default: // incomplete, paused
      return null;
  }
}

// Stripe-Signature: t=timestamp,v1=hex(hmac_sha256(secret, `${t}.${rawBody}`))
export function verifyStripeSignature(rawBody, header, secret, toleranceSeconds = 300) {
  if (!header || !secret) return false;
  const parts = Object.fromEntries(
    String(header).split(",").map(kv => {
      const i = kv.indexOf("=");
      return [kv.slice(0, i).trim(), kv.slice(i + 1).trim()];
    }).filter(([k]) => k)
  );
  const signatures = String(header).split(",")
    .map(kv => kv.trim())
    .filter(kv => kv.startsWith("v1="))
    .map(kv => kv.slice(3));
  const t = Number(parts.t);
  if (!t || !signatures.length) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - t) > toleranceSeconds) return false;
  const expected = crypto.createHmac("sha256", secret).update(`${t}.${rawBody}`, "utf8").digest("hex");
  return signatures.some(sig => {
    const a = Buffer.from(sig, "hex");
    const b = Buffer.from(expected, "hex");
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  });
}
