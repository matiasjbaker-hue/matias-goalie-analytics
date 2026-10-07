// ============================================================
// POST /api/admin/send-recap -- admin emails a game recap
// ============================================================
// Body: { accessToken, action, gameId, ... }
//   action "lookup":   the goalie's login email, whether sending is set
//                      up, and any earlier sends for this game.
//   action "diagnose": tests each piece of the email setup and says
//                      exactly which one is wrong.
//   action "send":     { to, subject, body, test?, resend? }
//                      test=true sends only to the caller's own address.
// Admin only. The email goes out from the company Gmail (see
// api/_lib/email.js for the env vars it needs). Real and test sends are
// written to recap_emails, and a game that has already been emailed won't
// be sent again unless the admin confirms. The log is a convenience: if it
// can't be read or written, the email still sends.

import { verifyUser, getProfile, serviceSelect } from "../_lib/billing.js";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function friendlyMailError(err) {
  const msg = String((err && err.message) || err || "");
  if (err && (err.code === "EAUTH" || /Invalid login|Username and Password not accepted|535/i.test(msg))) {
    return "Gmail rejected the login. Check RECAP_GMAIL_USER and the app password (it must be a Google app password, not the account password).";
  }
  if (err && (err.code === "ECONNECTION" || err.code === "ETIMEDOUT" || err.code === "ESOCKET" || err.code === "EDNS")) {
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
    res.status(503).json({ error: "Server isn't configured for this yet (missing SUPABASE_SERVICE_ROLE_KEY)." });
    return;
  }

  // Loaded here (not at the top) so a missing file gives a readable message.
  let email;
  try {
    email = await import("../_lib/email.js");
  } catch (err) {
    console.error(err);
    res.status(500).json({
      error: `The email code didn't load (${err.message}). Check that api/_lib/email.js was uploaded.`,
    });
    return;
  }

  const { accessToken, action, gameId } = req.body || {};

  // which step we were on, so an unexpected failure says where it happened
  let stage = "checking your login";

  try {
    const caller = await verifyUser(accessToken);
    if (!caller) {
      res.status(401).json({ error: "Invalid or expired session. Refresh the page and sign in again." });
      return;
    }

    stage = "checking you're an admin";
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

    stage = "loading the game";
    const games = await serviceSelect("Games", `select=id,user_id,date,opponent&id=eq.${gid}`);
    const game = games[0];
    if (!game) {
      res.status(404).json({ error: "Game not found." });
      return;
    }

    // ---------- diagnose ----------
    if (action === "diagnose") {
      stage = "running the setup check";
      const checks = [];
      const add = (name, ok, detail = "") => checks.push({ name, ok, detail });

      add("Signed in as an admin", true);

      if (email.dryRun()) {
        add("Dry-run mode", false, "RECAP_DRY_RUN is on, so emails are built but NOT actually sent. Remove it in Vercel to send for real.");
      }

      const lib = await email.nodemailerAvailable();
      add("Email library installed", lib.ok, lib.ok ? "" : lib.error);

      const user = email.gmailUser();
      add("RECAP_GMAIL_USER is set", !!user, user || "Add it in Vercel: your company Gmail address.");

      const rawPw = String(process.env.RECAP_GMAIL_APP_PASSWORD || "");
      const pw = email.gmailPassword();
      add(
        "RECAP_GMAIL_APP_PASSWORD is set",
        pw.length === 16,
        !pw
          ? "Add it in Vercel: the 16-character Google app password."
          : pw.length === 16
            ? "16 characters" + (/\s/.test(rawPw) ? " (the spaces are ignored)" : "")
            : `${pw.length} characters, but Google app passwords are 16. Create a new one and paste it again.`
      );

      // the Gmail login is the slow check, so it runs alongside the quick ones
      const canTryLogin = lib.ok && !!user && pw.length > 0 && !email.dryRun();

      const loginCheck = canTryLogin
        ? (async () => {
            try {
              const transport = await email.makeTransport();
              await transport.verify();
              return { ok: true, detail: "" };
            } catch (err) {
              return { ok: false, detail: friendlyMailError(err) };
            }
          })()
        : Promise.resolve({
            ok: email.dryRun(),
            detail: email.dryRun() ? "skipped (dry-run)" : "Skipped until the items above are fixed.",
          });

      try {
        await serviceSelect("recap_emails", "select=id&limit=1");
        add("Send log is readable", true);
      } catch (err) {
        const perm = /\b40[13]\b/.test(err.message)
          ? " This means the server isn't allowed to use that table (a database permission is missing)."
          : "";
        add("Send log is readable", false, `${err.message}.${perm} Recaps still send, but the history and duplicate protection are off.`);
      }

      try {
        const found = await email.getAuthUserEmail(game.user_id);
        add("Goalie's email found", !!found, found ? "yes" : "This account has no email on file. Type one in.");
      } catch (err) {
        add("Goalie's email found", false, err.message);
      }

      const login = await loginCheck;
      add("Gmail accepts the login", login.ok, login.detail);

      res.status(200).json({ checks });
      return;
    }

    // earlier sends of this game (never allowed to break lookup or send)
    stage = "checking earlier sends";
    let prior = [];
    let logProblem = null;
    try {
      prior = await serviceSelect(
        "recap_emails",
        `select=sent_to,created_at&game_id=eq.${gid}&is_test=eq.false&status=eq.sent&order=created_at.desc&limit=3`
      );
    } catch (err) {
      console.error(err);
      logProblem = err.message;
    }

    // ---------- lookup ----------
    if (action === "lookup") {
      stage = "looking up the goalie's email";
      const found = await email.getAuthUserEmail(game.user_id);
      res.status(200).json({ email: found, prior, emailConfigured: email.emailConfigured(), logProblem });
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

    if (!email.emailConfigured()) {
      res.status(503).json({
        error: "Email sending isn't set up yet. Add RECAP_GMAIL_USER and RECAP_GMAIL_APP_PASSWORD in Vercel, then redeploy. (Press Check setup to see what's missing.)",
      });
      return;
    }

    stage = "building the email";
    const message = email.buildEmail({
      subject: isTest ? `[TEST] ${subject}` : subject,
      body,
    });

    const from = email.fromAddress();
    const baseLog = {
      game_id: gid,
      goalie_id: game.user_id,
      sent_to: recipient,
      subject: message.subject,
      is_test: isTest,
      sent_by: caller.id,
    };

    stage = "sending through Gmail";
    try {
      const transport = await email.makeTransport();
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
      await email.logRecap({ ...baseLog, status: "failed", error: String(err && err.message).slice(0, 500) });
      res.status(502).json({ error: friendlyMailError(err) });
      return;
    }

    await email.logRecap({ ...baseLog, status: "sent" });

    res.status(200).json({
      sent: true,
      to: recipient,
      test: isTest,
      dryRun: email.dryRun(),
      warning: logProblem ? "Sent, but the send log couldn't be read, so duplicate protection was off." : undefined,
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: `${error.message || "Unexpected error"} (while ${stage})` });
  }
}
