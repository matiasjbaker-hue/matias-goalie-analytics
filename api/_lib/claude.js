// ============================================================
// SHARED CLAUDE CLIENT
// ============================================================
// The Anthropic API key lives only in Vercel's environment variables
// (ANTHROPIC_API_KEY) and never reaches the browser. If the key was
// created at the organization level rather than inside a workspace,
// also set ANTHROPIC_WORKSPACE_ID.

import Anthropic from "@anthropic-ai/sdk";

let client = null;

export function claudeConfigured() {
  return !!process.env.ANTHROPIC_API_KEY;
}

export function claude() {
  if (!client) {
    const workspaceId = (process.env.ANTHROPIC_WORKSPACE_ID || "").trim();
    client = new Anthropic({
      apiKey: process.env.ANTHROPIC_API_KEY,
      // An empty workspace header is rejected, so only send it when set.
      defaultHeaders: workspaceId ? { "anthropic-workspace-id": workspaceId } : undefined,
      // Stay inside the function's own time limit (see vercel.json).
      timeout: 55 * 1000,
      maxRetries: 2,
    });
  }
  return client;
}

export function textOf(message) {
  return (message.content || [])
    .filter(block => block.type === "text")
    .map(block => block.text)
    .join("\n");
}
