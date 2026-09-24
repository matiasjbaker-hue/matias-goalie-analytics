// ============================================================
// GAME REPORT NARRATIVE — serverless function
// ============================================================
// Used by the "Download PDF Report" feature. The browser has
// already computed every real stat for one specific game (using
// the same authoritative, database-scored xG values the rest of
// the app uses) and formats them into a plain-text summary. This
// function's only job is to turn that summary into a short,
// stat-driven analysis -- what went well, what to work on, and
// concrete practice priorities -- using Claude. The response is
// returned in the same "WENT WELL: / - bullet" text format the
// browser already parses.
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

OUTPUT
Submit your analysis with the submit_game_analysis tool:
- went_well: 2-3 items, strongest stat-backed positives first.
- areas_to_improve: 2-3 items, ranked by goals-against impact. If the data shows no clear weakness, give one item saying so plainly with the numbers that support it.
- practice_priorities: 2-3 items, one per weakness above, each with drill + dose + next-game target.
Every list must have at least one item. Each item is one plain sentence: no bullet characters, no numbering, no markdown.

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


// The analysis comes back through a forced tool call instead of free
// text, so the three sections always arrive as clean JSON arrays --
// no dependence on the model formatting headers or "- " bullets
// exactly right (which is what caused "Not enough data to say" when
// a section failed to parse).
const ANALYSIS_TOOL = {
  name: "submit_game_analysis",
  description: "Submit the finished post-game analysis.",
  input_schema: {
    type: "object",
    properties: {
      went_well: {
        type: "array",
        items: { type: "string" },
        minItems: 1,
        maxItems: 3,
        description: "Stat-backed positives, strongest first. One sentence each."
      },
      areas_to_improve: {
        type: "array",
        items: { type: "string" },
        minItems: 1,
        maxItems: 3,
        description: "Weaknesses ranked by goals-against impact. One sentence each."
      },
      practice_priorities: {
        type: "array",
        items: { type: "string" },
        minItems: 1,
        maxItems: 3,
        description: "One per weakness: drill + dose + measurable next-game target. One sentence each."
      }
    },
    required: ["went_well", "areas_to_improve", "practice_priorities"]
  }
};

function cleanItems(list) {
  return (Array.isArray(list) ? list : [])
    .map(item => String(item ?? "")
      .replace(/^\s*(?:[-\u2022*\u2013\u2014]+|\d+[.)])\s+/, "")
      .replace(/\s+/g, " ")
      .trim())
    .filter(Boolean)
    .slice(0, 3);
}

async function requestAnalysis(systemPrompt) {

  const anthropicRes = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: anthropicHeaders(),
    body: JSON.stringify({
      model: CLAUDE_MODEL,
      max_tokens: 2000,
      system: systemPrompt,
      tools: [ANALYSIS_TOOL],
      tool_choice: { type: "tool", name: ANALYSIS_TOOL.name },
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

  const toolBlock = (anthropicData.content || [])
    .find(block => block.type === "tool_use" && block.name === ANALYSIS_TOOL.name);

  const input = (toolBlock && toolBlock.input) || {};

  return {
    wentWell: cleanItems(input.went_well),
    areasToImprove: cleanItems(input.areas_to_improve),
    priorities: cleanItems(input.practice_priorities)
  };

}

function isComplete(analysis) {
  return analysis.wentWell.length > 0 &&
    analysis.areasToImprove.length > 0 &&
    analysis.priorities.length > 0;
}

// Rebuilds the exact plain-text format the browser's
// parseGameNarrative() already expects, so index.html needs no change.
function toNarrativeText(analysis) {
  const section = (header, items) =>
    header + "\n" + items.map(item => "- " + item).join("\n");

  return [
    section("WENT WELL:", analysis.wentWell),
    section("AREAS TO IMPROVE:", analysis.areasToImprove),
    section("PRIORITIES FOR NEXT PRACTICE:", analysis.priorities)
  ].join("\n\n");
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

    // One automatic retry if any section comes back empty, so a
    // single off response doesn't leave a hole in the PDF.
    let analysis = await requestAnalysis(systemPrompt);

    if (!isComplete(analysis)) {
      const retry = await requestAnalysis(systemPrompt);
      if (isComplete(retry)) {
        analysis = retry;
      }
    }

    const narrativeText = toNarrativeText(analysis);

    res.status(200).json({ narrative: narrativeText });

  } catch (error) {

    console.error(error);
    res.status(500).json({ error: error.message || "Something went wrong." });

  }

}
