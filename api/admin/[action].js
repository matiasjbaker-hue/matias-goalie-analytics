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
//
// Handlers load only when their action is called, so one missing or
// broken handler (e.g. the email recap) can't take the others down.

const ROUTES = {
  "delete-account": () => import("../_lib/admin-delete-account.js"),
  "send-recap": () => import("../_lib/admin-send-recap.js"),
  "user-info": () => import("../_lib/admin-user-info.js"),
  "make-clip": () => import("../_lib/admin-make-clip.js"),
  "create-request": () => import("../_lib/admin-create-request.js"),
  twelvelabs: () => import("../_lib/admin-twelvelabs.js"),
  "yolo-worker": () => import("../_lib/admin-yolo.js"),
};

export default async function handler(req, res) {
  const load = ROUTES[req.query && req.query.action];
  if (!load) {
    res.status(404).json({ error: "Not found." });
    return;
  }

  let mod;
  try {
    mod = await load();
  } catch (error) {
    console.error(`Admin action "${req.query.action}" couldn't load:`, error);
    res.status(503).json({ error: "This feature isn't available on the server right now." });
    return;
  }

  return mod.default(req, res);
}
