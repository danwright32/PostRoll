# PostRoll — Product Requirements Document

**Author:** Dan Wright
**Date:** April 12, 2026
**Status:** In Development — Phase 4 (GUI) complete, Phase 5 (publishing) not started

---

## 1. Overview

PostRoll is a local Mac application that automates the weekly social media content pipeline for Dan Wright Photography. It replaces the current manual workflow of creating visual assets in Canva/Final Cut/Photoshop, writing captions, composing blog posts, and scheduling across platforms via Metricool.

The app is a GUI over Claude for AI-powered tasks (caption writing, blog drafting, collaborator lookup) and uses Python + ffmpeg for media processing. AI calls go through the Anthropic API with the key stored in the app's Keychain, which is metered per token: a week's generation is a real, recurring cost. The Claude Code CLI is a fallback, used only when no API key is set or when a call needs a CLI-only tool (WebSearch, WebFetch, Bash). An earlier version of this document claimed the AI features were free; they are not, and the cost analysis in section 12 has been corrected.

### 1.1 Goals

1. Automate creation of all visual assets (stories, reels, collages, before/after images)
2. Auto-generate captions in Dan's brand voice for all platforms
3. Auto-generate Squarespace blog post drafts
4. Schedule and publish to all platforms programmatically
5. Suggest collaborator accounts based on OCR'd program data
6. Eliminate Metricool subscription ($216/year) if direct APIs can match its capabilities — otherwise use Metricool's API for all scheduling

### 1.2 Non-Goals (for v1)

- Analytics and performance tracking (Metricool currently provides this — revisit if Metricool is dropped)
- Hashtag suggestion engine (brand voice skill already defines hashtag structure)
- Best-time-to-post optimization (revisit post-launch)
- Pinterest-to-blog linking strategy (good idea, but post-launch)

---

## 2. Current Workflow

The app replaces a manual process currently tracked in OmniFocus with ~30 sequential tasks per event. The current tools involved are:

| Task | Current Tool |
|---|---|
| Story image creation | Canva |
| Collage creation | Canva |
| Before/after image | Photoshop |
| Speed edit reel (Tuesday) | Final Cut Pro |
| Photo scroll reel (Thursday) | Final Cut Pro |
| Caption writing | Claude (manual) |
| Blog post writing | Claude (manual) |
| Scheduling | Metricool (manual) |
| Collaborator invites | Instagram app (manual) |
| Story tagging | Instagram app (manual) |
| Account lookup | Manual search |

---

## 3. Platforms

Content is posted identically across all platforms with the same captions.

| Platform | Post Types |
|---|---|
| Instagram | Feed posts, carousels, reels, stories |
| Facebook | Feed posts, carousels, reels, stories |
| TikTok | Reels/videos |
| Pinterest | Pins |
| Bluesky | Posts |

---

## 4. Weekly Content Schedule

The posting schedule is fixed at Sunday through Friday for every event. Content prep timing relative to the event varies (days to months after).

### 4.1 Sunday — Single Photo Post + Story

**Feed Post:**
- Single landscape/portrait photo from the event
- Caption in brand voice (1-2 sentences + hashtags)
- Posted to all 5 platforms identically
- Performers added as collaborators on Instagram

**Story:**
- Same photo, reformatted into story template
- Template components:
  - Full-screen blurred/enlarged version of the photo as background
  - Original photo placed in upper portion, maintaining aspect ratio
  - Subtle rose-gold divider line
  - White/cream lower section with event name in script font
  - Organization name and venue in spaced tracking
  - DW Photography logo
- Tagged with venue and performer accounts
- Posted to Instagram and Facebook

### 4.2 Monday — Single Photo Post + Story

Identical format to Sunday with a different photo from the same event.

### 4.3 Tuesday — Speed Edit Reel

**Reel:**
- Inputs: screen recording of Lightroom edit, audio file, RAW photo, edited photo
- Screen recording is sped up to fit within ~15-20 second target (minus closing frame duration)
- Speed multiplier auto-calculated based on recording length and target duration
- Audio auto-trimmed and faded to match final video length
- Closes on a static before/after frame (RAW on top labeled "RAW," edit on bottom labeled "Edit," blurred background)
- Posted to all 5 platforms
- Performers added as collaborators on Instagram
- Story cover image = the before/after closing frame

