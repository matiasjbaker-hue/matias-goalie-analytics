// ============================================================
// Email helpers for the admin "Email recap" feature
// ============================================================
// Sends from the company Gmail account over SMTP using a Google
// APP PASSWORD (not the real account password). Required env vars:
//   RECAP_GMAIL_USER          e.g. goalieiqanalytics@gmail.com
//   RECAP_GMAIL_APP_PASSWORD  16-character Google app password
// Optional:
//   RECAP_FROM_NAME           display name (default "GoalieIQ Analytics")
//   RECAP_MAILING_ADDRESS     added to the footer if you want it there
//   RECAP_DRY_RUN=1           builds the email but sends nothing (testing)

import nodemailer from "nodemailer";
import { SUPABASE_URL } from "./billing.js";

const SITE = "https://www.goalieiqanalytics.com";

function serviceHeaders(extra = {}) {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
}

export function emailConfigured() {
  return (
    process.env.RECAP_DRY_RUN === "1" ||
    !!(process.env.RECAP_GMAIL_USER && process.env.RECAP_GMAIL_APP_PASSWORD)
  );
}

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

// Plain text from the admin's textarea -> simple, safe HTML.
// Blank line = new paragraph; a block of "• " lines = a bullet list.
export function textToHtml(body) {
  return String(body)
    .replace(/\r\n/g, "\n")
    .split(/\n{2,}/)
    .map((block) => {
      const lines = block.split("\n").filter((l) => l.trim() !== "");
      if (!lines.length) return "";

      const bullet = /^\s*[•\-\*]\s+/;

      if (lines.every((l) => bullet.test(l))) {
        const items = lines
          .map(
            (l) =>
              `<li style="margin:0 0 12px;padding-left:2px">${autolink(escapeHtml(l.replace(bullet, "")))}</li>`
          )
          .join("");
        return `<ul style="margin:0 0 18px;padding-left:22px">${items}</ul>`;
      }

      return `<p style="margin:0 0 18px">${lines.map((l) => autolink(escapeHtml(l))).join("<br>")}</p>`;
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

export function makeTransport() {
  if (process.env.RECAP_DRY_RUN === "1") {
    return nodemailer.createTransport({ jsonTransport: true });
  }
  return nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: {
      user: process.env.RECAP_GMAIL_USER,
      pass: process.env.RECAP_GMAIL_APP_PASSWORD,
    },
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
  const addr = process.env.RECAP_GMAIL_USER || "recap@example.invalid";
  return { name, address: addr };
}
