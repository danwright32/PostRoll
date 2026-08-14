# PostRoll — Design System & Build Log

## Concept: "The Studio"

A professional photographer's editorial workspace. Warm, precise, intimate — like working inside a beautifully printed concert program. The app should feel like an extension of the content it produces: open it and you're already inside the brand.

**Signature detail**: Event names appear in SignPainter wherever they surface — sidebar rows, detail view headers, progress screens. The handwritten script creates a direct visual thread between the tool and the assets it generates.

---

## Color Palette

Defined in `Sources/DesignTokens.swift` and registered as the app accent via `Assets.xcassets/AccentColor.colorset`.

| Token | Hex | RGB | Use |
|---|---|---|---|
| `cream` | `#FCFAF7` | 252, 250, 247 | Main window / detail background |
| `creamDeep` | `#EDE8E0` | 237, 232, 224 | Sidebar, toolbar, secondary surfaces |
| `creamEdge` | `#D4C9C0` | 212, 201, 192 | Dividers, inactive field borders |
| `roseGold` | `#A06A5F` | 160, 105, 95 | Accent, interactive, active state, system accent |
| `roseDeep` | `#7D4E44` | 125, 78, 68 | Pressed / active rose gold |
| `warmDark` | `#3C3732` | 60, 55, 50 | Primary text |
| `warmMid` | `#7A6860` | 122, 104, 96 | Secondary text, icons, metadata |
| `warmFaint` | `#AFA098` | 175, 160, 152 | Placeholder text only — fails WCAG on creamDeep, never use for real content |

**Rule**: Never use `warmFaint` as a foreground color on any `creamDeep` background. Contrast ratio is ~2:1, which is unreadable. Use `warmMid` (4.4:1) as the minimum for secondary text.

---

## Typography

```swift
Font.signPainter(size)   // SignPainter-HouseScript — event names, headlines
Font.light(size)         // HelveticaNeue-Light — labels, metadata, captions
// SF Pro                // Body text, inputs, numbers — default system font
```

### Scale in use

| Context | Font | Size |
|---|---|---|
| Event name (sidebar row) | SignPainter | 19 |
| Event name (detail header) | SignPainter | 28–36 |
| Section labels (UPPERCASE) | SF Pro Medium | 10, tracking 1.2–1.4 |
| Body / input text | SF Pro | 13 |
| Metadata rows (org, date) | HelveticaNeue-Light | 11 |
| Stage pill | SF Pro Medium | 9, tracking 0.3 |
| Small labels | HelveticaNeue-Light | 11–12 |

---

## Spacing & Radii

```swift
Spacing.xs = 4    Radius.xs = 4
Spacing.sm = 8    Radius.sm = 6
Spacing.md = 16   Radius.md = 8
Spacing.lg = 24   Radius.lg = 12
Spacing.xl = 32
```

---

## Stage Pills

Unified warm palette. No rainbow. All defined in `StagePill` in `EventListView.swift`.

| Stage | Color |
|---|---|
| Created | `warmMid` |
| Program Uploaded | warm rose-brown |
| OCR Done | `roseGold` |
| Photos Assigned | warm amber-brown |
| Assets Generated | warm amber |
| Captions Reviewed | warm sage |
| Exported | warm green |

---

## Shared Components

All reusable components are defined inline in the view file where they first appear and shared via `internal` access.

| Component | File | Notes |
|---|---|---|
| `BrandTextField` | `NewEventSheet.swift` | cream bg, roseGold focus ring, `focusEffectDisabled()` |
| `BrandField` | `OCRReviewView.swift` | Compact version of BrandTextField for dense forms |
| `BrandTextArea` | `OCRReviewView.swift` | TextEditor variant, same styling |
| `BrandButtonStyle` | `SharedChrome.swift` | roseGold fill, cream text, 8pt radius |
| `BrandSectionLabel` | `NewEventSheet.swift` | Uppercase tracking label |
| `BrandBanner` | `BrandBanner.swift` | Rose-gold left-border info block |
| `BrandAddButton` | `OCRReviewView.swift` | `plus.circle` icon, roseGold |
| `BrandDeleteButton` | `OCRReviewView.swift` | `minus.circle` icon, warmMid |
| `StagePill` | `EventListView.swift` | Warm palette capsule tag |
| `RoseGoldDivider` | `DesignTokens.swift` | 0.5pt horizontal rule |
| `EventHeader` | `ProgramUploadView.swift` | SignPainter name + UPPERCASE subtitle + divider |