**Note:** Format is open to iteration. Dan feels current format leaves something to be desired. The pipeline should be flexible enough to experiment with layout variations (progress bars, different compositions, etc.)

### 4.4 Wednesday — Carousel Post + Collage Story

**Carousel Post:**
- 10 photos from the event
- Single caption in brand voice
- Posted to all 5 platforms (as carousel where supported, individual photos where not)
- Performers added as collaborators on Instagram

**Collage Story:**
- Masonry-style collage of the 10 carousel photos
- Layout: alternating full-width and split rows with varying sizes, thin gaps
- Small DW Photography logo watermark in corner
- No story template treatment (no blurred background, event name, etc.)
- Posted to Instagram and Facebook

### 4.5 Thursday — Photo Scroll Reel

**Reel:**
- Inputs: 20-100 photos from the event, audio file
- Photos stitched into a tall vertical strip, edge-to-edge (no background/padding)
- Reel is a smooth vertical scroll/pan from top to bottom with easing at start and end
- Scroll speed auto-calculated based on total image height and desired duration
- Photo display duration configurable (default ~0.5 seconds per photo, adjustable for more/fewer photos)
- Audio auto-trimmed and faded to match video length
- Posted to all 5 platforms
- Performers added as collaborators on Instagram

### 4.6 Friday — Before/After Story

**Story:**
- Uses the same RAW and edited photos from Tuesday
- Layout: blurred version of photo as full-screen background, RAW photo on top half labeled "RAW," edited photo on bottom half labeled "Edit"
- No story template treatment (no event name, logo, script font section)
- Saved to Instagram highlights after posting
- Posted to Instagram and Facebook

---

## 5. Media Processing Pipeline

### 5.1 Static Assets (stored once)

- DW Photography logo (PNG, transparent background)
- Script font for event names in story template
- Spaced tracking font for organization/venue in story template
- Rose-gold divider color value
- Story template layout parameters (margins, photo placement ratios, text positions)
- Masonry collage layout templates (predefined arrangements for 10 photos)

### 5.2 Story Template Generator

**Inputs:** Photo, event name, organization, venue
**Output:** 1080x1920 PNG

Process:
1. Create 1080x1920 canvas
2. Generate blurred/enlarged version of input photo as full background
3. Place original photo in upper portion, maintaining aspect ratio
4. Add rose-gold divider line
5. Add event name in script font (centered)
6. Add organization and venue in spaced tracking font (centered)
7. Add DW Photography logo (centered, bottom)

**Tool:** Python + Pillow

### 5.3 Before/After Image Generator

**Inputs:** RAW photo, edited photo
**Output:** 1080x1920 PNG

Process:
1. Create 1080x1920 canvas
2. Generate blurred version of edited photo as full background
3. Place RAW photo in upper half with "RAW" label (white text, upper left)
4. Place edited photo in lower half with "Edit" label (white text, upper left)
5. Semi-transparent overlay band behind each label for readability

**Tool:** Python + Pillow

### 5.4 Masonry Collage Generator

**Inputs:** 10 photos
**Output:** 1080x1920 PNG

Process:
1. Select a predefined masonry layout template
2. Crop/resize photos to fit allocated cells
3. Arrange on 1080x1920 canvas with thin gaps
4. Add small logo watermark in corner

**Tool:** Python + Pillow

### 5.5 Tuesday Speed Edit Reel

**Inputs:** Screen recording (video), RAW photo, edited photo, audio file
**Target duration:** 15-20 seconds (configurable)

Process:
1. Generate before/after closing frame (reuse Before/After Image Generator)
2. Calculate speed multiplier: recording_duration / (target_duration - closing_frame_duration)
3. Speed up screen recording by calculated multiplier
4. Append closing frame as static image (hold for ~3 seconds)
5. Trim audio to match total video duration
6. Apply audio fade-out in final 1-2 seconds
7. Composite final 1080x1920 vertical video
8. Export as MP4 (H.264, AAC audio)

