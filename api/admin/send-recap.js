// ============================================================
// POST /api/admin/send-recap -- admin emails a game recap
// ============================================================
// Body: { accessToken, action, gameId, ... }
//   action "lookup": returns the goalie's login email, whether sending
//                    is set up, and any earlier sends for this game.
//   action "send":   { to, subject, body, test?, resend? }
//                    test=true sends only to the caller's own address.
// Admin only. The email goes out from the company Gmail (see
// api/_lib/email.js for the two env vars it needs). Every real or
// test send is written to recap_emails, and a game that has already
// been emailed won't be sent again unless the admin confirms.

import { verifyUser, getProfile, serviceSelect } from "../_lib/billing.js";
import {
  emailConfigured, getAuthUserEmail, logRecap, buildEmail,
  makeTransport, fromAddress,
} from "../_lib/email.js";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function friendlyMailError(err) {
  const msg = String((err && err.message) || err || "");
  if (err && (err.code === "EAUTH" || /Invalid login|Username and Password not accepted/i.test(msg))) {
    return "Gmail rejected the login. Check RECAP_GMAIL_USER and the app password (it must be a Google app password, not the account password).";
  }
  if (err && (err.code === "ECONNECTION" || err.code === "ETIMEDOUT" || err.code === "ESOCKET")) {
    return "Couldn't reach Gmail's mail server. Try again in a minute.";
  }
  return msg || "The email could not be sent.";
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

  const { accessToken, action, gameId } = req.body || {};

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const callerProfile = await getProfile(caller.id);
    if (!callerProfile || callerProfile.role !== "admin") {
      res.status(403).json({ error: "Only an admin can send recap emails." });
      return;
    }

    const gid = Number(gameId);
    if (!Number.isInteger(gid) || gid <= 0) {
      res.status(400).json({ error: "Missing game." });
      return;
    }

    const games = await serviceSelect("Games", `select=id,user_id,date,opponent&id=eq.${gid}`);
    const game = games[0];
    if (!game) {
      res.status(404).json({ error: "Game not found." });
      return;
    }

    const prior = await serviceSelect(
      "recap_emails",
      `select=sent_to,created_at&game_id=eq.${gid}&is_test=eq.false&status=eq.sent&order=created_at.desc&limit=3`
    );

    // ---------- lookup ----------
    if (action === "lookup") {
      const email = await getAuthUserEmail(game.user_id);
      res.status(200).json({ email, prior, emailConfigured: emailConfigured() });
      return;
    }

    // ---------- send ----------
    if (action !== "send") {
      res.status(400).json({ error: "Unknown action." });
      return;
    }

    const { to, subject, body, test, resend } = req.body || {};
    const isTest = !!test;

    if (!subject || !String(subject).trim() || String(subject).length > 200) {
      res.status(400).json({ error: "Add a subject (200 characters or fewer)." });
      return;
    }
    if (!body || !String(body).trim() || String(body).length > 8000) {
      res.status(400).json({ error: "Add a message (8,000 characters or fewer)." });
      return;
    }

    // a test only ever goes to the admin's own address
    const recipient = isTest ? caller.email : String(to || "").trim();

    if (!recipient || recipient.length > 254 || !EMAIL_RE.test(recipient)) {
      res.status(400).json({ error: isTest ? "Your own account has no valid email." : "That doesn't look like a valid email address." });
      return;
    }

    if (!isTest && prior.length && !resend) {
      res.status(409).json({ error: "This game was already emailed. Confirm to send another copy.", prior });
      return;
    }

    if (!emailConfigured()) {
      res.status(503).json({
        error: "Email sending isn't set up yet. Add RECAP_GMAIL_USER and RECAP_GMAIL_APP_PASSWORD in Vercel, then redeploy.",
      });
      return;
    }

    const message = buildEmail({
      subject: isTest ? `[TEST] ${subject}` : subject,
      body,
    });

    const from = fromAddress();
    const baseLog = {
      game_id: gid,
      goalie_id: game.user_id,
      sent_to: recipient,
      subject: message.subject,
      is_test: isTest,
      sent_by: caller.id,
    };

    try {
      const transport = makeTransport();
      await transport.sendMail({
        from,
        to: recipient,
        replyTo: from.address,
        subject: message.subject,
        text: message.text,
        html: message.html,
      });
    } catch (err) {
      console.error(err);
      await logRecap({ ...baseLog, status: "failed", error: String(err && err.message).slice(0, 500) });
      res.status(502).json({ error: friendlyMailError(err) });
      return;
    }

    await logRecap({ ...baseLog, status: "sent" });

    res.status(200).json({ sent: true, to: recipient, test: isTest, dryRun: process.env.RECAP_DRY_RUN === "1" });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });
  }
}
