// ============================================================
// POST /api/stripe/webhook -- Stripe tells us about payments
// ============================================================
// The ONLY place paid access is granted or removed. Every event is
// signature-checked, then the subscription is re-fetched from Stripe
// so out-of-order or replayed events can't set the wrong state.
//
// Stripe events to send (Stripe dashboard -> Developers -> Webhooks):
//   checkout.session.completed
//   checkout.session.async_payment_succeeded
//   customer.subscription.created
//   customer.subscription.updated
//   customer.subscription.deleted
//   invoice.paid
//   invoice.payment_failed

import {
  stripe, verifyStripeSignature, accessFromSubscription,
  upsertAccess, serviceSelect, getProfile, serviceRpc,
} from "../_lib/billing.js";

// Signature checking needs the exact raw body.
export const config = { api: { bodyParser: false } };

// Read the stream directly and never touch req.body first: on Vercel,
// accessing req.body parses the JSON, and the re-serialized text would
// no longer match Stripe's signature.
async function readRawBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

// Older API versions put the subscription on invoice.subscription;
// newer ones on invoice.parent.subscription_details.subscription.
function invoiceSubscriptionId(invoice) {
  const direct = invoice.subscription;
  if (direct) return typeof direct === "string" ? direct : direct.id;
  const nested = invoice.parent && invoice.parent.subscription_details && invoice.parent.subscription_details.subscription;
  if (nested) return typeof nested === "string" ? nested : nested.id;
  return null;
}

async function findUserId(sub, hint) {
  if (hint) return hint;
  if (sub.metadata && sub.metadata.user_id) return sub.metadata.user_id;
  const bySub = await serviceSelect("goalie_access", `select=user_id&stripe_subscription_id=eq.${encodeURIComponent(sub.id)}`);
  if (bySub[0]) return bySub[0].user_id;
  const customer = typeof sub.customer === "string" ? sub.customer : sub.customer && sub.customer.id;
  if (customer) {
    const byCustomer = await serviceSelect("goalie_access", `select=user_id&stripe_customer_id=eq.${encodeURIComponent(customer)}`);
    if (byCustomer[0]) return byCustomer[0].user_id;
  }
  return null;
}

async function syncSubscription(subscriptionId, userIdHint) {
  const sub = await stripe("GET", `/subscriptions/${encodeURIComponent(subscriptionId)}`, {
    expand: ["items.data.price.product"],
  });

  const userId = await findUserId(sub, userIdHint);
  if (!userId) {
    console.warn("Stripe subscription with no matching GoalieIQ user:", sub.id);
    return;
  }

  const profile = await getProfile(userId);
  if (!profile) {
    console.warn("Stripe subscription for a deleted profile:", userId);
    return;
  }

  const access = accessFromSubscription(sub);
  if (!access) return; // still processing -- don't touch existing access

  await upsertAccess({
    user_id: userId,
    ...access,
    stripe_customer_id: typeof sub.customer === "string" ? sub.customer : sub.customer && sub.customer.id,
    stripe_subscription_id: sub.id,
  });
}

// One-time purchase of game credits. Credits per product come from the
// product's "credits" metadata. grant_game_credits() is idempotent per
// checkout session, so a replayed event never adds credits twice.
async function grantCredits(session) {
  if (session.payment_status !== "paid") return; // async payment still pending

  const userId = session.client_reference_id || (session.metadata && session.metadata.user_id);
  if (!userId) {
    console.warn("Paid checkout with no GoalieIQ user:", session.id);
    return;
  }

  const profile = await getProfile(userId);
  if (!profile) {
    console.warn("Paid checkout for a deleted profile:", userId);
    return;
  }

  const items = await stripe("GET", `/checkout/sessions/${encodeURIComponent(session.id)}/line_items`, {
    limit: 100,
    expand: ["data.price.product"],
  });

  let credits = 0;
  for (const item of items.data || []) {
    const product = item.price && typeof item.price.product === "object" ? item.price.product : null;
    const perUnit = parseInt((product && product.metadata && product.metadata.credits) || "0", 10) || 0;
    credits += perUnit * (item.quantity || 1);
  }

  if (credits <= 0) {
    console.warn("Paid checkout with no game credits on its products:", session.id);
    return;
  }

  await serviceRpc("grant_game_credits", {
    p_user: userId,
    p_credits: credits,
    p_session: session.id,
    p_amount: session.amount_total,
    p_currency: session.currency,
    p_customer: typeof session.customer === "string" ? session.customer : (session.customer && session.customer.id) || null,
  });
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!process.env.STRIPE_SECRET_KEY || !process.env.STRIPE_WEBHOOK_SECRET || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Billing isn't configured." });
    return;
  }

  let event;
  try {
    const raw = await readRawBody(req);
    if (!verifyStripeSignature(raw, req.headers["stripe-signature"], process.env.STRIPE_WEBHOOK_SECRET)) {
      res.status(400).json({ error: "Invalid signature." });
      return;
    }
    event = JSON.parse(raw);
  } catch (error) {
    console.error(error);
    res.status(400).json({ error: "Bad request." });
    return;
  }

  try {
    const obj = event.data && event.data.object;

    switch (event.type) {
      case "checkout.session.completed":
        if (obj.mode === "subscription" && obj.subscription) {
          await syncSubscription(obj.subscription, obj.client_reference_id || (obj.metadata && obj.metadata.user_id));
        } else if (obj.mode === "payment") {
          await grantCredits(obj);
        }
        break;
      case "checkout.session.async_payment_succeeded":
        if (obj.mode === "payment") await grantCredits(obj);
        break;
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
        await syncSubscription(obj.id);
        break;
      // Renewal paid / renewal failed: re-sync so access_until moves
      // forward on payment, and past_due is reflected on failure.
      // (Stripe's own emails ask the goalie to fix their card.)
      case "invoice.paid":
      case "invoice.payment_failed": {
        const subId = invoiceSubscriptionId(obj);
        if (subId) await syncSubscription(subId);
        break;
      }
      default:
        break; // ignore everything else
    }

    res.status(200).json({ received: true });
  } catch (error) {
    // 500 makes Stripe retry later.
    console.error(error);
    res.status(500).json({ error: error.message || "Webhook handling failed." });
  }
}