**Tool:** ffmpeg via Python subprocess

### 5.6 Thursday Photo Scroll Reel

**Inputs:** 20-100 photos, audio file
**Default timing:** ~0.5 seconds per photo (configurable)

Process:
1. Resize all photos to 1080px wide, maintaining aspect ratio
2. Stitch vertically into one tall image strip (edge-to-edge, configurable gap: 0px default)
3. Calculate scroll duration based on photo count and per-photo timing
4. Create video: vertical pan from top to bottom of strip
5. Apply ease-in and ease-out to scroll
6. Trim audio to match video duration
7. Apply audio fade-out in final 1-2 seconds
8. Export as 1080x1920 MP4 (H.264, AAC audio)

**Tool:** ffmpeg via Python subprocess

---

## 6. AI Features

### 6.1 Caption Writing

**Engine:** Anthropic API (metered per token). The Claude Code CLI is the fallback when no API key is set.
**Style guide:** `postroll/assets/brand-voice.md` (loaded at runtime, evolves via Phase 4 feedback loop — see § 13)
**Source:** `postroll/ai/generate_captions.py`

Per post, generates:
- Post-level caption in Dan's voice (length varies by post type: 80–180 chars for single-photo feed, 120–280 for carousels/scroll reels)
- Required hashtags: venue, organization, performers visible, composer/playwright, #dwphotony, genre
- Identical caption used across all 5 platforms
- Per-photo alt text (15–35 words) even for multi-photo posts
- Per-photo scene labels matched from program/enrichment data

**Inputs:** Event name, venue, organization, date, shoot type, post type, photos, program OCR + enrichment, per-post `tag_handles` (@ mentions), per-post `name_mentions` (plain-text credits for people without handles), optional existing captions for the same event (to vary against)

**Post-type scope rules.** Captions are generated under one of two scope rules, selected from post_type:

- **Single-subject** (feed_photo, slider_reel, morph_reel, screen_reel, before_after_story): the caption body stays locked to what is visibly in THIS frame. Required @handles and name_mentions that aren't in the frame go on a trailing credit stack separated by one blank line — no "with" prefix, no narrative connector. This prevents single-photo posts from recapping the whole concert.
- **Event-level** (carousel, scroll_reel): the body can legitimately span the whole event. Credits can weave through the body or land in a stack.

**Multi-pass generation pipeline.** Each caption goes through 3 passes for single posts and 4 passes for week batches. Humanizer always runs LAST so nothing downstream can re-introduce AI tells:

1. **Draft.** Claude Code vision call with brand voice + program data + scope rule. Produces alt texts, scene labels, caption, and hashtags in a single JSON response.
2. **Voice review.** Narrower prompt asking only "does this sound like Dan?" against `brand-voice.md`. Rewrites cadence, removes press-release rhythms, fixes voice drift.
3. **Diversity review** *(week batch only)*. Looks at all 5 captions together and rewrites any that share structural shapes — same opener, same credit layout, same parallel rhythm. Prevents Mad-Libs across the week.
4. **Humanizer** (FINAL, non-negotiable). The humanizer skill at `~/.claude/skills/humanizer/SKILL.md` runs as the last pass. Enforces Dan-specific hard bans: no em dashes, no parallel-three credit structures (opened/middle/closed), no comma-list openers, no copula avoidance verbs ("took the podium"), no photo-description bodies, no "same X, same Y" rhetorical parallelism. Zero tolerance — captions are scanned twice for violations before returning.

**Batch entry point.** `generate_week_captions()` runs all 5 posts in a week through the pipeline in ONE set of Claude calls (one per pass, not per post). Dramatically cheaper than 5 separate calls and naturally produces cross-caption variation because the model sees all 5 at once during the diversity pass.

### 6.2 Blog Post Writing

**Engine:** Claude Code
**Style guide:** dan-wright-brand-voice skill (blog section)
**Destination:** Squarespace (via API if available, otherwise draft for manual paste)

Structure (per brand voice skill):
- 10-12 short paragraphs
- Opens with personal observation about the performance/venue
- No subheadings or section headers — continuous prose with paragraph breaks
- Embeds 4-7 photos directly
- Closes with helpful, non-pushy CTA

