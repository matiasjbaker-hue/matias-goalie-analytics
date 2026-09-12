// ============================================================
// GAME REPORT NARRATIVE — serverless function
// ============================================================
// Used by the "Download PDF Report" feature. The browser has
// already computed every real stat for one specific game (using
// the same authoritative, database-scored xG values the rest of
// the app uses) and formats them into a plain-text summary. This
// function's only job is to turn that summary into a short,
// grounded coach's narrative -- what went well, what to work on,
// and priorities for next practice -- using Claude.
//
// It does NOT fetch anything from Supabase itself and does NOT
// compute any stats. It only reads the summary text the client
// already built from real, RLS-scoped data. To stop this endpoint
// being hit with made-up stats by someone who was never signed in,
// it still verifies the caller's Supabase access token is valid
// before spending any Anthropic API budget on them.
//
// Setup: same ANTHROPIC_API_KEY environment variable as api/coach.js.

const SUPABASE_URL = "https://iiuqxxrrruvwvfehrzic.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ";

const CLAUDE_MODEL = "claude-sonnet-5";


async function verifyAccessToken(accessToken) {

  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`
    }
  });

  if (!res.ok) {
    return false;
  }

  const data = await res.json();
  return !!(data && data.id);

}


export default async function handler(req, res) {

  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return;
  }

  const { accessToken, summaryText, viewerRole } = req.body || {};

  if (!accessToken || !summaryText) {
    res.status(400).json({ error: "Missing accessToken or summaryText." });
    return;
  }

  if (!process.env.ANTHROPIC_API_KEY) {
    res.status(500).json({ error: "Server is not configured with an ANTHROPIC_API_KEY." });
    return;
  }

  try {

    const validSession = await verifyAccessToken(accessToken);

    if (!validSession) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const systemPrompt =
      "You write short, specific post-game analysis for a goaltender, based ONLY on the game " +
      "stats summary provided below. Never invent a number, situation, or detail that isn't in " +
      "the summary -- if something isn't in the data, don't mention it. Write for " +
      (viewerRole === "coach"
        ? "a coach reviewing one of their goalies after a game."
        : "a goalie reviewing their own game.") +
      "\n\n" +
      "Respond in EXACTLY this plain-text format, with these three headers verbatim and nothing " +
      "before the first header or after the last section:\n\n" +
      "WENT WELL:\n" +
      "- (2-3 short, specific bullet points citing actual numbers from the summary)\n\n" +
      "AREAS TO IMPROVE:\n" +
      "- (2-3 short, specific bullet points citing actual numbers from the summary. If the " +
      "summary genuinely shows no clear weakness, say so plainly instead of inventing one.)\n\n" +
      "PRIORITIES FOR NEXT PRACTICE:\n" +
      "- (2-3 concrete, actionable practice focuses that follow directly from the areas to " +
      "improve above)\n\n" +
      "Keep every bullet to one sentence. No preamble, no closing summary, no markdown besides " +
      "the plain \"- \" bullet dashes.\n\n" +
      "GAME STATS SUMMARY:\n" + summaryText;

    const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": process.env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01"
      },
      body: JSON.stringify({
        model: CLAUDE_MODEL,
        max_tokens: 600,
        system: systemPrompt,
        messages: [
          { role: "user", content: "Write the game analysis now." }
        ]
      })
    });

    if (!anthropicRes.ok) {
      const errText = await anthropicRes.text();
      throw new Error(`Anthropic API error ${anthropicRes.status}: ${errText}`);
    }

    const anthropicData = await anthropicRes.json();

    const narrativeText =
      (anthropicData.content || [])
        .filter(block => block.type === "text")
        .map(block => block.text)
        .join("\n") || "";

    res.status(200).json({ narrative: narrativeText });

  } catch (error) {

    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });

  }

}
