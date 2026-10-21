// ============================================================
// POST /api/admin/film-link -- a goalie sends a link to their game film
// ============================================================
// For goalies whose film lives in Google Drive, Dropbox, Hudl, YouTube
// and so on (a phone's file picker can't reliably upload a multi-GB
// game). They paste a link and the company inbox gets an email with
// everything needed to upload it for them from the admin side.
//
// Body: { accessToken, url, note?, game?, jerseyColor? }
// Any signed-in user may call this (despite the /admin URL: the admin
// dispatcher is only a function-count workaround, see [action].js), so
// every field is validated and length-limited here. Nothing is stored;
// the email is the record.

import { verifyUser, getProfile } from "./billing.js";

const MAX_URL = 600;

// single line, trimmed, length-limited: safe for a subject or a label
function oneLine(value, max) {
  return String(value == null ? "" : value).replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim().slice(0, max);
}

function cleanUrl(value) {
  const raw = String(value == null ? "" : value).trim();
  if (!raw || raw.length > MAX_URL || /\s/.test(raw)) return null;
  let parsed;
  try {
    parsed = new URL(raw);
  } catch (e) {
    return null;
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return null;
  if (!parsed.hostname.includes(".")) return null;
  return parsed.toString();
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, url, note, game, jerseyColor } = req.body || {};

  if (!accessToken) {
    res.status(400).json({ error: "Missing accessToken." });
    return;
  }

  const link = cleanUrl(url);
  if (!link) {
    res.status(400).json({ error: "Paste the full link to your film (it should start with https://)." });
    return;
  }

  let email;
  try {
    email = await import("./email.js");
  } catch (err) {
    console.error(err);
    res.status(503).json({ error: "Sending links isn't available right now. Please email the link to matias@goalieiqanalytics.com." });
    return;
  }

  try {
    const user = await verifyUser(accessToken);
    if (!user) {
      res.status(401).json({ error: "Invalid or expired session. Refresh the page and sign in again." });
      return;
    }

    if (!email.emailConfigured()) {
      res.status(503).json({ error: "Sending links isn't available right now. Please email the link to matias@goalieiqanalytics.com." });
      return;
    }

    let profile = null;
    try {
      profile = await getProfile(user.id);
    } catch (e) {
      // the name is a convenience; the email still goes out without it
    }

    const name = oneLine((profile && profile.full_name) || (user.user_metadata && (user.user_metadata.name || user.user_metadata.full_name)) || user.email || "A goalie", 80);
    const gameText = oneLine(game, 200) || "Not specified";
    const jersey = oneLine(jerseyColor, 60) || "Not specified";
    const noteText = String(note == null ? "" : note).replace(/\r/g, "").trim().slice(0, 1000);

    const lines = [
      `${name} sent a link to their game film.`,
      "",
      `Link: ${link}`,
      `Game: ${gameText}`,
      `Team jersey color: ${jersey}`,
      `Account email: ${user.email || "unknown"}`,
      `Account id: ${user.id}`,
    ];
    if (noteText) lines.push("", "Note:", noteText);
    lines.push(
      "",
      "Check the link opens (Drive/Dropbox links need to be shared so anyone with the link can view), then upload the film for them from Add Game as admin.",
    );
    const text = lines.join("\n");

    const html =
      `<p><strong>${email.escapeHtml(name)}</strong> sent a link to their game film.</p>` +
      `<p>Link: <a href="${email.escapeHtml(link)}">${email.escapeHtml(link)}</a><br>` +
      `Game: ${email.escapeHtml(gameText)}<br>` +
      `Team jersey color: ${email.escapeHtml(jersey)}<br>` +
      `Account email: ${email.escapeHtml(user.email || "unknown")}</p>` +
      (noteText ? `<p>Note:<br>${email.escapeHtml(noteText).replace(/\n/g, "<br>")}</p>` : "") +
      `<p>Check the link opens (Drive/Dropbox links need to be shared so anyone with the link can view), then upload the film for them from Add Game as admin.</p>`;

    const from = email.fromAddress();
    const transport = await email.makeTransport();

    await transport.sendMail({
      from,
      to: from.address,
      replyTo: user.email && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(user.email) ? user.email : from.address,
      subject: `Film link from ${name}`,
      text,
      html,
    });

    res.status(200).json({ sent: true });
  } catch (error) {
    console.error(error);
    res.status(502).json({ error: "Couldn't send your link. Please email it to matias@goalieiqanalytics.com instead." });
  }
}