**Inputs:** Event name, venue, organization, date, performer names (from OCR), program details (from OCR), selected photos

### 6.3 Program OCR

**Purpose:** Extract performer names, piece titles, ensemble names, and other event metadata from uploaded photos of the event program.

**Used for:**
- Populating caption fields (performer names, event details)
- Blog post content (program details, repertoire)
- Collaborator suggestion engine (matching performer names to Instagram accounts)

**Tool:** Python + Claude vision (`postroll/ai/ocr_program.py`), with macOS `sips` for image conversion and Apple Vision for the searchable text layer baked into the stored PDF. Tesseract was considered and never used.

### 6.4 Collaborator Suggestion Engine

**Purpose:** Given performer/ensemble names (from OCR), find likely Instagram accounts and present them for confirmation.

Process:
1. Take performer/ensemble names from OCR output
2. Search Instagram for matching accounts (via Graph API search or web lookup)
3. Present suggested accounts with profile links for Dan to confirm/reject
4. Send collaborator invites for confirmed accounts via API

**Open question:** Instagram Graph API may not support account search or collaborator invites — see Section 9.

---

## 7. Scheduling & Publishing

### 7.1 Decision: Metricool API vs. Direct APIs

This is a binary decision, not a fallback chain:

**Option A — Metricool API:** Use Metricool's API for all scheduling across all platforms. Keep $216/year subscription. App creates all content and pushes it to Metricool programmatically.

**Option B — Direct APIs:** Post directly to each platform's API. Eliminate Metricool. App manages its own scheduling calendar.

Decision criteria: whichever option covers the most required functionality. See Section 9 for open research questions.

### 7.2 Required Scheduling Capabilities

| Capability | Required |
|---|---|
| Schedule feed posts (all platforms) | Yes |
| Schedule carousels (Instagram, Facebook) | Yes |
| Schedule reels (Instagram, Facebook, TikTok) | Yes |
| Schedule stories (Instagram, Facebook) | Yes |
| Schedule pins (Pinterest) | Yes |
| Schedule posts (Bluesky) | Yes |
| Send collaborator invites (Instagram) | Yes |
| Tag accounts in stories (Instagram) | Nice to have (currently manual even with Metricool) |
| Embed images in blog draft (Squarespace) | Yes |

### 7.3 Built-In Calendar (Option B only)

If direct APIs are chosen, the app needs:
- Weekly calendar view showing all scheduled posts
- Ability to preview each post before it goes live
- Queue management (reschedule, delete, reorder)
- Status tracking (scheduled, posted, failed)
- Retry logic for failed posts

---

## 8. Application Architecture

### 8.1 App Type

Local Mac desktop application with GUI. Not a web app. Runs on Dan's machine.

### 8.2 Core Architecture

- **GUI layer:** SwiftUI (native macOS, chosen April 2026)
- **AI engine:** Anthropic API via the Python SDK, with the Claude Code CLI as a fallback (no key set, or a call needing WebSearch/WebFetch/Bash)
- **Media pipeline:** Python + Pillow (static images) + ffmpeg (video/audio)
- **Scheduling:** API client modules per platform (or single Metricool client)
- **Data storage:** Local SQLite database for event data, scheduled posts, account cache
- **OCR:** Claude vision, plus macOS `sips` and Apple Vision. Not Tesseract.

### 8.3 Workflow

Steps 1–8 are fully implemented in the GUI as of April 12, 2026. Steps 9–11 are not yet built.

1. Dan creates a new "event" in the app (name, org, venue, date, shoot type)
2. Uploads program photos (PDF pages or images) → app OCRs them via Claude Vision
3. Dan reviews/corrects OCR output (performers, pieces, scenes, notes)
4. Assigns photos to posting days (Sun–Fri) and blog; drag to reorder within each day
5. Optionally adds per-day @handles and plain-name credits
6. App generates all captions + blog draft via `generate_week.py` (Claude Code, 3–6 min)
   - Large Thursday shoots (50+ photos): Claude Vision auto-selects best 20 for the scroll reel
7. Dan reviews/edits captions, hashtags, and alt texts; can request plain-English revision per caption
   - Feedback optionally saved to `brand-voice.md` for all future events