---

## Window Setup

Handled in `WindowConfigurator` (`MainWindowView.swift`), a `NSViewRepresentable` that runs after the SwiftUI view is placed in an `NSWindow`.

- `titlebarAppearsTransparent = true` — removes standard macOS chrome; the title strip shows `window.backgroundColor` (creamDeep)
- `titleVisibility = .hidden` — suppresses the "PostRoll" title text
- `backgroundColor = NSColor(Color.creamDeep)` — fills the title strip area
- `isOpaque = true` — prevents any compositing against windows behind PostRoll
- `NSApplication.shared.appearance = .aqua` — forces light mode globally, including DatePicker calendar popups and all other panels
- `fixVibrancy()` — walks the view hierarchy and switches all `NSVisualEffectView` instances from `.behindWindow` to `.withinWindow` blending, preventing the sidebar from showing other apps through it

**Accent color**: `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor` is set in `project.yml`. The `AccentColor.colorset` contains rose-gold (160/255, 105/255, 95/255). This makes rose-gold the system accent for selection highlights, DatePicker segments, toggles, and all AppKit tintable controls.

---

## List Selection

`EventListView` uses `List(selection:)` bound to `appState.selectedEventID`, and paints the selected row itself so the system highlight never shows:

- `listRowBackground` draws the selection, in `EventRowBackground`: `roseGold.opacity(0.12)` on a `RoundedRectangle(cornerRadius: Radius.md)`, with a rose-gold spine at the leading edge, and an opaque `creamDeep` fill on every other row so the system highlight cannot bleed through
- The accent colour is rose-gold app wide (see Window Setup), so what the system does draw is already the brand colour rather than the default blue this note was originally written about

---

## Focus Rings

All custom text inputs suppress the macOS system focus ring with `.focusEffectDisabled()`. The brand focus state is communicated solely through the rose-gold `strokeBorder` on the input background.

---

## PDF Upload

`ProgramUploadView` accepts both PDFs and images. PDFs are rasterised page-by-page using CoreGraphics (`CGPDFDocument` → `CGContext` → `CGImageDestination`) at 2× resolution, saved as PNGs to the app's data root, `~/Library/Application Support/PostRoll/programs/` (`AppPaths.programsDir`). It moved out of `~/Documents` with the data root, because that folder is TCC protected and the app was being re-prompted for access to its own files. This runs in a detached background task since CoreGraphics is thread-safe.

---

## Design Rules for Remaining Views

Apply these consistently as new views are built.

### Every detail view
- `EventHeader(event: event, subtitle: "Step Name")` at the top — SignPainter name, UPPERCASE subtitle in roseGold, RoseGoldDivider
- `ScrollView` wrapping content with `Spacing.xl` horizontal padding
- `.background(Color.cream)` on the scroll view

### Form fields
- Use `BrandTextField` (or `BrandField` for compact layouts) — never raw `TextField` with default styling
- Section labels: `BrandSectionLabel("Label")` or the inline UPPERCASE pattern
- `focusEffectDisabled()` on every `TextField` and `TextEditor`

### Buttons
- Primary action: `BrandButtonStyle()` — roseGold fill, cream text
- Secondary / inline: `.buttonStyle(.plain)` with `.foregroundStyle(Color.roseGold)`
- Destructive: `.role(.destructive)` in alerts only — don't use red in the UI

### Banners / callouts
- Use `BrandBanner(icon:message:)` for tips and warnings — rose-gold left border, warm tinted background
- No orange, no system yellow — everything lives in the warm rose-gold palette

### Empty states
- Centered `VStack`, `warmMid` text, `light(12–13)` font
- Optional: a roseGold icon at 40pt opacity 0.4

### No blue anywhere
- Never use `.accentColor(.blue)` or system blue explicitly
- Paint list selection yourself with `listRowBackground`, and give unselected rows an opaque fill, so no system highlight shows through
- Always add `focusEffectDisabled()` to inputs
- The accent color is set globally; trust it

---

## Phase 4 (shipped)

Every step of the GUI phase this document was written during has shipped: the
app shell and event CRUD, program upload and the OCR review loop, photo
assignment, asset generation, caption and blog review, and export.

Deliberately not a status table any more. It listed shipped work as Pending for
months, which is a document stating a fact the code contradicts (L32), and a
table nothing generates goes stale the day after it is written. What is
outstanding lives in GitHub issues, which is the one place it is maintained.
