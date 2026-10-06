---
name: GoalieIQ Analytics
description: Shot-level goaltending analytics, cut and stitched like a goalie's custom pads.
colors:
  pu-face: "#F4F5F1"
  face: "#FFFFFF"
  channel: "#ECEEE8"
  ink: "#121412"
  ink-2: "#3B413C"
  muted-ink: "#596159"
  pine: "#0F4A35"
  pine-deep: "#0A3627"
  pine-bright: "#17704F"
  on-pine: "#EEF5F0"
  on-pine-2: "#B3CEBF"
  gold: "#E8B923"
  gold-deep: "#7A5D00"
  save: "#17704F"
  save-wash: "#E5F0EA"
  goal: "#B42318"
  goal-wash: "#FBEAE8"
  warn: "#7A5300"
  warn-wash: "#FBF1DA"
  seam: "rgba(18,20,18,.13)"
  seam-strong: "rgba(18,20,18,.26)"
  stitch: "rgba(18,20,18,.42)"
  rink-ice: "#FCFDFC"
  rink-red: "#C8102E"
  rink-blue: "#1F5FBF"
typography:
  display:
    fontFamily: "Archivo, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "clamp(2.75rem, min(5.6vw, 9.5svh), 5.25rem)"
    fontWeight: 900
    lineHeight: 0.88
    letterSpacing: "0.002em"
    fontVariation: "'wdth' 62"
  headline:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "clamp(2.25rem, 4.6vw, 3.75rem)"
    fontWeight: 900
    lineHeight: 0.92
    fontVariation: "'wdth' 64"
  page-title:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "34px"
    fontWeight: 850
    lineHeight: 1
    letterSpacing: "0.005em"
    fontVariation: "'wdth' 70"
  title:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 800
    lineHeight: 1.1
    letterSpacing: "0.01em"
    fontVariation: "'wdth' 78"
  metric:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "34px"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.005em"
    fontFeature: "'tnum'"
    fontVariation: "'wdth' 78"
  body:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Archivo, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 650
    lineHeight: 1.3
    letterSpacing: "0.07em"
rounded:
  chip: "4px"
  sm: "6px"
  lg: "10px"
spacing:
  hairline-gap: "6px"
  gutter: "16px"
  panel: "20px"
  section-break: "38px"
  page-edge: "clamp(16px, 4vw, 48px)"
  landing-section: "96px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.pu-face}"
    typography: "{typography.title}"
    rounded: "{rounded.sm}"
    padding: "13px 22px"
  button-primary-hover:
    backgroundColor: "{colors.pine}"
    textColor: "{colors.pu-face}"
  button-primary-on-photo:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "13px 22px"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "9px 14px"
  button-secondary-hover:
    backgroundColor: "{colors.channel}"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.goal}"
    rounded: "{rounded.sm}"
    padding: "8px 14px"
  tag-button:
    backgroundColor: "{colors.face}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "9px 14px"
  tag-button-selected:
    backgroundColor: "{colors.pine}"
    textColor: "{colors.on-pine}"
  input:
    backgroundColor: "{colors.face}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "10px 11px"
  panel:
    backgroundColor: "{colors.face}"
    textColor: "{colors.ink}"
    rounded: "0"
    padding: "{spacing.panel}"
  result-save:
    backgroundColor: "{colors.save-wash}"
    textColor: "{colors.save}"
    rounded: "{rounded.sm}"
    padding: "3px 9px"
  result-goal:
    backgroundColor: "{colors.goal-wash}"
    textColor: "{colors.goal}"
    rounded: "{rounded.sm}"
    padding: "3px 9px"
  result-otl:
    backgroundColor: "{colors.warn-wash}"
    textColor: "{colors.warn}"
    rounded: "{rounded.sm}"
    padding: "3px 9px"
  nav-tab:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.pu-face}"
    padding: "14px 14px 12px"
---

# Design System: GoalieIQ Analytics

## Overview

**Creative North Star: "Custom Pads"**

GoalieIQ is built the way a goalie's custom pads are built. The ground is the white PU face of a pad. Colour panels in pine green break at one hard angle. Black outer-roll bands frame the edges, gold piping is the only accent, and stitching does the work that shadows and card borders do elsewhere. Seams are dashed rules, panels are bound by a single ink edge at the top, and rows of numbers sit in one quilted strip divided by stitch instead of floating as separate tiles.

The voice is the wordmark printed on a pad: Archivo, extra-condensed, black, italic, uppercase, for every heading. Numbers drop to a condensed width with tabular figures. Body text runs at normal width so it reads at length. One variable family at five widths carries every level of the hierarchy. The density is that of a working tool, built for a goalie or coach reading a game shot by shot. On the landing page the full-bleed save photograph owns the first viewport, and pad construction takes over beneath it.

