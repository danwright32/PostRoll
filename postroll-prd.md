# PostRoll — Product Requirements Document

**Author:** Dan Wright
**Date:** April 4, 2026
**Status:** Planning / Pre-Development

---

## 1. Overview

PostRoll is a local Mac application that automates the weekly social media content pipeline for Dan Wright Photography. It replaces the current manual workflow of creating visual assets in Canva/Final Cut/Photoshop, writing captions, composing blog posts, and scheduling across platforms via Metricool.

The app is a GUI wrapper over Claude Code for AI-powered tasks (caption writing, blog drafting, collaborator lookup) and uses Python + ffmpeg for media processing. By using Claude Code as the LLM backend, there are no ongoing API costs for AI features.

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

**Engine:** Claude Code (invoked locally, no API cost)
**Style guide:** dan-wright-brand-voice skill (stored as app asset)

Per post, generates:
- 1-2 sentence caption in Dan's voice
- Required hashtags: venue, performer, #dwphotony, 2-3 additional relevant
- Identical caption used across all 5 platforms
- Alt text for images (15-25 words, per brand voice guidelines)

**Inputs:** Event name, venue, organization, performer names (from OCR), photo(s)

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

**Tool:** Python + Tesseract or Claude Code vision

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

- **GUI layer:** [TBD — Electron, Tauri, SwiftUI, or Python/tkinter]
- **AI engine:** Claude Code (invoked via CLI subprocess)
- **Media pipeline:** Python + Pillow (static images) + ffmpeg (video/audio)
- **Scheduling:** API client modules per platform (or single Metricool client)
- **Data storage:** Local SQLite database for event data, scheduled posts, account cache
- **OCR:** Tesseract or Claude Code vision capabilities

### 8.3 Workflow

1. Dan creates a new "event" in the app
2. Inputs: event name, organization, venue, date
3. Uploads program photos → app OCRs them for performer/piece data
4. Dan reviews/corrects OCR output
5. Uploads selected photos for the week (assigns them to days)
6. Uploads screen recording + audio for Tuesday reel
7. Uploads audio for Thursday reel
8. App generates all visual assets (stories, collages, reels, before/after)
9. Dan reviews visual assets, makes adjustments if needed
10. App generates captions for all posts and blog draft
11. Dan reviews/edits captions and blog
12. App suggests collaborator accounts → Dan confirms
13. App schedules everything for Sun-Fri
14. Dan handles any remaining manual tasks (story tagging) from a generated checklist

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

30. What GUI framework is preferred? Options: Electron (web tech, heavier), Tauri (Rust + web, lighter), SwiftUI (native Mac, fastest), Python + tkinter (simplest, ugliest)
31. Should the app support multiple events in progress at once, or one at a time?
32. Should there be a template/preset system for different recurring event types (e.g., DCINY events always use certain settings)?
33. For the Thursday scrolling reel — should there be an option for a tiny gap between photos, or always seamless?
34. For the Tuesday reel — what does the screen recording frame look like in the final reel? Full-screen vertical crop of the Lightroom window? Or placed on a background?

---

## 11. Open Questions — Content Details

35. What are the exact fonts used in the story template? (Need the script font and the spaced tracking font — or the Canva template to extract them)
36. What is the exact rose-gold color value for the divider?
37. What format is the DW Photography logo asset? (Need a high-res PNG with transparency)
38. For the masonry collage — are there specific layout arrangements you prefer, or should the app have 3-4 templates and rotate?
39. For the before/after labels ("RAW" and "Edit") — what font and size?
40. For the Thursday reel scroll — preferred total duration range (e.g., 15-30 seconds, or always target a specific length)?

---

## 12. Cost Analysis

### Current Costs
- Metricool: $216/year

### Projected Costs (Option B — Direct APIs)
- Hosting/infrastructure: $0 (local app)
- Claude Code: $0 (uses existing subscription)
- API costs: Most social media APIs are free for posting. Need to verify.
- ffmpeg/Pillow/Tesseract: Free (open source)
- **Total: ~$0/year** (potential full savings of $216/year)

### Projected Costs (Option A — Metricool API)
- Metricool: $216/year (unchanged)
- Everything else: $0
- **Total: $216/year** (no savings, but significant time savings)

### Development Cost
- Dan's time building the app (with Claude Code assistance)
- One-time investment regardless of Option A or B

---

## 13. Suggested Build Phases

### Phase 1 — Media Pipeline
Story template generator, before/after image generator, masonry collage generator, Tuesday speed edit reel, Thursday photo scroll reel. This is the most complex work and where the most time savings come from.

### Phase 2 — AI Content
Caption writing via Claude Code with brand voice skill. Blog post drafting via Claude Code. Program OCR pipeline.

### Phase 3 — Scheduling & Publishing
API research and decision (Metricool vs. direct). Platform API integrations. Built-in calendar (if direct APIs). Collaborator suggestion and invite system.

### Phase 4 — GUI
Application shell and interface. Event creation workflow. Asset review and approval screens. Schedule management view. Manual task checklist generator.
