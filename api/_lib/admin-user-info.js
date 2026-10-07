// ============================================================
// POST /api/admin/user-info -- everything an admin needs about one user
// (served through api/admin/[action].js)
// ============================================================
// Body: { accessToken, targetId }
// Returns the profile, login email and dates, plan/credits from
// goalie_access, the payments Stripe has on record for them, and how
// many games they have. Admin only; uses the service key server-side.

import {
  verifyUser, getProfile, getAccessRow, serviceSelect,
  stripe, stripeConfigured, SUPABASE_URL,
} from "./billing.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function authUser(userId) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
    headers: { apikey: key, Authorization: `Bearer ${key}` },
  });
  if (!res.ok) return null;
  const u = await res.json();
  return u ? { email: u.email || null, created_at: u.created_at || null, last_sign_in_at: u.last_sign_in_at || null } : null;
}

async function stripePayments(customerId) {
  if (!customerId || !stripeConfigured()) return { payments: [], error: null };
  try {
    const charges = await stripe("GET", "/charges", { customer: customerId, limit: 100 });
    const payments = (charges.data || []).map(c => ({
      id: c.id,
      created: c.created ? new Date(c.created * 1000).toISOString() : null,
      amount: c.amount,
      amount_refunded: c.amount_refunded || 0,
      currency: c.currency,
      status: c.status,
      paid: !!c.paid,
      description: c.description || null,
      receipt_url: c.receipt_url || null,
    }));
    return { payments, error: null };
  } catch (error) {
    console.error("Stripe charges lookup failed", error);
    return { payments: [], error: "Couldn't load payments from Stripe." };
  }
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Server isn't configured for this yet." });
    return;
  }

  const { accessToken, targetId } = req.body || {};

  if (typeof targetId !== "string" || !UUID.test(targetId)) {
    res.status(400).json({ error: "Missing user." });
    return;
  }

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const callerProfile = await getProfile(caller.id);
    if (!callerProfile || callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can view account details." });
      return;
    }

    const [profiles, login, access, games] = await Promise.all([
      serviceSelect("profiles", `select=*&id=eq.${encodeURIComponent(targetId)}`),
      authUser(targetId),
      getAccessRow(targetId),
      serviceSelect("Games", `select=id&user_id=eq.${encodeURIComponent(targetId)}`),
    ]);

    const { payments, error: paymentsError } = await stripePayments(access && access.stripe_customer_id);

    // Totals per currency, net of refunds, successful charges only.
    const totals = {};
    payments.filter(p => p.paid && p.status === "succeeded").forEach(p => {
      totals[p.currency] = (totals[p.currency] || 0) + p.amount - p.amount_refunded;
    });

    res.status(200).json({
      profile: profiles[0] || null,
      login,
      access: access
        ? {
            status: access.status || null,
            plan: access.plan || null,
            game_credits: access.game_credits ?? null,
            access_until: access.access_until || null,
            has_stripe: !!access.stripe_customer_id,
            has_subscription: !!access.stripe_subscription_id,
          }
        : null,
      games: games.length,
      payments,
      paymentsError,
      totals,
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Could not load this account." });
  }
}
