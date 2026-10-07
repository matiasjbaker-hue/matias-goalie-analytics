// ============================================================
// /api/admin/:action -- one function for every admin endpoint
// ============================================================
// Vercel Hobby deploys at most 12 serverless functions, so the admin
// endpoints share this one. URLs are unchanged:
//   POST /api/admin/delete-account   -> api/_lib/admin-delete-account.js
//   POST /api/admin/send-recap       -> api/_lib/admin-send-recap.js
//   POST /api/admin/user-info        -> api/_lib/admin-user-info.js
//   POST /api/admin/make-clip        -> api/_lib/admin-make-clip.js
// Each handler still does its own auth and role checks.

import deleteAccount from "../_lib/admin-delete-account.js";
import sendRecap from "../_lib/admin-send-recap.js";
import userInfo from "../_lib/admin-user-info.js";
import makeClip from "../_lib/admin-make-clip.js";

const ROUTES = {
  "delete-account": deleteAccount,
  "send-recap": sendRecap,
  "user-info": userInfo,
  "make-clip": makeClip,
};

export default function handler(req, res) {
  const route = ROUTES[req.query && req.query.action];
  if (!route) {
    res.status(404).json({ error: "Not found." });
    return;
  }
  return route(req, res);
}
