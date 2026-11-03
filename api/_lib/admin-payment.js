// ============================================================
// POST /api/admin/payment -- log (or remove) a payment that never went
// through Stripe, such as an e-transfer. Admin only.
// ============================================================
// Body for adding:
//   { accessToken, op: "add", userId, amount, credits, date?, method?, addCredits? }
//     amount      dollars (CAD), e.g. 90 or 45.5
//     credits     games in the pack (1 or more)
//     date        YYYY-MM-DD the money arrived (defaults to now)
//     method      "etransfer" (default) or "cash" / "other"
//     addCredits  true = also add `credits` to the goalie's games left and
//                 mark the account paid. Leave false if you already did that.
// Body for reading the list: { accessToken, op: "list" }
// Body for removing a mistake:
//   { accessToken, op: "delete", sessionId }   (only "manual_..." rows)
//
// Rows land in public.game_credit_purchases, the same table Stripe
// purchases are written to, so the Revenue tab and the account panel
// read one list. The service key is used server-side only.

import crypto from "crypto";
import { verifyUser, getProfile, getAccessRow, serviceSelect, SUPABASE_URL } from "./billing.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

function serviceHeaders(extra = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
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

  const body = req.body || {};

  try {
    const caller = await verifyUser(body.accessToken);
    if (!caller) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }
    const callerProfile = await getProfile(caller.id);
    if (!callerProfile || callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can log payments." });
      return;
    }

    // ---- list every logged payment (the table isn't readable from the browser) ----
    if (body.op === "list") {
      const rows = await serviceSelect(
        "game_credit_purchases",
        "select=stripe_session_id,user_id,credits,amount_total,currency,created_at&order=created_at.desc&limit=5000",
      );
      res.status(200).json({ purchases: rows });
      return;
    }

    // ---- remove a manual entry ----
    if (body.op === "delete") {
      const sessionId = String(body.sessionId || "");
      if (!sessionId.startsWith("manual_")) {
        res.status(400).json({ error: "Only manually logged payments can be removed here." });
        return;
      }
      const del = await fetch(
        `${SUPABASE_URL}/rest/v1/game_credit_purchases?stripe_session_id=eq.${encodeURIComponent(sessionId)}`,
        { method: "DELETE", headers: serviceHeaders({ Prefer: "return=minimal" }) },
      );
      if (!del.ok) throw new Error(`Supabase ${del.status} deleting payment: ${await del.text()}`);
      res.status(200).json({ removed: true });
      return;
    }

    // ---- add a manual entry ----
    const userId = String(body.userId || "");
    if (!UUID.test(userId)) {
      res.status(400).json({ error: "Pick the goalie who paid." });
      return;
    }

    const amount = Number(body.amount);
    if (!Number.isFinite(amount) || amount <= 0 || amount > 100000) {
      res.status(400).json({ error: "Enter the amount paid in dollars, like 90." });
      return;
    }
    const cents = Math.round(amount * 100);

    const credits = Math.floor(Number(body.credits));
    if (!Number.isFinite(credits) || credits < 1 || credits > 1000) {
      res.status(400).json({ error: "Enter how many games they bought (1 or more)." });
      return;
    }

    const date = body.date ? String(body.date) : "";
    if (date && !DATE.test(date)) {
      res.status(400).json({ error: "Date should look like 2026-11-02." });
      return;
    }

    const method = ["etransfer", "cash", "other"].includes(body.method) ? body.method : "etransfer";

    const profile = await getProfile(userId);
    if (!profile) {
      res.status(404).json({ error: "That account doesn't exist." });
      return;
    }

    const access = body.addCredits ? await getAccessRow(userId) : null;
    if (body.addCredits && !access) {
      res.status(400).json({ error: "That account has no access row yet, so credits can't be added. Log it without adding credits, or fix the account first." });
      return;
    }

    const sessionId = `manual_${date || new Date().toISOString().slice(0, 10)}_${method}_${crypto.randomBytes(3).toString("hex")}`;

    const row = {
      stripe_session_id: sessionId,
      user_id: userId,
      credits,
      amount_total: cents,
      currency: "cad",
    };
    // midday UTC keeps a backdated entry on the right calendar day in Ontario
    if (date) row.created_at = `${date}T17:00:00Z`;

    const ins = await fetch(`${SUPABASE_URL}/rest/v1/game_credit_purchases`, {
      method: "POST",
      headers: serviceHeaders({ "Content-Type": "application/json", Prefer: "return=minimal" }),
      body: JSON.stringify(row),
    });
    if (!ins.ok) throw new Error(`Supabase ${ins.status} logging payment: ${await ins.text()}`);

    let gamesLeft = null;
    if (body.addCredits) {
      gamesLeft = (Number(access.game_credits) || 0) + credits;
      const up = await fetch(`${SUPABASE_URL}/rest/v1/goalie_access?user_id=eq.${encodeURIComponent(userId)}`, {
        method: "PATCH",
        headers: serviceHeaders({ "Content-Type": "application/json", Prefer: "return=minimal" }),
        body: JSON.stringify({ game_credits: gamesLeft, paid: true, updated_at: new Date().toISOString() }),
      });
      if (!up.ok) {
        // The payment is logged; say so, so it isn't entered twice.
        res.status(502).json({ error: "Payment was logged, but adding the games failed. Add them from the account's edit screen (don't log the payment again).", logged: true, sessionId });
        return;
      }
    }

    res.status(200).json({ logged: true, sessionId, gamesLeft, name: profile.full_name || null });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Could not save the payment." });
  }
}
