// ============================================================
// POST /api/admin/delete-account -- admin removes a goalie/coach
// ============================================================
// Body: { accessToken, targetId }. Only an admin can call it, never on
// an admin account or on themselves. Order matters:
//   1. cancel any Stripe subscription (so Stripe can't re-grant access),
//   2. delete every row that references the user (stats, games, notes,
//      assignments, access),
//   3. delete the login itself.
// Uploaded video FILES in R2 storage are not removed by this.

import {
  stripe, stripeConfigured, verifyUser, getProfile, getAccessRow,
  serviceRpc, deleteAuthUser,
} from "../_lib/billing.js";

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Server isn't configured for account deletion." });
    return;
  }

  const { accessToken, targetId } = req.body || {};

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const callerProfile = await getProfile(caller.id);
    if (!callerProfile || callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can delete accounts." });
      return;
    }

    if (!targetId || targetId === caller.id) {
      res.status(400).json({ error: "You can't delete this account." });
      return;
    }

    const target = await getProfile(targetId);
    if (!target) {
      res.status(404).json({ error: "Account not found." });
      return;
    }
    if (target.role === "admin") {
      res.status(400).json({ error: "Admin accounts can't be deleted here." });
      return;
    }

    let stripeCanceled = false;
    const access = await getAccessRow(targetId);
    if (access && access.stripe_subscription_id && stripeConfigured()) {
      try {
        await stripe("DELETE", `/subscriptions/${encodeURIComponent(access.stripe_subscription_id)}`);
        stripeCanceled = true;
      } catch (err) {
        // Already canceled / not found is fine; anything else stops the delete.
        if (!/No such subscription|canceled/i.test(err.message)) throw err;
      }
    }

    const removed = await serviceRpc("admin_purge_account_data", { target: targetId });
    await deleteAuthUser(targetId);

    res.status(200).json({ deleted: true, stripeCanceled, removed });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Could not delete the account." });
  }
}