8. Dan exports: captions, blog draft, checklist written to a dated folder; story images + Wednesday collage generated via PIL (20–60 sec); Dan opens folder in Finder
9. *(Phase 5)* App suggests collaborator accounts → Dan confirms
10. *(Phase 5)* App schedules everything for Sun-Fri via direct platform APIs or Metricool
11. Dan handles remaining manual tasks (story tagging, Instagram highlights) from the CHECKLIST.md

### 8.4 Manual Task Checklist

The app generates a checklist of actions that cannot be automated, including:
- Tag stories on Instagram (no API support)
- Any other platform-specific manual steps identified during API research
- Save Friday before/after story to highlights
- Add Instagram post link to OmniFocus one-year follow-up reminder
- Promote trial reel to followers
- Hide reel from main feed

---

## 9. Open Questions — API Research Required

### 9.1 Instagram Graph API

1. Can it schedule and publish stories?
2. Can it send collaborator invites on posts/reels?
3. Can it search for accounts by name (for collaborator lookup)?
4. Can it post carousels?
5. Can it post reels with custom cover images?
6. What are rate limits and content size limits?
7. Does it require a Facebook Page connected to the Instagram Business account?

### 9.2 Facebook Graph API

8. Can it schedule and publish stories?
9. Can it post carousels?
10. Can it post reels?

### 9.3 TikTok API

11. Can it schedule video posts?
12. What are video format/size requirements?
13. Does it require a developer app approval process?

### 9.4 Pinterest API

14. Can it schedule pins?
15. Can it upload video pins?
16. Can pins link to a URL (for future blog linking)?

### 9.5 Bluesky API

17. Can it schedule posts?
18. Can it attach images?
19. Can it attach video?

### 9.6 Metricool API

20. Does Metricool have a public API?
21. Can it programmatically create and schedule posts?
22. Can it send collaborator invites via API?
23. Can it schedule across all 5 platforms?
24. What authentication method does it use?

### 9.7 Squarespace API

25. Can it create blog post drafts with embedded images?
26. What is the image upload/embedding workflow?
27. What authentication method does it use?

### 9.8 Collaborator Invites

28. How does Metricool currently send collaborator invites — is this a documented API feature or undocumented?
29. If Instagram's API doesn't support collaborator invites, is this a dealbreaker for dropping Metricool?

---

## 10. Open Questions — Design & UX

30. ~~What GUI framework is preferred?~~ **Resolved:** SwiftUI (native macOS). Chosen April 2026.
31. ~~Should the app support multiple events in progress at once, or one at a time?~~ **Resolved:** Multiple events. Sidebar shows all events; any can be selected and worked independently.
32. Should there be a template/preset system for different recurring event types (e.g., DCINY events always use certain settings)?
33. For the Thursday scrolling reel — should there be an option for a tiny gap between photos, or always seamless?
34. For the Tuesday reel — what does the screen recording frame look like in the final reel? Full-screen vertical crop of the Lightroom window? Or placed on a background?

---

## 11. Open Questions — Content Details

35. ~~What are the exact fonts used in the story template?~~ **Resolved:** SignPainter HouseScript (event name, 100pt) + Helvetica Neue Thin (org/venue, 38pt, wide tracking). Both are macOS system fonts.
36. ~~What is the exact rose-gold color value for the divider?~~ **Resolved:** `#C4877A` (RGB 196/135/122) in Python; `Color(red: 160/255, green: 105/255, blue: 95/255)` in SwiftUI.
37. ~~What format is the DW Photography logo asset?~~ **Resolved:** `postroll/assets/logo-white.png` and `logo-black.png` (PNG with transparency).
38. ~~For the masonry collage — are there specific layout arrangements you prefer?~~ **Resolved:** 4 top patterns + 5 bottom patterns, randomly selected per generation. Each handles exactly 5 photos per half. Seed is stable so same photos → same layout.
39. For the before/after labels ("RAW" and "Edit") — what font and size?
40. For the Thursday reel scroll — preferred total duration range (e.g., 15-30 seconds, or always target a specific length)?

---