Results are coded by stitch, so they never rely on colour alone. A save is a solid stitch, a goal is a broken (dashed) stitch, and an overtime loss is dotted, wherever a result appears. This system rejects the category default of a dark navy dashboard with glowing charts and a photo hero over three feature cards.

**Key Characteristics:**
- Light PU-white ground, pine panels, ink bands, gold piping as the single accent.
- Dashed stitch rules in place of shadows and card borders on resting surfaces.
- Panels carry only a 2px ink top binding: no box, no radius.
- One hard angle (a single clip-path break) is how a colour panel ends.
- Archivo at five widths: 62-64% display, ~70% page titles, ~78% titles and metrics, ~80-90% buttons and labels, 100% body.
- Save = solid, goal = broken, OTL = dotted, everywhere.
- Motion is short exponential ease-outs that play once. Nothing loops.

## Colors

The palette is pad material: a warm off-white face, deep pine, near-black ink, and one gold piping colour. Result colours exist only to back up the stitch code.

### Primary
- **Pad Pine** (pine): the colour panel. Used for the app header, the landing proof panel, pad headers, the first block of the game-overview hero, modal headers, selected tag buttons, the user's coach-chat bubbles, and the primary-button hover. **Deep Pine** (pine-deep) is its darker cut. **Bright Pine** (pine-bright) is the link colour on light grounds.
- **On-Pine White** and **On-Pine Sage** (on-pine, on-pine-2): primary and secondary text on pine panels.

### Secondary
- **Gold Piping** (gold): the single accent. It appears as the 3px rule above the ink nav and footer, the active nav underline, the dashed inner stitch on primary buttons, the season badge, the text-selection colour, the puck tag's ring and leader, the "Start free" button over the photo, and the GSAx figure on the landing page. **Deep Gold** (gold-deep) is the legible text-weight version, used for sample and AI chips on light grounds.

### Tertiary (result coding)
- **Save Green** (save, with save-wash): saves, wins, improvement, positive deltas. Always paired with a solid stitch or solid fill.
- **Goal Red** (goal, with goal-wash): goals against, losses, errors, destructive actions. Always paired with a dashed stitch.
- **Warning Umber** (warn, with warn-wash): overtime losses (dotted stitch), pending access, caution.

### Neutral
- **PU Face** (pu-face): the page ground, and the hover tint for table rows.
- **Face White** (face): panel faces, fields, and buttons on PU.
- **Channel** (channel): quiet fills for neutral pills, menu hover, and the secondary-button hover.
- **Ink** (ink): text, outer-roll bands (nav, footer, testimonial band, pad rolls), panel bindings, and the primary button.
- **Ink 2 / Muted Ink** (ink-2, muted-ink): secondary text, captions, and labels.
- **Seam / Seam Strong / Stitch** (seam, seam-strong, stitch): translucent ink for hairlines, dashed stitch rules and field borders, and the inset stitch on stitched cards.

### Rink markings (data surfaces only)
- **Rink Ice, Rink Red, Rink Blue** (rink-ice, rink-red, rink-blue): the shot map paints the real defensive-zone markings: goal line, faceoff circles and crease in red, blue line in blue, on ice-white. These are the rink's own materials, so the single-accent rule does not apply to them. They never leave the rink drawing.

### Named Rules
**The Gold Piping Rule.** Gold is the only accent. It is piping, so it appears as rules, stitches, rings and small badges, never as a large fill. The one exception is a primary action set directly on the hero photo, where ink would disappear.

**The Stitch Code Rule.** A result is never colour alone. Save = solid stitch or fill, goal = broken (dashed) stitch, OTL = dotted. This holds on result pills, trend badges, shot-map markers, legends, and the landing ledger.

## Typography

**Display Font:** Archivo variable, self-hosted (wdth 62-125, wght 100-900, roman and italic), with a system-ui fallback.
**Body Font:** Archivo at normal width.

**Character:** One family stretched across five widths, the way a pad maker uses one lettering style at different sizes. Headings are extra-condensed black italic caps that look printed onto the gear. Body text is plain, normal-width Archivo, set for reading.

