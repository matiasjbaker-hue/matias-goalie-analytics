// ============================================================
// GET /api/stripe/plans -- the plans shown on the access screen
// ============================================================
// Reads names and prices straight from Stripe for the price IDs in
// STRIPE_PRICE_IDS, so changing a price never needs a code change.

import { stripe, stripeConfigured, configuredPriceIds } from "../_lib/billing.js";

export default async function handler(req, res) {
  if (!stripeConfigured() || !configuredPriceIds().length) {
    res.status(200).json({
      plans: [],
      error: !stripeConfigured() ? "STRIPE_SECRET_KEY is not set." : "STRIPE_PRICE_IDS is not set.",
    });
    return;
  }

  try {
    const plans = [];
    for (const id of configuredPriceIds()) {
      const price = await stripe("GET", `/prices/${encodeURIComponent(id)}`, { expand: ["product"] });
      if (!price.active) continue;
      plans.push({
        priceId: price.id,
        name: (price.product && price.product.name) || price.nickname || "GoalieIQ",
        description: (price.product && price.product.description) || "",
        amount: price.unit_amount,
        currency: price.currency,
        interval: price.recurring ? price.recurring.interval : null,
        intervalCount: price.recurring ? price.recurring.interval_count : null,
      });
    }
    res.setHeader("Cache-Control", "s-maxage=300, stale-while-revalidate=600");
    res.status(200).json({ plans });
  } catch (error) {
    console.error(error);
    // Safe diagnostics only: Stripe's message (it masks keys itself) and
    // which KIND of key is configured -- never the key itself.
    const key = String(process.env.STRIPE_SECRET_KEY || "");
    const keyType =
      key.startsWith("sk_test_") ? "secret key (test)" :
      key.startsWith("sk_live_") ? "secret key (LIVE)" :
      key.startsWith("rk_") ? "restricted key" :
      key.startsWith("pk_") ? "PUBLISHABLE key (wrong key)" :
      key ? "unrecognized key" : "missing";
    res.status(200).json({
      plans: [],
      error: "Could not load plans.",
      detail: error.message,
      keyType,
      priceIds: configuredPriceIds(),
    });
  }
}
