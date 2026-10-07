// ============================================================
// Email helpers for the admin "Email recap" feature
// ============================================================
// Sends from the company Gmail account over SMTP using a Google
// APP PASSWORD (not the real account password). Required env vars:
//   RECAP_GMAIL_USER          e.g. goalieiqanalytics@gmail.com
//   RECAP_GMAIL_APP_PASSWORD  16-character Google app password
//                             (the spaces Google shows are ignored)
// Optional:
//   RECAP_FROM_NAME           display name (default "GoalieIQ Analytics")
//   RECAP_MAILING_ADDRESS     added to the footer if you want it there
//   RECAP_DRY_RUN=1           builds the email but sends nothing (testing)

import { SUPABASE_URL } from "./billing.js";

const SITE = "https://www.goalieiqanalytics.com";

function serviceHeaders(extra = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
}

// ---- settings (read at call time so a redeploy with new values just works) ----

export function gmailUser() {
  return String(process.env.RECAP_GMAIL_USER || "").trim();
}

// Google displays app passwords as "abcd efgh ijkl mnop"; pasting with the
// spaces is the most common slip, so strip all whitespace.
export function gmailPassword() {
  return String(process.env.RECAP_GMAIL_APP_PASSWORD || "").replace(/\s+/g, "");
}

export function dryRun() {
  return process.env.RECAP_DRY_RUN === "1";
}

export function emailConfigured() {
  return dryRun() || !!(gmailUser() && gmailPassword());
}

// ---- nodemailer is loaded lazily so a missing package gives a clear
// message here instead of crashing the whole endpoint at startup ----

export async function loadNodemailer() {
  try {
    const mod = await import("nodemailer");
    return mod.default || mod;
  } catch (err) {
    const e = new Error(
      "The email library (nodemailer) isn't installed on the server. Make sure package.json includes the nodemailer line, then redeploy."
    );
    e.code = "NO_NODEMAILER";
    throw e;
  }
}

export async function nodemailerAvailable() {
  try {
    await loadNodemailer();
    return { ok: true };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

// ---- Supabase helpers ----

// The login email for a user id (only the server can read this).
export async function getAuthUserEmail(userId) {
  const res = await fetch(
    `${SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
    { headers: serviceHeaders() }
  );
  if (!res.ok) throw new Error(`Supabase ${res.status} looking up the login`);
  const user = await res.json();
  return user && user.email ? user.email : null;
}

// Logging must never be the reason an email fails or is reported as failed.
export async function logRecap(row) {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/recap_emails`, {
      method: "POST",
      headers: serviceHeaders({ "Content-Type": "application/json", Prefer: "return=minimal" }),
      body: JSON.stringify(row),
    });
    if (!res.ok) console.error("recap log insert failed", res.status, await res.text());
  } catch (err) {
    console.error("recap log insert failed", err);
  }
}

// ---- building the message ----

export function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Applied AFTER escaping, so it can only ever add our own <a> tag.
function autolink(escaped) {
  return escaped.replace(
    /\b((?:https?:\/\/)?(?:www\.)?goalieiqanalytics\.com)\b/gi,
    `<a href="${SITE}" style="color:#0a8f5a;font-weight:600">$1</a>`
  );
}

// An ALL-CAPS line on its own (e.g. "THE HEADLINE") becomes a section heading.
const HEADING = /^[A-Z][A-Z0-9 &'\/\-]{2,48}$/;
const BULLET = /^\s*[•\-\*]\s+/;

function headingHtml(text) {
  return `<p style="margin:26px 0 8px;font-size:12px;font-weight:bold;letter-spacing:1.6px;color:#0a8f5a">${escapeHtml(text)}</p>`;
}

// Plain text from the admin's textarea -> simple, safe HTML.
// Blank line = new paragraph; "• " lines = a bullet list; an ALL-CAPS
// first line = a section heading.
export function textToHtml(body) {
  return String(body)
    .replace(/\r\n/g, "\n")
    .split(/\n{2,}/)
    .map((block) => {
      let lines = block.split("\n").filter((l) => l.trim() !== "");
      if (!lines.length) return "";

      let out = "";

      if (HEADING.test(lines[0].trim())) {
        out += headingHtml(lines[0].trim());
        lines = lines.slice(1);
        if (!lines.length) return out;
      }

      if (lines.every((l) => BULLET.test(l))) {
        const items = lines
          .map(
            (l) =>
              `<li style="margin:0 0 10px;padding-left:2px">${autolink(escapeHtml(l.replace(BULLET, "")))}</li>`
          )
          .join("");
        return out + `<ul style="margin:0 0 16px;padding-left:22px">${items}</ul>`;
      }

      return out + `<p style="margin:0 0 16px">${lines.map((l) => autolink(escapeHtml(l))).join("<br>")}</p>`;
    })
    .join("");
}

function footerText() {
  const lines = [
    "You're getting this because you're a GoalieIQ Analytics customer.",
    'Don\'t want recap emails? Just reply "no recaps" and I\'ll stop them.',
  ];
  if (process.env.RECAP_MAILING_ADDRESS) lines.push(process.env.RECAP_MAILING_ADDRESS);
  return lines;
}

export function buildEmail({ subject, body }) {
  const cleanSubject = String(subject).replace(/[\r\n]+/g, " ").trim();
  const footer = footerText();

  const text = `${String(body).trim()}\n\n--\n${footer.join("\n")}\n`;

  const html = `<!doctype html>
<html><body style="margin:0;padding:0;background:#eef3f0">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef3f0;padding:24px 0">
<tr><td align="center">
<table role="presentation" width="580" cellpadding="0" cellspacing="0" style="width:100%;max-width:580px;background:#ffffff;border-radius:12px;overflow:hidden;font-family:Arial,Helvetica,sans-serif">
<tr><td style="background:#061710;padding:20px 30px;color:#69dda0;font-size:13px;font-weight:bold;letter-spacing:2px">GOALIEIQ ANALYTICS</td></tr>
<tr><td style="padding:30px 30px 12px;color:#1b2b24;font-size:16px;line-height:1.6">${textToHtml(body)}</td></tr>
<tr><td style="padding:16px 30px 26px;border-top:1px solid #e3ebe6;color:#7a8c83;font-size:12px;line-height:1.6">${footer.map(escapeHtml).join("<br>")}</td></tr>
</table>
</td></tr>
</table>
</body></html>`;

  return { subject: cleanSubject, text, html };
}

// ---- sending ----

export async function makeTransport() {
  const nodemailer = await loadNodemailer();

  if (dryRun()) {
    return nodemailer.createTransport({ jsonTransport: true });
  }

  return nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: { user: gmailUser(), pass: gmailPassword() },
    // nodemailer's defaults wait up to 2 minutes. Keep every step under
    // ~10 seconds so a problem comes back as a clear error, not a hang
    // (serverless functions get cut off around then anyway).
    connectionTimeout: 8000,
    greetingTimeout: 8000,
    socketTimeout: 9000,
  });
}

export function fromAddress() {
  const name = process.env.RECAP_FROM_NAME || "GoalieIQ Analytics";
  return { name, address: gmailUser() || "recap@example.invalid" };
}
