// ============================================================
// POST /api/stripe/portal -- open Stripe's billing page
// ============================================================
// Body: { accessToken }. Lets a goalie update their card, see
// invoices, or cancel, on Stripe's own hosted page.

import { stripe, stripeConfigured, siteUrl, verifyUser, getAccessRow } from "../_lib/billing.js";

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!stripeConfigured() || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Payments aren't set up yet." });
    return;
  }

  try {
    const user = await verifyUser((req.body || {}).accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const row = await getAccessRow(user.id);
    if (!row || !row.stripe_customer_id) {
      res.status(404).json({ error: "No billing account found." });
      return;
    }

    const session = await stripe("POST", "/billing_portal/sessions", {
      customer: row.stripe_customer_id,
      return_url: siteUrl(req),
    });

    res.status(200).json({ url: session.url });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Could not open billing." });
  }
}