### Hierarchy
- **Display** (900 italic, 62% width, clamp(2.75rem, min(5.6vw, 9.5svh), 5.25rem), line-height 0.88, uppercase, max 14ch): the hero headline over the photo. The wordmark uses the same voice (900 italic, 64% width, 28-30px).
- **Headline** (900 italic, 64% width, clamp(2.25rem, 4.6vw, 3.75rem), line-height 0.92, uppercase): landing section heads. Pad headers use the same treatment at clamp(1.75rem, 3vw, 2.5rem).
- **Page title** (850 italic, 70% width, 34px, 30px on phones, line-height 1, uppercase): app page heads and paywall heads.
- **Title** (800-850 italic, 72-78% width, 19-22px, uppercase): section heads, channel heads, modal heads, goalie names, plan names. Nav tabs (750 italic, 78% width, 15px) and buttons (800 italic, 80% width, 16px) use the same voice.
- **Metric** (800-850 roman, 75-78% width, 34px; 46px on hero metrics, 22px in goalie cards; tabular figures): every compared number.
- **Body** (400, 15px, line-height 1.55, normal width): running text, capped at 60-75ch.
- **Label** (650-750, 11-13px, uppercase, letter-spacing .05-.07em, normal to 90% width): metric labels, table headers, panel h3s, field-group labels.

### Named Rules
**The Five Widths Rule.** Width, not a second typeface, sets the hierarchy. The narrower the width, the louder the level. Body text never goes condensed, and headings never run at normal width.

**The Tabular Rule.** Any number that is compared (tables, metrics, scores, counters, prices) uses tabular figures.

## Layout

The app is a centred column (max 1500px; padding 34px 32px 80px, and 24px 16px 56px under 750px) under a pine header and an ink nav bar. Content stacks in grids of 2, 3 or 4 columns with a 16px gutter. These collapse to 2 columns at 1100px and to 1 at 750px. Sections are separated by a full-width dashed stitch rule with 38px above it, not by boxes. A row of metric tiles is a single strip: the grid gap goes to zero, one ink binding runs across the top, and dashed vertical dividers separate the tiles. These turn horizontal when the strip stacks on phones.

The landing page runs edge to edge with page-edge padding of clamp(16px, 4vw, 48px), an inner measure of 1240px, and roughly 88-104px of vertical rhythm between sections (72px on phones). The hero photo covers a full viewport (max(600px, 100svh - 96px)), anchored right so the puck is never cropped. On phones the photo sits above and the copy moves onto ink below it. The proof panel runs as tall channels divided by dashed stitch (1.25fr / 1fr / 1fr), not as a card grid. It goes to 2 columns at 1100px and stacks at 750px. Breakpoints are 1100, 900, 750 and 480px.

## Elevation & Depth

Resting surfaces are flat. Depth comes from material: tonal steps between PU, face, channel, pine and ink, an ink binding along a panel's top edge, and dashed stitch rules. Shadows appear only on layers that float above the page (dropdown menu, modal, toast, cookie notice, the hero tag label, the feedback button), and always as one soft ink-tinted drop. Field focus uses a pine halo rather than elevation.

### Shadow Vocabulary
- **Menu lift** (`box-shadow: 0 14px 32px -8px rgba(18,20,18,.28)`): the nav dropdown menu.
- **Modal lift** (`box-shadow: 0 24px 60px -12px rgba(18,20,18,.45)`): dialogs, over an ink scrim at 55%.
- **Toast lift** (`box-shadow: 0 14px 30px -10px rgba(18,20,18,.5)`): toasts. The cookie notice (0 16px 36px -12px, .55) and feedback button (0 10px 24px -8px, .5) are close variants.
- **Field focus** (`box-shadow: 0 0 0 3px rgba(15,74,53,.16)`): a pine halo on focused inputs.

### Named Rules
**The Stitch, Not Shadow Rule.** Nothing that rests on the page casts a shadow. Separate resting things with a dashed stitch rule or an ink binding. Shadows belong to floating layers only.

## Shapes

Corners are barely softened: 6px on controls, pills and badges, 10px on floating surfaces (modals, menus, auth card, plan rows, rink frames), and 4px on the smallest chips and ledger blocks. App panels have no radius at all, because a panel is a pad face bound at the top, not a box. Colour panels end in one hard angle made with a clip-path polygon that breaks a single edge: the hero photo into the pine proof panel (clamp(56px, 8vw, 120px) of rise), each landing pad and its pine header (22px and 18px, mirrored left and right), and the pine block of the game-overview hero (22px on the side, 16px on the bottom on phones). Stitches are 1-2px dashed lines. Inset stitching uses an outline with a negative offset, for example -5px on buttons and -9px on the auth and paywall cards.

**The One Break Rule.** A colour panel breaks at one hard angle, on one edge, once. Never two angles on a panel, and never a curve.

## Components