## 12. Cost Analysis

### Current Costs
- Metricool: $216/year

### Projected Costs (Option B — Direct APIs)
- Hosting/infrastructure: $0 (local app)
- **Anthropic API: metered per token, not $0.** Every week's run makes multi-pass
  caption calls, a blog call, and vision calls over the photos, all billed
  against Dan's own API key. This line previously read "$0 (uses existing
  subscription)", which was never true of the shipped app: the key is stored in
  the Keychain and the metered SDK path is the default. The Claude Code CLI
  path, which does draw on the subscription instead, runs only when no key is
  set or a call needs a CLI-only tool.
- API costs: Most social media APIs are free for posting. Need to verify.
- ffmpeg/Pillow: Free (open source)
- **Total: Anthropic usage per week, plus $0 for everything else.** The $216/year
  Metricool saving still stands; it is offset by whatever the AI usage comes to,
  which is not currently measured or displayed anywhere in the app.

### Projected Costs (Option A — Metricool API)
- Metricool: $216/year (unchanged)
- Anthropic API: the same metered usage as Option B
- Everything else: $0
- **Total: $216/year plus Anthropic usage** (no Metricool savings, but significant time savings)

### Development Cost
- Dan's time building the app (with Claude Code assistance)
- One-time investment regardless of Option A or B

---

## 13. Build Phases — Status

### Phase 1 — Media Pipeline ✅ Complete
Story template generator, before/after image generator, masonry collage generator, Tuesday speed edit reel, Thursday photo scroll reel.

### Phase 2 — AI Content ✅ Complete
Caption writing via Claude Code with brand voice skill. Blog post drafting. Program OCR pipeline. Multi-pass generation (draft, voice review, diversity review, humanizer). Batch week caption generation.

### Phase 3 — Export Pipeline ✅ Complete (April 12, 2026)
`audio.py` with Jamendo auto-fetch for licensed audio. The export itself is
native Swift (`EventExporter` and `ExportManager`); the original Python
`export.py` was retired in August 2026 after the app stopped calling it.

### Phase 4 — GUI ✅ Complete (April 12, 2026)
**Framework:** SwiftUI (native macOS). **App icon:** rose-gold P over camera aperture.

| Step | Description | Status |
|---|---|---|
| 1 | App shell — NavigationSplitView, AppState, event CRUD, persistence | ✅ Done |
| 2 | OCR flow — program upload (PDF + images), progress view, review/correction loop | ✅ Done |
| 3 | Photo assignment — drag photos to posting days, select 4–7 blog photos; drag-to-reorder within day grid; Wednesday collage warning (>10 photos) | ✅ Done |
| 4 | Asset generation — invoke `generate_week.py`, animated progress, per-day @handles + plain-name fields; representative photo sampling (Claude Vision picks best 20 from 50+ photos for scroll reels via `select_reel_photos.py`) | ✅ Done |
| 5 | Caption + blog review — per-day accordion, inline editing, hashtag editor, alt texts collapsible, revision feedback loop with plain-English feedback per caption | ✅ Done |
| 6 | Export — two-phase: text (captions, blog draft, checklist) then media generation (story images via PIL for all days, Wednesday masonry collage via PIL) via `generate_media.py`; non-fatal skip option if media fails | ✅ Done |
| 7 | Feedback loop — revision feedback saved to `brand-voice.md` via checkbox in revision panel; back navigation across all stages so any step is reversible | ✅ Done |

**What the feedback loop does now.** In the caption review step, every "Revise with feedback" panel has a "Save this feedback to brand voice for all future events" checkbox. When checked, the feedback text is appended to `postroll/assets/brand-voice.md` under a `## Caption revision notes` section. This provides the permanent-rule half of the feedback loop. The final-version capture mechanism (diff analysis, periodic batch proposal) is deferred to a future phase.

**Back navigation.** All 7 stages have a back button. Going back preserves all data — photos, handles, captions, and OCR results are all saved on every change, so reversing is always safe.

### Phase 5 — Publishing 🔲 Not Started

Direct platform API publishing or Metricool API integration. Blocked on API research (see Section 9). Collaborator suggestion engine also in this phase.
