// ============================================================
// GAME REPORT NARRATIVE — serverless function
// ============================================================
// Used by the "Download PDF Report" feature. The browser has
// already computed every real stat for one specific game (using
// the same authoritative, database-scored xG values the rest of
// the app uses) and formats them into a plain-text summary. This
// function's only job is to turn that summary into a short,
// stat-driven analysis -- what went well, what to work on, and
// concrete practice priorities -- using Claude.
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


function buildSystemPrompt(summaryText, viewerRole) {

  const audience =
    viewerRole === "coach"
      ? "a goalie coach reviewing one of their goalies after a game"
      : "a goalie reviewing their own game";

  return `You are a goaltending performance analyst writing a post-game report for ${audience}. You work ONLY from the GAME STATS SUMMARY below. You never invent a number, situation, shot, or detail that is not in the summary.

HOW TO ANALYZE
1. Rank problems by damage: which categories (situation, location, period, rebound zone, puck playing) produced the most goals against, and how far that category's SV% sits below the goalie's overall SV% for this game.
2. Use shot grades and xG to separate goalie error from team error. Goals on B or C grade shots are the goalie's highest-priority issues. Goals on A+ shots are mostly defensive breakdowns; do not treat them as the goalie's main weakness unless there are several.
3. Use GSAx as the headline verdict: positive means the goalie outperformed the shots faced, negative means they underperformed. State it with the number.
4. Sample size: any category with fewer than 5 shots is a small sample. You may mention it, but label it "small sample" and never make it a top priority on its own.
5. Stats show WHAT happened, not WHY. When you name a likely technical cause (e.g. rebound direction, depth, post integration, tracking through screens), phrase it as the likely cause and say what to confirm on film.
6. If a data section is missing (no shot-level data, no rebound data, etc.), do not comment on it.

WRITING RULES
- Every bullet follows: stat -> what it means. Always include the actual numbers (shots, goals, SV%, xG/GSAx where relevant).
- Banned: generic advice with no stat behind it, such as "stay focused", "battle harder", "trust your positioning", "keep your eyes on the puck", "stay confident", "be more aggressive". If a bullet could apply to any goalie in any game, rewrite it or cut it.
- Do not praise or criticize effort, attitude, or mentality.

PRACTICE PRIORITIES
Each priority must target one specific weakness from AREAS TO IMPROVE and include, in one sentence:
- the drill or skill (name it concretely, e.g. "post-to-post RVH push to cross-ice one-timer", "screened point shots with a live screener", "pad save directed to corner off low shots"),
- the dose (reps x sets, or minutes),
- a measurable target for next game tied to the stat (e.g. "cross-ice SV% above 85%", "zero pad rebounds to the slot").
Order priorities from highest to lowest goals-against impact.

OUTPUT FORMAT
Respond in EXACTLY this plain-text format, with these three headers verbatim, nothing before the first header, and nothing after the last bullet:

WENT WELL:
- (2-3 bullets, strongest stat-backed positives first)

AREAS TO IMPROVE:
- (2-3 bullets, ranked by goals-against impact. If the data shows no clear weakness, write one bullet saying so plainly with the numbers that support it.)

PRIORITIES FOR NEXT PRACTICE:
- (2-3 bullets, one per weakness above, each with drill + dose + next-game target)

Each bullet is a single line starting with "- ". No markdown other than the dashes.

GAME STATS SUMMARY:
${summaryText}`;

}


// Builds the headers for every Anthropic API call. If the API key
// was created at the organization level (not inside a workspace),
// Anthropic requires an anthropic-workspace-id header naming the
// workspace to bill/run in. Set ANTHROPIC_WORKSPACE_ID in Vercel
// for that case. A key created inside a workspace doesn't need it,
// and an empty header is rejected, so it's only sent when set.
function anthropicHeaders() {
  const headers = {
    "Content-Type": "application/json",
    "x-api-key": process.env.ANTHROPIC_API_KEY,
    "anthropic-version": "2023-06-01"
  };
  const workspaceId = (process.env.ANTHROPIC_WORKSPACE_ID || "").trim();
  if (workspaceId) {
    headers["anthropic-workspace-id"] = workspaceId;
  }
  return headers;
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
    res.status(503).json({ error: "AI Coach analysis is being finalized and will be available soon." });
    return;
  }

  try {

    const validSession = await verifyAccessToken(accessToken);

    if (!validSession) {
      res.status(401).json({ error: "Invalid or expired session." });
      return;
    }

    const systemPrompt = buildSystemPrompt(summaryText, viewerRole);

    const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: anthropicHeaders(),
      body: JSON.stringify({
        model: CLAUDE_MODEL,
        max_tokens: 1000,
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
