// ============================================================
// GET /api/stripe/plans -- the plans shown on the access screen
// ============================================================
// Reads names and prices straight from Stripe for the price IDs in
// STRIPE_PRICE_IDS, so changing a price never needs a code change.

import { stripe, stripeConfigured, configuredPriceIds } from "../_lib/billing.js";

export default async function handler(req, res) {
  if (!stripeConfigured() || !configuredPriceIds().length) {
    res.status(200).json({ plans: [] });
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
    res.status(200).json({ plans: [], error: "Could not load plans." });
  }
}
