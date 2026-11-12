// ============================================================
// POST /api/admin/invite-goalies -- admin sets up goalies by email
// (served through api/admin/[action].js)
// ============================================================
// Body: { accessToken, coachId, goalies: [{ email, name }] }
//
// For each email: creates the goalie's login (or finds the one that
// exists), links it to the coach as a coach-managed goalie, and emails
// an invite link. The goalie sets a password and accepts the terms on
// their first visit (the page asks for it: user metadata needs_terms).
// If the email can't be sent, the link comes back so it can be sent by
// hand. Re-running it for the same email sends a fresh link.

import { verifyUser, getProfile, serviceSelect, SUPABASE_URL } from "./billing.js";
import { UUID_RE } from "./supabase.js";
import * as email from "./email.js";

const SITE = "https://www.goalieiqanalytics.com";
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX = 30;

function svc(extra = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
}

async function generateLink(type, address, data) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: svc({ "Content-Type": "application/json" }),
    body: JSON.stringify({ type, email: address, data, redirect_to: SITE }),
  });
  const text = await res.text();
  let body = {};
  try { body = JSON.parse(text); } catch (e) { /* not JSON */ }
  return { ok: res.ok, status: res.status, body, text };
}

async function linkToCoach(coachId, goalieId) {
  const found = await serviceSelect(
    "coach_goalie_assignments",
    `select=id&coach_id=eq.${coachId}&goalie_id=eq.${goalieId}&limit=1`
  );
  if (found[0]) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/coach_goalie_assignments?id=eq.${found[0].id}`, {
      method: "PATCH",
      headers: svc({ "Content-Type": "application/json", Prefer: "return=minimal" }),
      body: JSON.stringify({ active: true, coach_managed: true }),
    });
    if (!res.ok) throw new Error(`Could not update the link (${res.status}).`);
    return "already linked";
  }
  const res = await fetch(`${SUPABASE_URL}/rest/v1/coach_goalie_assignments`, {
    method: "POST",
    headers: svc({ "Content-Type": "application/json", Prefer: "return=minimal" }),
    body: JSON.stringify({ coach_id: coachId, goalie_id: goalieId, active: true, coach_managed: true }),
  });
  if (!res.ok) throw new Error(`Could not link to the coach (${res.status}): ${await res.text()}`);
  return "linked";
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: "Server isn't configured for this yet (missing SUPABASE_SERVICE_ROLE_KEY)." });
    return;
  }

  const { accessToken, coachId, goalies } = req.body || {};
  if (!UUID_RE.test(String(coachId || ""))) {
    res.status(400).json({ error: "Pick a coach." });
    return;
  }
  if (!Array.isArray(goalies) || !goalies.length || goalies.length > MAX) {
    res.status(400).json({ error: `Add between 1 and ${MAX} goalies.` });
    return;
  }

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) { res.status(401).json({ error: "Invalid or expired session." }); return; }
    const callerProfile = await getProfile(caller.id);
    if (!callerProfile || callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can invite goalies." });
      return;
    }
    const coach = await getProfile(coachId);
    if (!coach || coach.role !== "coach") {
      res.status(404).json({ error: "That coach wasn't found." });
      return;
    }

    const canEmail = email.emailConfigured();
    const transport = canEmail ? await email.makeTransport() : null;
    const results = [];
    const seen = new Set();

    for (const g of goalies) {
      const address = String((g && g.email) || "").trim().toLowerCase();
      const name = String((g && g.name) || "").replace(/\s+/g, " ").trim().slice(0, 80);
      const row = { email: address, name, status: "", link: null };
      results.push(row);

      if (!address || address.length > 254 || !EMAIL_RE.test(address)) { row.status = "error: not a valid email"; continue; }
      if (seen.has(address)) { row.status = "error: listed twice"; continue; }
      seen.add(address);

      try {
        const meta = { name: name || address.split("@")[0], invited_by_coach: coachId, needs_terms: true };
        let r = await generateLink("invite", address, meta);
        let isNew = true;
        if (!r.ok) {
          // Already has a login: find it with a sign-in link instead.
          r = await generateLink("magiclink", address, undefined);
          isNew = false;
          if (!r.ok) throw new Error((r.body && (r.body.msg || r.body.message)) || `login error ${r.status}`);
        }
        const goalieId = r.body.id || (r.body.user && r.body.user.id);
        if (!UUID_RE.test(String(goalieId || ""))) throw new Error("Couldn't read the new account's id.");

        const profile = await getProfile(goalieId);
        if (profile && profile.role !== "goalie") throw new Error(`That email belongs to a ${profile.role} account.`);

        const linked = await linkToCoach(coachId, goalieId);

        const metaNow = r.body.user_metadata || (r.body.user && r.body.user.user_metadata) || {};
        const acceptedAlready = !isNew && !!metaNow.terms_accepted_at;
        if (acceptedAlready) { row.status = `${linked}; already has an account, no email needed`; continue; }

        const link = r.body.action_link || (r.body.properties && r.body.properties.action_link);
        if (!link) throw new Error("Couldn't create the invite link.");
        row.link = link;

        if (!canEmail) { row.status = `${linked}; email isn't set up, send the link by hand`; continue; }

        const first = (name || "").split(" ")[0];
        const who = coach.full_name ? `Coach ${coach.full_name}` : "Your coach";
        const body =
          `${first ? `Hi ${first},` : "Hi,"}\n\n` +
          `${who} has set up your GoalieIQ Analytics account so they can upload and review your game film.\n\n` +
          "Use the button below to choose a password and finish setting up. It only takes a minute. If the link has expired, tell your coach and they'll send a new one.";
        const msg = email.buildEmail({ subject: "Your GoalieIQ Analytics account is ready", body });
        const button = `<tr><td style="padding:0 30px 24px"><a href="${email.escapeHtml(link)}" style="display:inline-block;background:#0a8f5a;color:#ffffff;font-weight:bold;font-size:16px;text-decoration:none;padding:14px 26px;border-radius:8px">Set up my account</a></td></tr>`;
        const html = msg.html.replace('<tr><td style="padding:16px 30px 26px', button + '<tr><td style="padding:16px 30px 26px');
        const from = email.fromAddress();
        await transport.sendMail({
          from, to: address, subject: msg.subject,
          text: `${msg.text}\n\nSet up my account: ${link}\n`, html,
        });
        row.status = `${linked}; invite emailed`;
      } catch (err) {
        console.error("invite-goalies failed for", address, err);
        row.status = `error: ${err.message}`;
      }
    }

    res.status(200).json({ results, emailed: canEmail });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Could not send the invites." });
  }
}