### Buttons
Ink and gold stitching. These are confident, pad-lettered actions.
- **Shape:** gently softened (6px).
- **Primary:** an ink face with PU text, 800 italic caps at 80% width, 16px, padding 13px 22px, and a dashed gold inner stitch (1.5px outline at -5px offset). Hover turns it pine, press moves it down 1px, focus shows a solid 2px gold ring outside. Over the hero photo, and in the cookie notice, the primary inverts to a gold face with ink text and an ink stitch.
- **Secondary:** transparent with a 1.5px solid ink border, 14px 650-weight normal-width text. Hover fills it with channel.
- **Danger:** transparent with a 1.5px dashed goal-red border and goal-red text. Hover fills it with goal-wash.
- **Small actions** (watch, nav arrows, steppers): face with a seam-strong border. Hover brings the border to ink or pine.

### Chips and Pills
- **Result pills:** 11px 800 caps on the result's wash colour. The border is a 1.5px solid save, dashed goal, or dotted warn stitch. On the pine hero block the result pill turns gold.
- **Trend badges:** the same code. Improving is solid save, declining is dashed goal, flat is a solid seam border on channel.
- **Sample / AI chips:** 10px caps in deep gold with a 1px dashed deep-gold border, 4px radius.

### Cards / Containers
- **Corner Style:** none on panels. 10px on floating containers.
- **Background:** face white on PU ground.
- **Border:** only a 2px ink top binding. Internal divisions are 1px dashed seam-strong rules.
- **Internal Padding:** 20px (24px on hero metric panels).
- **Stitched variant:** the auth card, paywall, and goalie card on hover carry a 1.5px dashed inset stitch at -7 to -9px.

### Inputs / Fields
- **Style:** face white, 1.5px seam-strong border, 6px radius, padding 10px 11px, 14-15px text. File inputs switch to a dashed border on PU.
- **Focus:** the border turns pine with a 3px pine halo.
- **Error:** messages sit in a goal-wash box with a dashed goal border. Success messages use save-wash with a solid save border.

### Navigation
The app header is a pine panel with the italic wordmark. Below it runs an ink outer-roll nav bar with a 3px gold rule along its top edge. Tabs are 750 italic caps at 78% width, set in 72% PU. Hover brightens the text and adds a faint gold underline. The active tab has full PU text and a 3px gold underline. On the landing page, the bar floats over the photo on a PU fade: an ink wordmark with "IQ" in pine, italic caps links, and an ink Sign-in pill with a gold stitch. Secondary links hide under 900px.

### Shot Map (signature)
The real defensive zone is drawn on ice-white, inside a 1.5-2px ink frame with a 10px radius. A save is a small solid save-green dot with a fine white edge. A goal is a white-filled dashed ink ring with an ink centre, drawn above the saves. The pin being placed is a dashed ink ring around a gold centre. Legends repeat the same marks.

### Puck Tag (signature)
On the hero, a dashed gold ring settles onto the puck, a dashed gold leader draws out from it, and then a PU label with an inset stitch lands. Its result chip is solid save. The sequence plays once, as exponential ease-outs: ring .5s, leader .55s, label .5s, staggered from .5s to 1.25s.

### Pads (landing pair)
Two mirrored face-white panels. Each has a 16px ink outer roll on its outside edge, a pine header cut at one angle, one dashed quilting channel down the face, and dashed rules between rows.

## Do's and Don'ts

### Do:
- **Do** code every save, goal and OTL by stitch as well as colour: solid, broken (dashed), dotted.
- **Do** bind app panels with a single 2px ink top edge and divide their insides with dashed seam-strong rules.
- **Do** join a row of metric tiles into one strip with dashed dividers, not separate cards.
- **Do** end a colour panel with one hard clip-path angle.
- **Do** set headings in Archivo black italic caps at 62-78% width, numbers condensed with tabular figures, and body text at normal width.
- **Do** keep gold to piping: rules, stitches, rings, the season badge, and the one primary action on the photo.
- **Do** use the shared out-expo ease (cubic-bezier(.16,1,.3,1)) for short, one-time motion, and honour reduced motion.

### Don't:
- **Don't** put shadows, radii or full borders on resting panels. Use stitch and binding instead.
- **Don't** add a second accent colour. The rink's red and blue stay inside the rink drawing.
- **Don't** signal a result with colour alone.
- **Don't** add eyebrow or kicker labels above headings.
- **Don't** break a panel at more than one angle, or round the break.
- **Don't** build a dark navy dashboard, glowing charts, or a photo hero over three feature cards.
- **Don't** set body copy condensed or italic.
