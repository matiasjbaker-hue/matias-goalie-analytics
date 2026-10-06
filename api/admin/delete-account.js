// ============================================================
// POST /api/admin/delete-account -- admin removes a goalie/coach
// ============================================================
// Body: { accessToken, targetId }. An admin can delete any non-admin
// account; any non-admin user can delete their own. Order matters:
//   1. cancel any Stripe subscription (so Stripe can't re-grant access),
//   2. delete every row that references the user (stats, games, notes,
//      assignments, access),
//   3. delete the login itself,
//   4. delete their uploaded video files from R2 (everything under
//      "<user id>/"), so no game film outlives the account.

import { ListObjectsV2Command, DeleteObjectsCommand } from "@aws-sdk/client-s3";
import {
  stripe, stripeConfigured, verifyUser, getProfile, getAccessRow,
  serviceRpc, deleteAuthUser,
} from "../_lib/billing.js";
import { r2Configured, r2Client } from "../_lib/supabase.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Returns how many files were removed. Failures are logged, not thrown:
// the account itself is already gone by the time this runs.
async function deleteUserFiles(userId) {
  if (!r2Configured() || !UUID.test(userId)) return 0;
  const client = r2Client();
  const Bucket = process.env.R2_BUCKET_NAME;
  let removed = 0;
  let ContinuationToken;
  try {
    do {
      const page = await client.send(new ListObjectsV2Command({ Bucket, Prefix: `${userId}/`, ContinuationToken }));
      const keys = (page.Contents || []).map(o => ({ Key: o.Key }));
      if (keys.length) {
        await client.send(new DeleteObjectsCommand({ Bucket, Delete: { Objects: keys, Quiet: true } }));
        removed += keys.length;
      }
      ContinuationToken = page.IsTruncated ? page.NextContinuationToken : undefined;
    } while (ContinuationToken);
  } catch (error) {
    console.error("R2 cleanup failed for deleted account", userId, error);
  }
  return removed;
}

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
    if (!callerProfile) {
      res.status(403).json({ error: "Account not found." });
      return;
    }

    // Anyone (except admin) can delete their OWN account (privacy right);
    // only an admin can delete someone else's.
    const isSelf = targetId === caller.id;

    if (typeof targetId !== "string" || !UUID.test(targetId)) {
      res.status(400).json({ error: "You can't delete this account." });
      return;
    }
    if (isSelf && callerProfile.role === "admin") {
      res.status(400).json({ error: "Admin accounts can't be deleted here." });
      return;
    }
    if (!isSelf && callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can delete other accounts." });
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
    const filesRemoved = await deleteUserFiles(targetId);

    res.status(200).json({ deleted: true, stripeCanceled, removed, filesRemoved });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Could not delete the account. Please try again." });
  }
}
