// ============================================================
// POST /api/stripe/checkout -- buy game credits (one-time payment)
// ============================================================
// Body: { accessToken, priceId }. The goalie is identified from their
// own Supabase session, never from anything else in the request.
// Credits are added later by the webhook, only after Stripe confirms.

import {
  stripe, stripeConfigured, configuredPriceIds, siteUrl,
  verifyUser, getProfile, getAccessRow, checkoutAllowedFor,
} from "../_lib/billing.js";

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!stripeConfigured() || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Payments aren't set up yet." });
    return;
  }

  const { accessToken, priceId } = req.body || {};

  if (!configuredPriceIds().includes(priceId)) {
    res.status(400).json({ error: "Unknown plan." });
    return;
  }

  try {
    const user = await verifyUser(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    if (!checkoutAllowedFor(user.email)) {
      res.status(403).json({ error: "Online payments open soon. Start with your free game for now, or request access." });
      return;
    }

    const profile = await getProfile(user.id);
    if (!profile || profile.role !== "goalie") {
      res.status(403).json({ error: "Only goalie accounts can buy games." });
      return;
    }

    const existing = await getAccessRow(user.id);

    const site = siteUrl(req);

    const params = {
      mode: "payment",
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: `${site}/?checkout=success`,
      cancel_url: `${site}/?checkout=cancel`,
      client_reference_id: user.id,
      metadata: { user_id: user.id },
      payment_intent_data: { metadata: { user_id: user.id } },
      invoice_creation: { enabled: "true" }, // receipt + history in Billing
      allow_promotion_codes: "true",
    };

    if (existing && existing.stripe_customer_id) {
      params.customer = existing.stripe_customer_id;
    } else {
      params.customer_creation = "always";
      if (user.email) params.customer_email = user.email;
    }

    const session = await stripe("POST", "/checkout/sessions", params);
    res.status(200).json({ url: session.url });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Could not start checkout." });
  }
}
