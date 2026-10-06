# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Two audiences, weighted equally (confirmed 2026-10-06):

- **Goalies** on a development path: junior, AAA, and college-track goaltenders (current users include OJHL, OHL-signed, and NCAA-committed goalies), often with a parent paying. Their job: understand their own game beyond save percentage and goals against, and know what to train next.
- **Goalie coaches** responsible for several goalies, who need each goalie's performance, notes, and development areas in one place to decide what to work on this week.

Internal user: the GoalieIQ admin (Matias Baker), who tags uploaded game film shot by shot, manages accounts and access, and attaches shot clips.

## Product Purpose

GoalieIQ turns a goalie's game film into shot-level analytics and coaching decisions. Every shot faced is tagged (location, situation, shot type, release, rebound control, strength), scored for quality (xG), and rolled up into game reports, trends, and training priorities. Success: a goalie or coach can name a specific weakness, train it, and see in the numbers whether it improved.

## Positioning

Built only for goaltending, not adapted from a generic team-stats app. The mechanism a neighbor can't copy-paste: every shot is tracked from the goalie's own film and graded, so the numbers separate goalie error from team error (GSAx, shot grades, rebound control by body part) instead of reporting save percentage alone.

## Operating Context

- Goalies upload full game film (often 1-3 hour files from home internet); the GoalieIQ team tags it, or AI tags pre-trimmed shot clips with a human able to correct every field afterwards.
- Live Tag: a shot-by-shot tagging toolbar used during or after a game.
- Coaches open a dashboard of assigned goalies; goalies see their own season, game overviews, and downloadable PDF game reports.
- AI Coach answers plain-language questions grounded in the goalie's tracked season.
- Access is invite-first: new accounts get one free game, then pay per game (Stripe, game credits); AI features are part of Goalie Plus. Prices live in Stripe, not in the site.

## Capabilities and Constraints

- Single-page app in one `index.html` (vanilla JS, Chart.js, jsPDF, Supabase JS) plus Vercel serverless functions under `api/`. Data and auth in Supabase with row-level security; video in Cloudflare R2; payments in Stripe; AI via the Anthropic API (key held server-side only).
- Terminology in use: SV%, GAA, GSAx, xG, shot grades (A+/A/B/C), high-danger, rebound control (glove / blocker / midsection / pad-stick), rims, strength states (5v5, PK, PP).
- Roles: goalie, coach, admin.
- Mobile use is real (installable PWA, portrait).

## Brand Commitments

- Name: **GoalieIQ Analytics** (short form GoalieIQ). Operated by Matias Baker, Ontario, Canada.
- Contact: goalieiqanalytics@gmail.com; Instagram @goalieiqanalytics.
- The public landing page opens on a full-bleed hero photograph of a goalie making a save, spanning edge to edge, with the headline set over the photo (user requirement, 2026-10-06).
- The redesign must avoid generic AI-generated looks and layouts (user requirement, 2026-10-06).

## Evidence on Hand

- Three real goalie testimonials with photos: Maija St-Pierre (`testimonial-maija.jpg`), Alex Beaupre (`testimonial-alex.jpg`), Marcus Cruz D'Annunzio (`testimonial-marcus.jpg`).
- Hero photograph supplied by the user (Team Canada goalie, diving glove save). Its license for commercial use has not been confirmed; see open decisions.
- The xG / GSAx methodology write-up on the About tab.
- Absent, must not be invented: user counts, accuracy or improvement statistics, customer logos, prices, press, partnerships, endorsements by any team, league, or player.

## Product Principles

1. Every number traces back to a tagged shot; show the evidence, not a verdict alone.
2. Separate what the goalie controls from what the team gave up.
3. Data exists to set the next practice, not to decorate a résumé.
4. Automation proposes, a human can always correct.

## Open Decisions

- Hero photograph rights: the supplied photo appears to be a professional wire photo of an identifiable national-team player. Confirm a commercial license (or replace it) before launch.
