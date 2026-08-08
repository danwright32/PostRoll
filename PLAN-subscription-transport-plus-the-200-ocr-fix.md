# Plan council: subscription transport plus the #200 OCR fix
Run 2026-08-08. Six panelists (architect, backend, product, ux, security, red team), three rival whole options, champion and red team each, scored against criteria fixed before any option existed.

## READ THIS FIRST: the plan is NOT fully verified
The reality check ran twice and still returned **needs-fixes**. Known-wrong claims:

- THE HALT CANNOT FIRE. generate_week.py has four `except Exception` handlers the plan's eight-site swallow table misses entirely: :158 (friday frame extraction), :221 (wrapping the `select_reel_photos` Claude call), :257 (the whole per-day caption block) and :282 (the blog). :257 and :282 sit above every one of the eight `except ClaudeError` sites on the call stack. A `ClaudeQuotaError` that deliberately does not subclass ClaudeError is still an Exception, so on a cap wall it is caught at :257, written into `errors[day_name]`, and the loop continues to the next day and then the blog, hammering the exhausted cap for the rest of the run. `generate_week` then returns normally and `__main__` falls off the end, so the process exits 0. Phase 4.2's carrier requires exit code 3, which nothing can produce. Net effect: the halted screen is unreachable, Dan is never asked, and the run silently degrades exactly the way the plan exists to prevent. Phase 5.5 must add an explicit step making these four handlers re-raise ClaudeQuotaError (catch Exception, `isinstance` check, re-raise), and `__main__` must catch it, write the halted checkpoint, and `sys.exit(3)`. :221 is the nastiest of the four because it silently substitutes "first N photos" for a Claude selection and then keeps calling Claude.

- THE 130-TOKEN FLOOR IS WRONG BY ~49x, AND THE 45x CWD SWING DOES NOT EXIST. Measured live, warm, three ways with the plan's exact pinned flags: pinned from a scratch cwd with no project memory = 6,390 total input tokens (3 input + 6,387 cache_read); pinned from the PostRoll repo root = 12,233; unpinned from the repo root = 53,835. Project memory adds 5,843, which is almost exactly the plan's "5,845" figure, so the plan appears to have reported the memory delta as the repo-root total and to have counted input_tokens plus cache_read while ignoring cache_creation. Consequences: (a) Phase 5.2's live guard asserting "input tokens under 500" would fail on its first run and permanently, so it is unshippable as written and the real ceiling is around 7,000; (b) Phase 5.6's cap arithmetic "calibrated on 130 tokens per call" is off by a factor of ~49, and at ~30 Claude calls per week that is roughly 192,000 tokens of pure per-call overhead rather than the ~4,000 assumed, which changes the warn threshold and any days-remaining estimate materially. The plan's directional conclusion survives (pinning is worth 4.4x, scratch cwd another 1.9x, and cwd must still be set explicitly because PythonBridge.swift cds into the repo root), but every number in 5.2 and 5.6 must be replaced with the measured ones.

- THE PHASE 0.1 FIXTURE IS NOT WHAT THE MODEL SAW. The images embedded in BLUDLINE's baked PDF are FlateDecode, 8 bits per component, lossless. The shipped OCR path feeds a `sips -s format jpeg` re-encode of the HEIC. Rasterising page 1 out of the PDF therefore produces a losslessly-preserved 3024x4032 image that is strictly higher fidelity than the JPEG the model actually received, and a character-level `Safa` vs `5afa` assertion is exactly the kind of test that can flip on JPEG artefacts. The failing test may not reproduce, or may later pass for a reason unrelated to resolution. The fixture pipeline must reproduce the shipped one end to end: extract the page losslessly, then run the real `sips -s format jpeg` on it, and only then hand it to `_image_block`. Verify the extracted-plus-sips fixture reproduces `5afa` three times before building anything on it.

### Corrected since the run
The third item above (the #200 fixture) has since been settled by controls, recorded on #200: JPEG compression is ruled out (PNG lossless at 1568 also yields `5afa`), and a native-resolution tile through the SAME model and SAME SDK path reads `Safa` correctly. Resolution is the cause and tiling is the fix, both demonstrated rather than assumed. The threshold sits between 0.25 and 0.45 of native and should be measured, not fixed at a constant.

The FIRST item is the serious one and is unresolved: the stop-and-ask behaviour Dan specified cannot fire as designed, because `generate_week.py` has four broad `except Exception` handlers above the eight the plan accounted for. Any implementation must fix that first or the cap safety is decorative.

## Criteria (set before any option existed)

Correctness and robustness 30% (this app's recurring failure mode is silently producing plausible-but-wrong output; a transport that degrades quality or fabricates is disqualifying). Recurring cost 25% (the entire point of the exercise; prefer free, a paid path must earn its bill). Risk and reversibility 20% (Dan explicitly requires an instant switch back). Maintainability 15% (one transport abstraction, not two divergent code paths that drift). Latency and user impact 10% (15-20 min acceptable, faster preferred). Build time/effort is deliberately EXCLUDED as a criterion.

## Rival options and scores

### Fix #200 with data already on disk, meter the bill, defer the migration (`free-fix-and-meter`)

Treat the two halves as the unrelated problems #200 itself says they are, and refuse to build the transport swap until anyone can name the number it saves. Fix the OCR defect using work the app already does and throws away: ProgramPDFBuilder.drawTextLayer (line 268) already runs Apple Vision VNRecognizeText at full native resolution on every program page and bakes the strings invisibly into the PDF, and a panel member extracted that layer from the real BLUDLINE PDF and found 'Safa @safa.wav' verbatim and correct. The exact character Claude gets wrong deterministically, macOS already gets right, on device, free, at upload time. Feed those strings to the OCR prompt alongside the page images as the character-level authority for spelling (Claude still does layout and structure, because the Vision reading order is scrambled across columns), then add the deterministic half: every performer name and handle Claude returns must appear as a substring of the Vision text, and anything that does not is raised into the OCR review loop that already exists (flag_issues.py, review_flag.py, OCRReviewView.swift). Also raise ProgramPDFBuilder.rasterise from scale 2 (144 DPI, confirmed 1224x1584 on the real files) to scale 4, since that raster, not MAX_IMAGE_EDGE, is the actual ceiling. Before writing any of it, run the two controls #200 never ran, because its own control run was confounded: send identical 1176x1568 pixels as lossless PNG versus JPEG q88 (the current path re-encodes at q88 after downscaling), and compare resamplers. If PNG alone fixes 'Safa', the whole issue is a three-line change in _image_block and tiling is unnecessary complexity. Then ship one small release that records tokens and dollars from each SDK response and shows 'this week cost $X' on the Export page. Decide about the subscription in three weeks, with a number.

- No transport work at all. claude_client.py:260-277 (the guard refusing image calls on the CLI path) and _needs_cli are left exactly as they are.

- Root cause gets confirmed in writing on the issue before any code: PNG vs JPEG q88 at identical pixel dimensions, then resampler comparison. Tiling only if resolution is genuinely implicated.

- Vision text is a cross-check, not a replacement. If the text layer is missing, stale, or the async bake from ProgramUploadView has not finished, OCR says so loudly rather than silently reverting to today's behaviour.

- Model output is checked in code (substring against the Vision strings), not asked for in a prompt, and mismatches route into the review flow that already exists rather than a new surface.

- Cost telemetry ships as its own release and runs for three real weeks. The migration is gated on that number, not on an assumption.

- Committed BLUDLINE fixture asserting the exact string 'Safa', per the issue's own test plan.

### Subscription for words, metered API for pixels, permanently (`text-only-subscription`)

Take the saving that is safe to take and refuse the rest. A fixed routing rule by payload type, never surfaced as a per-step choice Dan maintains: any call carrying photographs (OCR, alt text, captions, cover and reel selection, review_flag) stays on the metered API forever, and text-only calls (the three review passes, blog prose, revise_caption) run on the Claude Code CLI against the Max subscription. The reasoning is that vision is where the money is smallest relative to the risk: routing photos through an agentic CLI session converts 'N images are in the request body by construction' into 'an agent decided which files to open', and confident alt text describing photos Claude never saw, published under Dan's byline, is the worst thing this product can produce and is undetectable by him. Text calls have no such failure mode. #200 is fixed exactly as in the free option, independently and on the metered path first, so a passing 'Safa' assertion can never be credited to the transport change. The CLI invocation is pinned hard, because the naive form is measured at 47,000 to 70,000 tokens of Dan's own CLAUDE.md, LESSONS.md, skills and MCP tool definitions per call, which would eat the very allowance this feature exists to protect. And the child environment must actively delete ANTHROPIC_API_KEY, because PythonBridge runs zsh -l and sources ~/.zshrc, so the 'free' path is one profile export away from silently billing while the UI says it did not.

- Routing is a property of the call, not a setting Dan tunes. One Settings picker with both states named ('Max subscription (free, slower)' / 'Paid API (metered, faster)'), default paid, and it never applies to image calls in either position.

- Pinned argv or nothing: --setting-sources "" --strict-mcp-config --tools "" --system-prompt --no-session-persistence --output-format stream-json. Never --bare, whose own help text says OAuth and keychain are never read, so it cannot use the subscription at all.

- The child env explicitly deletes ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN and ANTHROPIC_BASE_URL, asserts apiKeySource from the stream-json init message, and asserts total_cost_usd is zero as the receipt. A non-zero receipt means that run billed and Dan is told.

- Success is classified from is_error and api_error_status, never the exit code (the CLI returns 0 on a 401) and never subtype (which reads 'success' on that same 401). The existing _run_cli checks only returncode and would hand an API error back as model prose.

- A distinct quota error that no existing catch swallows. run_review_pass currently catches ClaudeError and quietly returns the prior draft at seven call sites, so a cap hit today reports as a successful run.

- The existing images-guard survives literally, because images never take this path. No read-receipt machinery needed.

- _needs_cli is deleted. Transport comes from one explicit setting, never inferred from whether an API key happens to be present, which is the inference that caused #85.

### One transport seam, every call eligible, built to be flipped (`dual-transport-foundation`)

Build the thing properly once. Restructure postroll/ai/claude_client.py into ClaudeRequest and ClaudeResponse dataclasses, an SdkTransport and a CliTransport that are the only two modules allowed to import anthropic or subprocess, and one resolver, with all eleven call-site signatures byte-identical so nothing downstream changes. The move that makes vision calls safe here is that images do not go through the Read tool at all: the CLI accepts the exact Anthropic base64 content-block JSON via --input-format stream-json, so _image_block is shared verbatim by both transports, the bytes are in the request by construction exactly as on the SDK, and there is no agentic file access and no fabrication path. That also means the CLI buys zero extra pixels, so #200 must be fixed on its own merits first, on the metered path, exactly as in the free option. Then three things that do not exist today have to be built before the cap behaviour Dan asked for is honest rather than decorative: generate_week writes its results once at the end (line 293), so a cap at minute 14 destroys every day already generated and already paid for; a cap arriving as a non-zero exit renders under the header 'Generation Failed', which is a lie about a mostly successful run; and AssetGenerationView advances its phase list purely on elapsed seconds against a table, so at 20 minutes it shows every phase complete while the run continues, which is indistinguishable from a hang. Per-day atomic checkpointing, a halted-not-failed screen with resume, and progress driven by real pipeline events (generate_week already prints per-day lines that Swift throws away) are all prerequisites, not polish.

- Transport is a resolver reading one mode plus a per-call declaration (either / cli_required for enrich_program's web tools / prefer_metered for the image-heavy OCR path). Call sites declare, they never choose.

- Images travel as base64 content blocks over stream-json input, not the Read tool. The old guard's intent survives as a positive assertion in the transport: N image blocks for N image_paths, checked on every call.

- stream-json is the only output format carrying rate_limit_event, which is where resetsAt, rateLimitType and overageStatus come from. Nothing else can support the 'stop and ask' decision.

- Land the refactor with mode pinned to paid and the full suite green before any subscription behaviour ships, so every later step has a proven seam to test against.

- Per-day atomic checkpointing plus resume, or 'wait for reset' is a start-over button that re-runs and re-bills work that already succeeded. TimingStore keyed by transport, or the ETA is wrong in both directions for several runs after every flip.

- MAX_IMAGE_EDGE becomes a property of the resolved model rather than a module constant, since two transports can otherwise land on models with different vision caps and silently disagree.

- One process per call, no shared session. A persistent stream-json process would be faster and would bleed context between unrelated call sites, which is a failure this codebase has already recorded.

- tests/test_paid_default_path.py gets rewritten to pin the new invariant, never deleted. It exists because the PRD claimed the AI was free while the app billed on every call.

## Selection

Verified the decisive claims in each case against the real repo rather than trusting the champions. Weighted scores: dual-transport-foundation 8.55, free-fix-and-meter 7.45, text-only-subscription 6.73.

WHY dual-transport-foundation WINS. All three options are $0 in new services, so "prefer free" does not discriminate against it, it is the only one that actually eliminates the metered bill the exercise exists to kill, which makes cost-first reasoning favour it rather than penalise it.

Every load-bearing claim I could check held. Images travel to the CLI as base64 content blocks over --input-format stream-json (demonstrated live by its champion), so there is no Read tool, no agentic file access, and no fabrication path, and _image_block is genuinely shareable verbatim. Its replacement for the images guard (assert N image blocks for N image_paths on every call) is strictly stronger than today's refusal at claude_client.py:264-277, because it catches a silently dropped block, which the current refusal structurally cannot. The hard constraint about never producing output from no photos is therefore strengthened, not weakened.

Two verifications settled it. First, enrich_program.py:255-260 passes allowed_dirs=[tmp_path], allowed_tools=["Read","WebSearch","WebFetch"] with staged program images and no image_paths=, and I confirmed _run_sdk has no tools= parameter at all, so WebSearch has never worked over the SDK. This call site falsifies text-only-subscription's entire organising rule while dual-transport is the only option that names it (cli_required). Second, _MODEL_ALIASES maps "sonnet" to claude-sonnet-4-6 (1568px cap) while the CLI resolves the same alias to a newer, higher-cap model, and ocr_program.py passes no model= at all. Making MAX_IMAGE_EDGE a property of the resolved model is the only thing in the panel that catches this: fixing #200 the obvious way ships a guaranteed no-op with a green test. That is exactly this app's named recurring failure mode (plausible-but-wrong output) reproduced in the fix for it, and only this option's architecture makes it unavailable.

The three "prerequisites" are verified defects, not scope creep. generate_week.py writes once at line 293 after the loop, so a cap at minute 14 destroys days already generated and already paid for (L5, L47) while the per-day "done" lines it already prints at 256 are thrown away. AssetGenerationView.swift:137 drives progress off a stopwatch against a static table, which at 20 minutes is indistinguishable from a hang and directly violates the standing rule that working / still-alive / failed be visibly distinct. Line 306 renders "Generation Failed" over a mostly-successful run (L10, L11). Without these, Dan's locked cap decisions are decorative.

SURVIVES ITS RED-TEAM, with a mandatory amendment. The red-team's hit is real and confirmed by measurement: claude -p loads hooks, CLAUDE.md, RTK.md and LESSONS.md by default (69,418 tokens naive vs 12,044 stripped; the rival case measured a fully pinned form at 665). But this is a missing flag set with a known-correct answer, not a broken premise, and the red-team's own proposed remedy is wrong: --bare's help text says OAuth and keychain are never read, so it cannot reach the subscription at all. Both other cases caught that. The amendment is non-optional: pin the argv, and add a test that deliberately pollutes CLAUDE.md and hooks to prove strict-JSON output survives behavioural injection.

WHY NOT free-fix-and-meter (strong second). Its Vision text-layer cross-check is the single best idea in the panel and must be grafted. But its red-team lands two confirmed hits: the raster scale 2 to 4 change is inert because _image_block clamps at 1568 unconditionally, and PNG is already preserved in the shipped path, so its gating diagnostic partly re-tests a settled variable. It also misses the model/cap divergence entirely, so after its work the pixel path is unchanged and Safa may still misread. The cross-check would then flag rather than fix, converting an OCR defect into recurring manual review. Deferring the transport decision three weeks is defensible discipline, but it declines to deliver half of what was asked and saves nothing now.

WHY NOT text-only-subscription. Its empirical findings are the most valuable factual contributions here and several are decisive, but its defining rule is falsified by a call site that exists today. Under "images vs text", enrich_program classifies as text-only and routes to a CLI pinned with --tools "", where it can neither Read the staged images nor WebSearch, and the plan's own stated nightmare (confident fabrication of cast, director, playwright and venue for a real production) lands on the path it declared safe. It deletes _needs_cli citing #85, but #85 was only about key-presence inference; the tool-need inference is load-bearing and gets no replacement. It breaks in both switch positions, so "instant switch back" does not restore correctness, and it permanently institutionalises two paths split by an implicit payload property, which is precisely the drift the maintainability criterion warns against.

MANDATORY CONDITIONS ON THE WINNER: (1) fix #200 first, on the metered path, with a failing Safa test, so a pass can never be miscredited to the transport change; (2) treat #200 as three coupled changes (raster scale, edge cap, and a vision-capable model), never the pixel change alone; (3) land the refactor pinned to paid with all 530 tests green before any subscription behaviour ships.

## The plan

## What this plan does

Two things, in a fixed order:

1. **Fix PostRoll#200 first, on the metered API**, so a passing `Safa` assertion can never be credited to a transport change and the OCR fix survives a transport revert.
2. **Then restructure `postroll/ai/claude_client.py` into one transport seam** (`ClaudeRequest`/`ClaudeResponse`, `SdkTransport`, `CliTransport`, one resolver), land it pinned to the paid path with all tests green, build the three things Dan's cap decisions actually require, and only then ship the subscription transport behind a setting that flips back in one line.

Everything below is grounded in files read this session. Line numbers are from the current working tree.

---

## Facts this plan is built on (verified, not assumed)

| Claim | Evidence |
|---|---|
| `_image_block` clamps every image to 1568px unconditionally | `postroll/ai/claude_client.py:78` (`MAX_IMAGE_EDGE = 1568`), applied at `:97-98` |
| **#200 is event `070DDA6B-F6CA-452E-BD3F-4159A3914467` ("BLUDLINE: A Hip-Hop Odyssey")** | `~/Library/Application Support/PostRoll/events.json` |
| **Its baked PDF is 2 pages, `/MediaBox [0 0 3024 4032]`** | `~/Library/Application Support/PostRoll/programs/070DDA6B-…_program.pdf`, 30 MB, embedded images 3024x4032 |
| **Its source pages were iPhone HEIC files, and `sips` does not resize them** | `postroll/ai/ocr_program.py:274-302` runs `["sips", "-s", "format", "jpeg", src, "--out", dest]` with no resize flag |
| **So the shipped path applies a ~2.57x LANCZOS downscale (4032 to 1568) to each program page** | Not a near-identity resample. The issue text's 1600x2133 to 1176x1568 is the same 0.735-per-axis reduction seen from a different intermediate |
| The 1224x1584 pages in `programs/` are a **different event** (`03.29.2026 Program Notes…`) | `sips -g pixelWidth -g pixelHeight` reports 1224x1584. Not #200's inputs |
| Some real program pages are **already under the cap** and are never resized | `05-24 DCINY Sing Democracy 250 (DGH) Confirm_p10.png` measures **774x1224**, produced at `scale: 2` from a **387x612pt** page |
| `ProgramPDFBuilder.rasterise` defaults to `scale: 2`, and multiplies the page's **PDF point size** | `PostRollApp/Sources/Services/ProgramPDFBuilder.swift:170`, `size = CGSize(width: bounds.width * scale, height: bounds.height * scale)` at `:184` |
| The repo's model aliases are all **1568px-cap models**, and the haiku alias is **dated** | `claude_client.py:37-40` gives `claude-sonnet-4-6`, `claude-opus-4-6`, **`claude-haiku-4-5-20251001`**. Per the `claude-api` skill, high-resolution vision (**2576px** long edge) starts at Opus 4.7 / Opus 4.8 / Opus 5 / Sonnet 5 / Fable 5 / Mythos 5 |
| OCR passes **no `model=`**, so it takes the `"sonnet"` default | `ocr_program.py:354, 390, 441, 459` |
| **Therefore raising `MAX_IMAGE_EDGE` alone is a guaranteed no-op** | The server downscales `claude-sonnet-4-6` to 1568 regardless. The fix is three coupled changes, not one |
| `_image_block` **swallows every downscale failure** and uploads the original bytes | `claude_client.py:109-112` is a bare `except Exception` that prints a warning to stderr and continues |
| `max_tokens=16384` is hardcoded, and the truncation guard fires on `stop_reason == "max_tokens"` | `claude_client.py:167` and `:173` |
| `_run_sdk` reads `message.content[0].text` **unconditionally** | `claude_client.py:182`. No `stop_reason == "refusal"` handling anywhere in the module |
| **Sonnet 5 uses a new tokenizer producing roughly 30% more tokens for the same text**, and `max_tokens` caps thinking plus response text together | `claude-api` skill. A model swap is therefore an output-budget change, not only a thinking change |
| Vision already reads these pages at full resolution, on device, for free, and the answer is thrown away | `ProgramPDFBuilder.swift:268` `drawTextLayer` runs `VNRecognizeTextRequest`; called only from `renderImagePage` (`:260`) |
| **`makePDF` has two page paths with different text authority** | `ProgramPDFBuilder.swift:96-101`: when `pdf.hasText(onPage:)` it calls `embedPDFPage` (publisher's own text layer); otherwise `renderImagePage` then `drawTextLayer` (Vision OCR). BLUDLINE is HEIC-sourced, so every page is the Vision path |
| **All three baked PDFs on this machine came from image sources** (two HEIC, one Screenshot PNG) | `~/Library/Application Support/PostRoll/programs/`. No page on this machine is known to carry an embedded publisher text layer |
| The baked PDF is **never passed to Python** | `PythonBridge.swift:1443-1450`, `runOCR` sends only `--image` and `--output` |
| **`fingerprint(of:)` is filenames only, and two events collide on it** | `ProgramPDFBuilder.swift:61-63` returns `pages.map(\.lastPathComponent).joined(separator: "|")`. Both `070DDA6B` (BLUDLINE) and `7770D947` ("The One-Man Odyssey") carry `IMG_3787.HEIC\|IMG_3788.HEIC`, over different 30 MB files |
| **Every one of the 19 events in `events.json` has `programImagePaths == []`** | ArchiveCleanup has reclaimed all page scans. `fingerprint(of: [])` returns `""`, so `AssetGenerationView.swift:694`'s `fresh` is false for **every event on the machine**, and `ProgramScanRetention.swift:50` is never reached because `:47` short-circuits on empty pages |
| `generate_week` writes results **once, after the loop** | `postroll/ai/generate_week.py:293`. A cap at minute 14 destroys every day already generated and already paid for |
| It already prints per-day progress that Swift throws away | `generate_week.py:256` (`[generate_week] {day}: done`), `:281` for the blog |
| **`ProcessRunner` captures no stdout at all** | `ProcessRunner.swift:44-45` sets only `process.standardError = stderrPipe`. stdout is inherited by the app |
| **Its stderr is drained with `readDataToEndOfFile()` inside `terminationHandler`, and only on non-zero exit** | `ProcessRunner.swift:73` |
| **Any non-zero exit becomes `PythonBridgeError.scriptFailed(exitCode:stderr:)`**, and the child is `zsh -l -c <script>` | `ProcessRunner.swift:76-77`, `PythonBridge.swift:1747-1749`. A failure **before** `exec` returns the **shell's** status, not Python's |
| **The script `cd`s into the repo root before exec** | `PythonBridge.swift:1737`, `cd '\(root.path)'` |
| **The script sources `~/.zshrc` before exec** | `PythonBridge.swift:1733`. Anything the profile prints to stdout lands ahead of Python's own stdout |
| The progress UI is a **stopwatch against a static table** | `AssetGenerationView.swift:137`, `if elapsedSeconds >= phase.startsAt { active = i }` |
| A non-zero exit renders under **"Generation Failed"** | `AssetGenerationView.swift:306` |
| **`AssetGenerationDisplay.RunStatus` has exactly `.running` and `.failed`** | `AssetGenerationDisplay.swift:21-23`, mapped at `:34-35` |
| The Python child inherits the metered key **unconditionally** | `PythonBridge.swift:1729` calls `apiKeyDelivery(KeychainStore.readAPIKey())`, whose script lines export `ANTHROPIC_API_KEY` into every run |
| `_run_cli` classifies success **from the exit code only** | `claude_client.py:226-232`. The CLI returns exit 0 with `subtype: "success"` on a 401 |
| **Eight sites swallow `ClaudeError`** | `grep -rn 'except ClaudeError' postroll/`: `claude_client.py:343` (the single `run_review_pass` catch all seven review-pass callers funnel through), `ocr_program.py:492, :509, :531`, `generate_blog.py:1493, :1525`, `select_cover_photo.py:173`, `learn_from_edits.py:158` |
| The CLI path **refuses images today**, loudly, on two branches | `claude_client.py:260` (`if _needs_cli`), `:264` (`if image_paths:`) |
| `enrich_program` genuinely needs the CLI | `enrich_program.py:255-260` passes `allowed_tools=["Read","WebSearch","WebFetch"]`; `_run_sdk` has **no `tools=` parameter at all** (`claude_client.py:133-185`), so those tools have never worked over the SDK |
| **15 modules import `claude_client`; 29 call sites across them** | `grep -rln 'from .claude_client import' postroll/` |
| `claude` CLI **2.1.226** is installed | `claude --version` |
| **`--setting-sources` is about settings files, not memory files** | `claude --help`: "Comma-separated list of setting sources to load (user, project, local)." The **only** flag whose help mentions "CLAUDE.md auto-discovery" is `--bare` |
| **`--bare` cannot reach the subscription** | Its help text: "Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper via --settings (OAuth and keychain are never read)" |
| **PostRoll has no repo-root `CLAUDE.md` at all** | `ls /Users/danielhankins-wright/Documents/PostRoll/CLAUDE.md` returns "No such file or directory" |
| **The residual per-call context is the project auto-memory, selected by cwd** | `~/.claude/projects/-Users-danielhankins-wright-Documents-PostRoll/memory/` holds 119 files including a 20 KB `MEMORY.md`. `--setting-sources ""` does not suppress it |
| **Measured per-call input cost, three ways** | Pinned invocation from the PostRoll repo root: **5,845 tokens** (3 input + 5,842 cache_read). Same pinned invocation from a directory with no project memory: **130 tokens**. Unpinned from the repo: **38,252 tokens** (3 + 38,249 cache_creation). A **45x swing**, entirely decided by cwd |
| **A real subscription run reported `total_cost_usd: 0.00045` with `apiKeySource: "none"`** | Measured live. Zero is not the receipt; `apiKeySource` is |
| **Dan's account reports `overageStatus: "rejected"`, `overageDisabledReason: "out_of_credits"`** | Measured live. There is **no overage cushion** behind the five-hour window |
| **The CLI reports `contextWindow: 200000` for `claude-sonnet-4-6`**, not the 1M the API documents | Measured live |
| **There is no pytest config in the repo** | No `pytest.ini`, `pyproject.toml`, `setup.cfg`, or `tox.ini`. `tests/conftest.py` registers no markers and no collection hook |
| **CI runs Python with no marker filter** | `.github/workflows/tests.yml`: `PYTHONPATH=. pytest tests/ -v` on `ubuntu-latest`, Python 3.11 |
| **CI's Swift job NEVER runs on pull requests** | `.github/workflows/tests.yml` gates it `if: github.event_name != 'pull_request'`, with a comment saying private-repo macOS minutes bill at 10x and "Pull requests skip it deliberately." The 436 Swift tests run only on push to `main` and `workflow_dispatch`, i.e. **after merge** |
| **`requirements.txt` holds only two lines** | `Pillow>=11.0`, `anthropic>=0.40.0`. CI installs from it |
| **CI's Swift job pins the runner, not the toolchain** | `runs-on: macos-15`, `brew install xcodegen`, no Xcode version selection. It uses the macos-15 image default, which differs from local Xcode 26.6 on actor isolation |
| Baseline suite | **530 Python tests collected**, `venv/bin/python -m pytest tests` |

---

## A CI fact that changes every gate in this plan

**The Swift half of "all tests green" is not enforceable before merge.** `.github/workflows/tests.yml` skips the `swift` job on pull requests by design, to avoid the 10x macOS minute multiplier on a private repo. So every gate below that says "tests green" means, precisely:

- **Python:** enforced by CI on the PR. Automatic.
- **Swift:** **not** run by CI on the PR. The gate is satisfied by a **local run recorded in the PR body**:

```
xcodebuild -project PostRollApp/PostRoll.xcodeproj -scheme PostRollTests -destination 'platform=macOS' test
```

and by the post-merge `main` run going green. If the post-merge Swift run goes red, that is a revert, not a follow-up.

This plan does **not** silently assume a PR-triggered Swift job exists. Adding one is a real option with a real cost and is escalated to Dan (decision 1). Until he chooses, the local-run-in-PR-body rule is the gate, and Phase 6's "run the whole suite with mode forced to CLI in CI" inherits the same split: the Python half runs in CI, the Swift half runs locally and then post-merge on `main`.

---

## Phase 0: Measure before building (no shipping-code changes)

Everything in Phase 1 is a hypothesis until this runs. Scripts live in the scratchpad, not the repo.

**0.1 Build the fixture from the real #200 inputs, pinned by content hash.** BLUDLINE's page scans are gone (`programImagePaths == []`, as they are for all 19 events); the surviving artifact is:

`~/Library/Application Support/PostRoll/programs/070DDA6B-F6CA-452E-BD3F-4159A3914467_program.pdf`, 2 pages, 3024x4032, HEIC-sourced, so its text layer is Vision output, not publisher text.

**Select it by SHA-256 of the PDF bytes, never by event name and never by page filenames.** BLUDLINE (`070DDA6B`) and "The One-Man Odyssey" (`7770D947`) both carry the fingerprint string `IMG_3787.HEIC|IMG_3788.HEIC` over different 30 MB files, so any fixture selection keyed on that string can silently pick up the wrong event's program and the whole `Safa` assertion would then be measuring the wrong document. Record the hash in the test file as a literal and assert it before the fixture is used.

Rasterise page 1 from that PDF at the resolution the shipped path actually produced (3024x4032, matching the untouched `sips` JPEG), and use that as the fixture image.

**Default: do not commit it.** The pages carry real performers' names and Instagram handles, and committing them puts them in git history permanently. Use a gitignored local fixture directory (`tests/fixtures/local/programs/bludline/`, added to `.gitignore`) plus a `pytest.skip(...)` guard when the file is absent. That gives the same failing test locally without publishing anyone's PII. Committing a redacted crop is the fallback, and either way it is escalated decision 6.

**0.2 Write the failing test behind a real gate.** `tests/test_program_ocr_resolution.py`, marked `@pytest.mark.live`.

A bare marker does **not** keep this out of CI: there is no pytest config, `conftest.py` registers nothing, and CI runs `PYTHONPATH=. pytest tests/ -v` with no `-m` filter, so the test would be collected and executed on ubuntu and fail on the missing Keychain and API key. That breaks the "existing tests must keep passing" constraint. The gate needs four parts, all landed in this step:

1. A new `pytest.ini` at the repo root with `addopts = -m "not live"` and `markers = live: hits the paid Anthropic API; opt in with --run-live`.
2. A `pytest_addoption` hook in `tests/conftest.py` adding `--run-live`, and a `pytest_collection_modifyitems` hook that deselects `live` tests unless the flag is passed.
3. A refusal inside the test body itself: if `ANTHROPIC_API_KEY` is absent from the environment and unreadable from the Keychain, `pytest.fail` with a clear message rather than silently passing (L2, the test must be structurally unable to bill, and must never look green when it did not run).
4. A test of the gate: assert that a default collection run does not select the `live` test.

The assertion:

```
assert "Safa" in names and "5afa" not in names
```

Run it three times against the current path. It must fail deterministically, exactly as #200 reports. **A test that has not been seen to fail is not a test** (L1).

**0.3 Four controls, one variable each, on the same real page.** Each is a direct `messages.create` from a scratchpad script:

| Control | Question it answers |
|---|---|
| A. 3024x4032 page, shipped path (downscaled to 1176x1568), `claude-sonnet-4-6` | Baseline: reproduce `5afa` through the real ~2.57x LANCZOS reduction |
| B. 3024x4032 page, cap raised to 2576 but still `claude-sonnet-4-6` | Confirms the "more pixels alone is inert" prediction, since the server re-downscales to 1568. If this passes, the diagnosis is wrong and the plan changes |
| C. 3024x4032 page, cap raised to 2576, **`claude-sonnet-5`** | The real hypothesis: more pixels reaching a model that can use them |
| D. Same as C on **`claude-opus-5`** | Is the cheaper Sonnet-tier model enough? |

Note what A does *not* test: whether the resampler is at fault independent of resolution. Because the reduction here is 2.57x, not 1%, resolution and resampling cannot be separated on this input, and there is no point pretending otherwise. If you want the resampler isolated, add a control A2 that reduces 3024x4032 to 1176x1568 with `Image.BICUBIC` instead of `LANCZOS` and compare.

**0.4 Measure input AND output cost, and re-baseline `max_tokens`.** Record `usage.input_tokens` **and `usage.output_tokens`** per control.

Input side: a 2576px page costs up to roughly 4784 image tokens against roughly 1568 today, about 3x. A 16-page program run makes 4+ Claude calls over all pages (`extract_program` plus the `_extract_*_only` fallbacks at `ocr_program.py:441, :459`), so this is the number that decides escalated decision 2.

**Output side is not optional, and the plan previously missed it.** Per the `claude-api` skill, Sonnet 5 uses a new tokenizer producing roughly **30% more tokens for the same text** than Sonnet 4.6, and `max_tokens` caps **thinking plus response text together**. `claude_client.py:167` hardcodes `max_tokens=16384` and `:173` raises on `stop_reason == "max_tokens"`. So a 16-page program whose OCR JSON comfortably fits inside 16384 on `claude-sonnet-4-6` can trip that truncation guard on `claude-sonnet-5` **for tokenizer reasons alone**, with thinking disabled and nothing else changed. Record, for each of C and D:

- `output_tokens` on the largest real program available, not the single fixture page.
- Whether `stop_reason` was `max_tokens`.
- The headroom ratio against 16384.

Phase 1.4 sets the new `max_tokens` from these measurements, per model, and it must be a **measured** number with the largest observed output plus margin, not a guessed one.

**0.5 Extract the Vision text.** With `pypdf` in the scratchpad venv, dump the baked PDF's text layer per page. Confirm `Safa @safa.wav` is present verbatim and note where Vision mangles stylised blocks (the champion saw "Sottlieb, Jake", "aunno", letter-spaced headline garbage). That split, reliable on clean body text and unreliable on posters and reading order, is what makes the cross-check a *flag*, not a rewrite.

**Gate:** write the four control results, input **and** output token counts, into the issue before any shipping code changes. If B passes, stop and re-plan.

---

## Phase 1: Fix #200 on the metered path

TDD throughout. `venv/bin/python -m pytest` (never `venv/bin/pytest`, see project memory).

**1.1 Make the edge cap a property of the resolved model.** This is the one decision that makes the wrong fix structurally unavailable.

In `claude_client.py`, replace the module constant with a lookup keyed on the **resolved** model id (`_resolve_model()`'s output at `:49`, not the alias, since `_MODEL_ALIASES["haiku"]` at `:40` is the dated `claude-haiku-4-5-20251001`, so an alias-keyed table would miss on day one):

```python
_MODEL_VISION_EDGE = {                    # long-edge px the model actually uses
    "claude-sonnet-4-6":          1568,
    "claude-opus-4-6":            1568,
    "claude-haiku-4-5-20251001":  1568,   # dated: what _resolve_model returns today
    "claude-haiku-4-5":           1568,   # undated alias, in case a call site writes it
    "claude-sonnet-5":            2576,
    "claude-opus-5":              2576,
    "claude-fable-5":             2576,
    "claude-mythos-5":            2576,
    "claude-opus-4-8":            2576,
    "claude-opus-4-7":            2576,
}
DEFAULT_IMAGE_EDGE = 1568                 # unknown model -> conservative
def image_edge_for(model: str) -> int: ...
```

The table carries **more than the repo's own three aliases on purpose**. The unknown-model default of 1568 keeps a hand-written model string safe (it under-uses pixels rather than over-sending them), but "safe" here means silently reverting to the #200 defect, so the table should already know every model the repo could plausibly be pointed at.

`_image_block(path, *, max_edge)` takes the cap as an argument. Both transports share it verbatim. Keep `MAX_IMAGE_EDGE` as a deprecated alias only if something outside `claude_client` imports it (grep says only the test does; update the test).

Tests:
- a known 1568 model clamps to 1568;
- a known 2576 model clamps to 2576;
- an unknown model string falls back to 1568;
- a table-vs-alias consistency test asserting every **resolved** value of `_MODEL_ALIASES` has an entry in `_MODEL_VISION_EDGE`, so adding an alias without a cap fails the suite rather than silently defaulting;
- **and a call-site scan test**, because the alias-consistency test as written only checks the repo's own three aliases and would not catch a hand-written `model="claude-sonnet-5"` at a call site. Grep every `model=` literal passed into `run_prompt`/`run_json_prompt`/`run_review_pass` across `postroll/` and assert each one is either an alias key or a `_MODEL_VISION_EDGE` key.

**1.2 Make the downscale loud when it fails.** `_image_block` currently catches every exception during resize (`claude_client.py:109-112`), prints a warning to stderr, and uploads the original bytes. That is exactly the condition #200 is about: a page that bypassed the resize looks identical to a page that was resized correctly, from the caller's side.

Change `_image_block` to record whether the resize was attempted and whether it raised, and surface that on the returned block (an out-of-band sidecar dict, not inside the API payload). Phase 3.3's assertion consumes it.

There is **no near-identity skip** in this plan. An earlier draft proposed skipping the resample when `max(size) / max_edge <= 1.02`; that was derived from the wrong event's 1584px pages and would do nothing for #200, whose pages are 4032px. If a future measurement shows the resampler itself degrades near-identity inputs, that is a separate issue against the DCINY-class pages, not part of the #200 fix.

**1.3 Raise the raster to a TARGET, not a hardcoded multiplier.** The previous draft said "default `scale: 2` to `4`". That is wrong: `rasterise` multiplies the page's **PDF point size** (`ProgramPDFBuilder.swift:184`), so a fixed scale is an unbounded multiplier whose effect depends entirely on the source document:

| Source page (points) | Today at `scale: 2` | At a fixed `scale: 4` |
|---|---|---|
| 387x612 (the real DCINY page) | 774x1224 | 1548x2448 |
| 612x792 (US Letter) | 1224x1584 | 2448x3168 |
| 3024x4032 (a BLUDLINE-class MediaBox) | 6048x8064 | **12096x16128** |

The third row is a real disk and memory blowup (the baked PDFs already run 30 MB for two pages) and it massively **overshoots** the 2576px cap the change exists to serve. Every pixel above 2576 on the long edge is thrown away by the server anyway.

So: **compute the scale per page** so the long edge lands at the target, clamped both ways.

```
scale = clamp(targetLongEdge / max(bounds.width, bounds.height), min: 1, max: 6)
```

with `targetLongEdge` defaulting to the vision cap of the model OCR will use (2576 after 1.4), passed in rather than hardcoded, so the raster and the upload cap can never drift apart. The `min: 1` floor keeps a page that is already huge in points from being *down*-rastered; the `max: 6` ceiling keeps a tiny page (a business-card-sized PDF) from exploding.

Add a Swift test in `PostRollApp/Tests` asserting, for **three** synthetic page sizes covering all three rows above, that the produced PNG's long edge is within one pixel of `targetLongEdge` (or at the clamp when clamped), and that the short edge preserves aspect ratio. A single-page-size test would pass for every one of the broken variants.

Note the knock-on: `drawTextLayer`'s Vision pass gets a better raster too, which is a second, independent win.

This only affects the **PDF-upload** path. BLUDLINE came in as HEIC photos, which never touch `rasterise`; for those, `sips` already hands over the full 3024x4032 frame. So 1.3 helps future PDF-sourced programs and does nothing for #200 itself. Do not let a green raster test be read as evidence #200 is fixed.

**1.4 Give OCR a vision-capable model, and make the response reader survive it.** `ocr_program.py`'s four call sites pass an explicit `model=` from one module constant (`OCR_MODEL`), not the `"sonnet"` default.

**This is not a string swap.** Four things in `_run_sdk` break on a 2576px-class model:

- **`message.content[0].text` is read unconditionally at `claude_client.py:182`.** On Opus 5 and Sonnet 5 adaptive thinking is on by default, so `content[0]` is a `thinking` block, not a text block. That is an `AttributeError` or a silently empty string, not the clear truncation error the module intends. Replace with a scan for the first block whose `type == "text"`, and raise a specific `ClaudeError` when no text block exists at all.
- **`stop_reason == "refusal"` is not handled anywhere.** Opus 5 and Sonnet 5 return HTTP 200 with `stop_reason: "refusal"`, an optional `stop_details.category`, and a possibly empty `content` array. Check `stop_reason` **before** touching `content`, and raise a distinct, named error naming the category.
- **`max_tokens=16384` at `claude_client.py:167` caps thinking plus response text together.** With thinking on by default, a naive swap silently spends the budget on thinking and can trip the existing truncation guard at `:173`.
- **The tokenizer changed.** Even with thinking fully disabled, Sonnet 5 emits roughly 30% more tokens for the same OCR JSON. `max_tokens` must be re-baselined from Phase 0.4's measured `output_tokens` on the largest real program, per model, and made a per-model value rather than one module constant. Ship it as `_MODEL_MAX_TOKENS` keyed on the resolved id, same shape and same consistency test as `_MODEL_VISION_EDGE`.

So `_run_sdk` gains an explicit `thinking` parameter defaulted per model family and an explicit `max_tokens` resolved per model, and OCR sets both deliberately (`{"type": "disabled"}` at effort `high` or below, or adaptive with a raised cap; decide from Phase 0 controls C and D). Per the `claude-api` skill, `{"type": "disabled"}` is rejected on Opus 5 above effort `high`, so if OCR disables thinking it must also pin effort to `high` or lower.

Tests, all offline with a faked SDK response object:
- a response whose `content[0]` is a thinking block still yields the text block's text;
- a response with `stop_reason == "refusal"` and empty content raises a named error mentioning the category;
- a response with no text block at all raises rather than returning `""`;
- a truncation still raises the existing clear error;
- the request built for a 2576-class model carries an explicit `thinking` value **and** the per-model `max_tokens`, not 16384;
- a model with no `_MODEL_MAX_TOKENS` entry fails the consistency test.

**1.5 Re-run the failing test.** Three runs, all green, `Safa` present, `5afa` absent. Plus the two tests #200 asks for: a sparse single-page program is not made worse, and no duplicate performers appear.

**Deliverable:** #200 closed on the metered path, with the measured before/after (including output-token headroom) in the issue. **Do not proceed to Phase 3 until this is merged and green.**

---

## Phase 2: Vision text-layer cross-check (independent of transport and of pixels)

This is the strongest graft in the panel and it holds even if Phase 1 underdelivers.

**2.0 Create the missing fixture BEFORE writing 2.2's heuristic.** All three baked PDFs on this machine came from image sources (two HEIC, one Screenshot PNG), so **no page on this machine is known to carry an embedded publisher text layer**. 2.2's provenance heuristic has two branches and only one of them has a real specimen. Shipping it means asserting one side against reality and assuming the other, which is precisely the shape L58 warns about.

So before 2.2 is written, one real program PDF with a genuine publisher text layer must go through the app's own upload path so `makePDF` takes the `embedPDFPage` branch (`ProgramPDFBuilder.swift:100`). This needs Dan, because the upload is a GUI action.

**Steps for Dan (one command per block):**

1. Find a program PDF that came from a publisher (a downloaded playbill or press packet, not a photo of one). If unsure whether it has a text layer, open it in Preview and try to select a line of text with the cursor. If the text highlights, it has one.

2. Open PostRoll:

```
open -a PostRoll
```

3. Create a throwaway event named `TEXTLAYER FIXTURE`, go to its Program step, and upload that PDF.

4. When the bake finishes, run this to confirm the baked PDF exists and report the path back:

```
ls -la ~/Library/Application\ Support/PostRoll/programs/
```

If no such PDF exists on the machine, 2.2 does **not** ship a two-branch heuristic. It ships the Vision branch only, treats every page as Vision-provenance (the weaker, flag-only authority), and files the issue that turns on the embedded branch when a specimen arrives (L65). That is escalated decision 4.

**2.1 Plumb the baked PDF into OCR.** `PythonBridge.runOCR` (`PythonBridge.swift:1443`) gains `--program-pdf <path>`; `ocr_program.main` gains the matching argument; `extract_program(image_paths, *, program_pdf=None)`.

**2.2 Read the text layer in Python, and know which path produced it.** Add `pypdf` to `requirements.txt`, which currently holds only `Pillow>=11.0` and `anthropic>=0.40.0`, and which CI installs from. **The requirements change must land in the same commit as, or before, the first test that imports `program_text_layer`, or the ubuntu job goes red on import.**

New module `postroll/ai/program_text_layer.py`:

- `page_texts(pdf_path) -> list[PageText] | None`, one entry per page. Returns `None`, loudly, when the PDF has no text layer at all.
- **Each `PageText` must carry its provenance**, because `makePDF` produces two structurally different kinds of page (`ProgramPDFBuilder.swift:96-101`):
  - **`embedPDFPage`** (`:100`), taken when `pdf.hasText(onPage:)` is true, so the page carries the **publisher's own text layer**, a far stronger spelling authority than any OCR.
  - **`renderImagePage` then `drawTextLayer`** (`:108`, `:260`, `:268`), so the page carries **Vision OCR output**, with its known reading-order scrambling and stylised-block failures.
  - **BLUDLINE is entirely the second kind** (HEIC-sourced, no source PDF to embed).
- Distinguish them by whether the page's text has the geometric signature of a Vision-drawn layer (invisible render mode and per-glyph positioning from `drawTextLayer`) versus embedded publisher text. The heuristic is asserted against **both** a real embedded-PDF page (from 2.0) and a real Vision-drawn page. If 2.0 produced no embedded specimen, the embedded branch does not ship at all rather than shipping asserted on one side and assumed on the other (L58).

**2.3 Freshness preconditions that actually work.** The obvious rule, `event.programPDFFingerprint == ProgramPDFBuilder.fingerprint(of: event.programImagePaths)` as used at `AssetGenerationView.swift:694` and `ProgramScanRetention.swift:50`, **cannot be reused here**. And the reason is stronger than an edge case:

- **It is currently false for every event on the machine.** All 19 events in `events.json` have `programImagePaths == []` (ArchiveCleanup has reclaimed every page scan), so `fingerprint(of: [])` returns `""` and can never equal a stored fingerprint. `AssetGenerationView.swift:694`'s `fresh` therefore evaluates false for all 19. (`ProgramScanRetention.swift:50` is not even reached, because `:47` short-circuits to `.nothingToDelete` on empty pages.) Reclaimed pages are not the exception, they are the **steady state**, so reusing this check would switch Phase 2 off on 100% of the events it exists for. The content-hash replacement is not an edge-case fix; it is the only thing that would ever be true.
- **It cannot tell two events apart.** `fingerprint(of:)` is filenames only (`ProgramPDFBuilder.swift:61-63`), and `070DDA6B` (BLUDLINE) and `7770D947` ("The One-Man Odyssey") carry the byte-identical string over different 30 MB files, because both events' pages came off an iPhone as `IMG_3787`/`IMG_3788`.

So Phase 2 needs its own freshness key, stored on the event when the PDF is baked (`ProgramPDFBakery.swift:67` already writes the fingerprint there; add the new fields alongside):

- **`programPDFContentHash`**, SHA-256 of the baked PDF's bytes, computed at bake time and re-computed at read time. This is the primary check, and it is immune to both the reclaimed-pages problem and the filename collision.
- **`programPDFBakedAt`** and **`programPDFPageCount`**, recorded at bake time, used to produce a human-readable staleness message and to catch a truncated bake.

Rules, all loud on failure:

- Content hash mismatch, or the PDF is missing: do not pass `--program-pdf`; the OCR screen says explicitly that the cross-check is off and why. It must never silently revert to today's behaviour, which is exactly how a guard becomes indistinguishable from no guard (L65).
- `ProgramPDFBakery.baking` contains this event: same, with a "bake in flight, retry when it finishes" message.
- Reclaimed page scans (`programImagePaths == []`) are **not** a failure condition. The PDF is the artifact; the scans are not needed. This is the normal case for all 19 events.

Because these are new persisted fields on `Event`, they get `decodeIfPresent` in the custom `init(from:)` (`Event.swift:127` is the existing pattern). A missing one wipes saved data on next launch.

**Backfill:** every already-baked PDF has no content hash. On first read, compute and store it, and record `programPDFPageCount` from the file. Do **not** treat a missing hash as staleness, or every existing event loses the cross-check permanently.

**2.4 Feed the text layer to the prompt as spelling authority, weighted by provenance.** Extend `PROMPT_TEMPLATE` with a per-page block. Claude still owns layout, structure, and reading order (Vision's is scrambled across columns). The text layer is authoritative on *character shapes*, and how strongly depends on 2.2's provenance:

- **Embedded publisher text:** strong authority. A mismatch between Claude's reading and the text layer is very likely Claude's error.
- **Vision OCR text:** weaker authority. A mismatch is a *flag for review*, not a correction, and never blocks.

**2.5 Enforce it in code, not in the prompt** (L27, and `feedback_deterministic_enforcement.md`). New `postroll/ai/verify_against_text_layer.py`:

- Every returned performer `name` and every `@handle` must appear as a substring of the concatenated page text, after a shared normalisation (case, curly quotes, whitespace, accents).
- A miss produces a **flag**, never a silent rewrite, routed into the existing OCR review loop (`flag_issues.py`, `review_flag.py`, `OCRReviewView.swift`) with the closest text-layer candidate offered as a one-click correction.
- The flag's severity carries the provenance from 2.2, so a mismatch against publisher text reads differently from a mismatch against Vision output.

Tests, including failure paths (the pre-push judge requires this): missing text layer; content-hash mismatch; bake in flight; reclaimed page scans (must **not** disable the check, and this is the majority case); two events sharing a filename fingerprint (must not cross-contaminate); a name present in Claude's output but absent from the text layer **must flag and must not rewrite**; a stylised-block false positive on a Vision page is flagged rather than auto-applied.

---

## Phase 3: The transport seam, landed pinned to paid

No behaviour change. This is the refactor whose whole purpose is that Phase 5 becomes a one-line mode change.

**3.1 New shape inside `postroll/ai/claude_client.py`:**

- `ClaudeRequest`: prompt, image_paths, image_labels, allowed_dirs, allowed_tools, model, timeout, thinking, max_tokens.
- `ClaudeResponse`: text, input_tokens, output_tokens, model, transport, plus an optional `quota` block.
- `SdkTransport`, the **only** module allowed to `import anthropic`.
- `CliTransport`, the **only** module allowed to `import subprocess` for Claude.
- `resolve_transport(request, mode)`, one function, one place.

Every public call-site signature stays **byte-identical**. `run_prompt`, `run_json_prompt`, and `run_review_pass` keep their exact current parameters and return types, so none of the 29 call sites across the 15 importing modules move.

**3.2 Call sites declare, they never choose.** Each request carries a capability, not a transport: `enrich_program` declares `cli_required` (it needs Read/WebSearch/WebFetch, which the SDK path structurally cannot serve, since `_run_sdk` at `claude_client.py:133-185` has no `tools=` parameter at all); OCR declares `prefer_metered` until Phase 5 says otherwise. Everything else is unmarked. This is what prevents one of 29 sites drifting onto the wrong transport.

**3.3 Replace the images guard with a stronger one.** Today `claude_client.py:260` and `:264` *refuse* images on the CLI path. Replace with a positive assertion, run on **every** call, both transports:

- The built content contains exactly N image blocks for N `image_paths`, and each carries non-empty base64 data.
- **And the Phase 1.2 sidecar reports no swallowed downscale failure.** An N-blocks-for-N-paths count passes fine when `_image_block` caught an exception at `:109` and uploaded the original bytes, which is precisely the condition #200 is about. The assertion must fail loudly when a resize was attempted and raised.

This catches a silently dropped block and a silently bypassed resize, neither of which the current refusal can see. The hard constraint (never produce output from no photos) gets stronger, not weaker.

**3.4 Rewrite, do not delete, `tests/test_paid_default_path.py`.** That file exists because #85 shipped a PRD claiming free while the app billed. Deleting it to make a new mode pass recreates the exact conditions that produced it. Rewrite it to pin the new invariant: transport comes from an explicit setting; the default is paid; the doc assertions at lines 36-44 stay.

**3.5 Cost telemetry, kept but re-scoped.** Record `usage.input_tokens` / `usage.output_tokens` from every SDK response into the existing analytics store and show "this week cost $X" on the Export page.

Record the **subscription-side** figure in the same store, because it is already measured and it is the concrete evidence Phase 5.4 rests on: a live CLI run returned `total_cost_usd: 0.00045` while reporting `apiKeySource: "none"`. A non-zero `total_cost_usd` on a subscription run is normal and means nothing about billing; only `apiKeySource` does. Storing both side by side is what makes a silent regression back to the metered path visible rather than inferred.

This is no longer a gate on the migration; it is how the flip is judged afterwards.

**Gate:** merge with mode pinned to paid, **530+ Python tests green in CI**, and the Swift suite green **locally, with the run pasted into the PR body** (see the CI note above), then green on the post-merge `main` run. No subscription behaviour ships in this phase.

---

## Phase 4: The three prerequisites Dan's cap decisions actually require

These are verified defects in shipped code that the cap requirement merely exposes. Without them the cap behaviour is decorative.

**4.1 Per-day atomic checkpointing, stamped with a per-run id.** `generate_week.py` accumulates into `results` and writes once at `:293`. Change to: after each day (and after the blog), write the accumulated results to `output_path.tmp` and `os.replace` onto `output_path`. Temp-and-rename, never a partial file at the real path (L5).

The checkpoint carries:

- `"run_id"`, a UUID generated **once at process start** and written into the checkpoint **before the first day runs**, so a checkpoint from any earlier run is structurally distinguishable from this run's.
- `"completed"`, so a resume knows what not to re-pay for.
- `"status"`, see 4.2.

**The very first thing the run does, before any Claude call, is write a fresh checkpoint carrying this run's `run_id` and `status: "running"`.** It does not read, trust, or leave in place whatever was on disk. (A resume is an explicit, separate entry point that reads the prior checkpoint deliberately and then stamps a new `run_id` of its own.)

Tests: a simulated crash at day 3 leaves days 1-2 readable and valid on disk; a resume regenerates only days 3+; the write is atomic (no partial JSON observable); **a checkpoint left by a previous run is overwritten at start, so its `run_id` is never observable from a later run.**

**4.2 Halted is not failed, and its carrier must survive a shell-level failure.** `AssetGenerationDisplay.RunStatus` has exactly `.running` and `.failed` today (`AssetGenerationDisplay.swift:21-23`), and `AssetGenerationView.swift:306` renders "Generation Failed" for a non-zero exit, a lie about a mostly-successful run (L10, L11).

Add `.halted(reason:completed:resumeAt:)`. But `.halted` is unreachable unless something carries it across the process boundary, and today the **only** channel is a non-zero exit turning into `PythonBridgeError.scriptFailed(exitCode:stderr:)` (`ProcessRunner.swift:76-77`).

**Carrier: the Phase 4.1 checkpoint file, matched on run id.** On a cap wall, Python writes `"status": "halted"` plus `reason`, `completed`, and `resets_at` into the checkpoint (atomically, as in 4.1, and keeping this run's `run_id`) and then exits **non-zero with a reserved code (3)**. Swift's `ProcessRunner` still throws `scriptFailed`; `PythonBridge` catches it, reads the checkpoint, and promotes the failure to `.halted` **only when all three of these hold**:

1. the exit code is exactly 3, **and**
2. the checkpoint's `"status"` is `"halted"`, **and**
3. the checkpoint's `"run_id"` equals the `run_id` **Swift generated and passed into this invocation** as a CLI argument.

Condition 3 is not belt-and-braces, it is the whole point. The child is `zsh -l -c <script>` (`PythonBridge.swift:1747-1749`), so a failure **before** `exec` (a bad `source ~/.zshrc`, a missing PATH entry, a failed `cd '<root>'` at `:1737`) returns the **shell's** exit status, not Python's, and Python may never have run at all. Without condition 3, a stale `halted` checkpoint sitting on disk from an earlier run plus an unrelated shell failure that happens to exit 3 manufactures a **fake halt**: the app would tell Dan he hit his cap when he did not, and offer to spend money to get past a wall that is not there. That is exactly the self-agreeing check L70 is about, because both surviving signals would be reading state that this run never wrote.

Passing `run_id` in from Swift also means the two sides of the check come from genuinely independent routes: Swift owns the id, Python echoes it, and a file written by anything else cannot match.

The halted screen names what finished, names why it stopped, and offers **Resume** (which reads the checkpoint) and **Wait until \<time\>** when a reset timestamp is known.

Tests: exit code 3 with a matching-`run_id` `halted` checkpoint yields `.halted`; exit code 3 with **no** checkpoint yields `.failed`; exit code 3 with a `halted` checkpoint carrying a **different** `run_id` yields `.failed` (this is the stale-file case, and it must be a real test with a real leftover file, not a mock); exit code 1 with a matching `halted` checkpoint yields `.failed` (never trust the file alone); a pre-`exec` shell failure with a leftover checkpoint yields `.failed`.

**4.3 Progress from real events, not a stopwatch, behind a sentinel, through a pipe that exists.** `generate_week` already prints `[generate_week] {day}: done` at `:256`; Swift discards it. Emit a structured line instead and drive `AssetGenerationView`'s phase list from real events.

**Every progress line carries a fixed sentinel prefix**, because the script sources `~/.zshrc` at `PythonBridge.swift:1733` before `exec`, so anything the profile prints to stdout (a version banner, an nvm notice, a motd) lands in the new pipe **ahead of** Python's structured lines. Tolerating malformed lines is necessary but not sufficient; profile noise must be structurally unable to parse as progress:

```
POSTROLL_PROGRESS {"event":"day_done","day":"tuesday","index":2,"total":5}
```

Swift ignores every line that does not start with `POSTROLL_PROGRESS `, then parses the remainder as JSON, then ignores it again if the JSON is malformed.

Two things must be built for any of this to work at all:

- **`ProcessRunner` has no stdout pipe.** `ProcessRunner.swift:44-45` sets only `process.standardError = stderrPipe`; the child's stdout is inherited by the app. Add `process.standardOutput = stdoutPipe`.
- **The existing drain pattern will deadlock.** `ProcessRunner.swift:73` reads the pipe with `readDataToEndOfFile()` inside `terminationHandler`, i.e. only after the child exits, and only on non-zero exit. A 15-to-20-minute run emitting per-day progress will fill the 64 KB pipe buffer and block the Python child forever; the app would hang, not just miss updates. Replace with a `readabilityHandler`-based incremental reader on both pipes: accumulate into a line buffer, emit complete lines as they arrive, and drain any remainder in `terminationHandler`. Keep the existing stderr-empty `logFallback` behaviour (`PythonBridge.swift:1753-1765`, scoped by `runMarker`) intact.

Tests, in `PostRollTests`: a chatty child that writes far more than 64 KB to stdout before exiting **completes** rather than hanging (this is the test that would have caught the deadlock; run it against a real tiny executable, as `ProcessRunner`'s existing tests already do); structured lines arrive incrementally while the child is still running; **a child that prints unprefixed profile-style noise to stdout before its first real progress line produces zero spurious progress updates**; a malformed line **behind** the sentinel is ignored rather than crashing the parser; stderr capture on a non-zero exit still works unchanged.

Add a stall state using the existing `PipelineProgressState` (`PipelineProgress.swift`) so working / still-alive / failed are visibly distinct, which is a standing rule in CLAUDE.md and is violated today at 20 minutes.

---

## Phase 5: The CLI transport, behind a setting

**5.1 Images travel as base64 content blocks, not through the Read tool.** `CliTransport` writes the exact Anthropic content-block JSON to the CLI's stdin via `--input-format stream-json`. `_image_block` is shared verbatim with `SdkTransport`. There is no agentic file access and therefore no fabrication path. The Phase 3.3 assertion runs here too.

**5.2 Pinned argv, run from a scratch cwd that carries no project memory.** This was previously the plan's weakest number and it is now measured. Three live measurements of the same two-token prompt:

| Invocation | Input tokens |
|---|---|
| Unpinned, from the PostRoll repo root | **38,252** (3 input + 38,249 cache_creation) |
| **Pinned**, from the PostRoll repo root | **5,845** (3 input + 5,842 cache_read) |
| **Pinned**, from a directory with no project memory | **130** |

**The residual 5.8k is not `CLAUDE.md`.** PostRoll has **no repo-root `CLAUDE.md` at all** (`ls` confirms it does not exist), so that was never the culprit. The 5.8k is the **project auto-memory** at `~/.claude/projects/-Users-danielhankins-wright-Documents-PostRoll/memory/` (119 files, including a 20 KB `MEMORY.md`), which is selected by **cwd** and which `--setting-sources ""` does not suppress. Its help text is about settings files, not memory files.

That is a **45x swing decided entirely by working directory**, and the default is the expensive one: `PythonBridge.swift:1737` does `cd '\(root.path)'` into the repo root before `exec`, so a `CliTransport` that inherits the process cwd would take the 5,845-token path on every single call.

**So the design requirement, not an optimisation:** `CliTransport` sets the child's cwd explicitly to a dedicated scratch directory that contains no project memory and no settings (created under the app's Application Support tree, e.g. `~/Library/Application Support/PostRoll/cli-scratch/`), and never inherits the Python process's cwd. Since `enrich_program` is the one caller that legitimately needs file access, its directory scope comes from explicit `--add-dir` arguments, not from cwd (escalated decision 5).

Tests:
- `CliTransport` always passes an explicit cwd, and that cwd is never the repo root (a unit test on the constructed invocation, no network);
- the scratch directory is created if absent, and asserted to contain no `CLAUDE.md` and no `.claude/` before use;
- **a live, `@pytest.mark.live`-gated measurement** asserting the pinned invocation from the scratch cwd reports input tokens **under 500**, so a future Claude Code release that starts loading something new fails the suite loudly instead of quietly costing 45x. (A hardcoded 130 would be brittle; 500 is a ceiling with headroom, and this is the guard asserting the quantity it exists to protect, per L63.)

The pinned form:

```
--setting-sources "" --strict-mcp-config --tools "" --disable-slash-commands
--system-prompt <ours> --no-session-persistence
--input-format stream-json --output-format stream-json --verbose
--model <resolved id>
```

run with cwd set to the scratch directory.

**Explicitly refuse `--bare`**: its help text says OAuth and keychain are never read, so it cannot reach the subscription at all. Pin `POSTROLL_CLAUDE_BIN` and assert `claude --version` matches a recorded supported version at startup. 2.1.226 is what is installed today, and the stream-json contract is a moving target between Claude Code releases (L25).

**5.3 Scrub the child environment.** `CliTransport` explicitly deletes `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`. Without this, `PythonBridge.swift:1729`'s `apiKeyDelivery(KeychainStore.readAPIKey())` (whose script lines export the Keychain key into every Python invocation) makes the "free" path bill while the UI says it did not. Test with a poisoned environment: assert the child sees none of the three.

**5.4 The receipt is `apiKeySource == "none"`.** From the stream-json `system/init` line. **Not** `total_cost_usd == 0`: a genuine subscription run measured this session reported `total_cost_usd: 0.00045` while reporting `apiKeySource: "none"`, and a hard 401 reports 0. Zero means nothing ran, not nothing was billed. If the receipt is absent or any other value, refuse the run and say why. Store both fields (Phase 3.5).

**5.5 Classify from `is_error` and `api_error_status`.** Never from exit code (the CLI returns 0 on a 401) and never from `subtype` (which reads `"success"` on that same 401). Add a distinct `ClaudeQuotaError` that is **not** a `ClaudeError` subclass, so it escapes every existing swallow site.

The mechanism is right, but the inventory must be complete, because each site needs a deliberate review of what it does when a quota wall arrives instead of a transient failure. There are **eight** sites:

| Site | Current behaviour on `ClaudeError` |
|---|---|
| `claude_client.py:343` (`run_review_pass`) | Warn, return prior draft. All seven review-pass call sites (`revise_blog.py:186,200`, `generate_captions.py:796,810`, `generate_blog.py:1668,1685`, `revise_caption.py:157`) funnel through this one catch |
| `ocr_program.py:492` | Fallback recovery, warn and continue |
| `ocr_program.py:509` | Fallback recovery, warn and continue |
| `ocr_program.py:531` | Fallback recovery, warn and continue |
| `generate_blog.py:1493` | Bare `continue` inside a per-paragraph fix loop |
| `generate_blog.py:1525` | Bare `continue` inside a per-paragraph fix loop |
| `select_cover_photo.py:173` | **Returns `_fallback_pick`**, silently substituting a heuristic choice for a Claude decision |
| `learn_from_edits.py:158` | `sys.exit(1)` |

A non-`ClaudeError` `ClaudeQuotaError` does escape all eight. But `select_cover_photo.py:173` is the same class of defect as `run_review_pass`, a silent substitution that reads as success, and deserves the same treatment independent of the quota work: it should say, in the run output, that the cover photo was picked heuristically because Claude failed. File that as its own issue in the same change (L65).

**5.6 Cap handling from `rate_limit_event`, calibrated on 130 tokens per call and no overage cushion.** The stream carries `{"status", "resetsAt", "rateLimitType": "five_hour", "overageStatus"}`. Use `resetsAt` for the "wait until" timestamp and `status` for the warn threshold, wired into the Phase 4.2 halted screen through the checkpoint carrier.

Two measured facts change the arithmetic and must be built in, not discovered later:

- **The per-call floor is 130 input tokens, not the 665 an earlier draft assumed and not the 5,845 the repo-root cwd would produce.** All cap forecasting, the warn threshold, and any "how many days can this week still afford" estimate are computed from the 130-token floor plus the actual per-call prompt and image tokens, with a live assertion (5.2) that the floor has not silently moved.
- **There is no overage cushion.** Dan's account reports `overageStatus: "rejected"` with `overageDisabledReason: "out_of_credits"`, so hitting the five-hour window is a hard wall with nothing behind it. The design must not include, and the UI must not imply, any "it will just cost a bit more past the limit" behaviour. The only two choices at the wall are the two Dan locked: wait for reset, or explicitly switch this run to paid.

Also note, and surface where relevant: the CLI reported `contextWindow: 200000` for `claude-sonnet-4-6`, not the 1M the API documents. Any per-call sizing (how many program pages, how many photos) must be computed against the **CLI-reported** context window read off the `system/init` line, not against a documented figure, and the two transports may therefore disagree on what fits.

Add `--max-budget-usd` as a second belt.

**5.7 The injection test that SDK tests structurally cannot reproduce.** A test that deliberately pollutes a `CLAUDE.md` in a directory and installs a `SessionStart` hook, then asserts the pinned invocation from the scratch cwd still returns parseable strict JSON. This failure mode has no coverage otherwise, because an SDK call literally cannot receive hook or CLAUDE.md content. Paired with 5.2's token-ceiling assertion, it covers both halves: the content is inert **and** it is not being loaded.

---

## Phase 6: Flip, judge, keep the revert live

- Default stays paid. The setting flips one call site's mode; the revert is the same one line.
- Run one real week on the subscription. Compare against the Phase 3.5 telemetry from the metered weeks, and against the 130-token-per-call floor the cap arithmetic assumes.
- Re-run the whole suite with mode forced to CLI so both transports are exercised, not just the shipped one (L3). **The Python half runs in CI on the PR; the Swift half does not** (`if: github.event_name != 'pull_request'`), so the Swift run with mode forced to CLI is a local run pasted into the PR body, plus the post-merge `main` run. Note the Swift job runs on the **macos-15 default toolchain** (the workflow pins `runs-on: macos-15` and installs xcodegen but never selects an Xcode version), which differs from local Xcode 26.6 on actor isolation, so expect Sendable and isolation diagnostics that do not reproduce locally and that will only appear **after** merge unless decision 1 says otherwise.
- Keep OCR's transport a separate decision from the rest, see escalated decision 2.

---

## Sequencing summary

Every "green" below means: **Python green in CI on the PR**, and **Swift green from a local `xcodebuild ... -scheme PostRollTests` run pasted into the PR body**, then green on the post-merge `main` run. CI cannot enforce the Swift half pre-merge (see the CI note above).

| Phase | Ships | Gate to proceed |
|---|---|---|
| 0 | Nothing | Four control results, input **and** output tokens, written into #200; `max_tokens` re-baseline recorded; live-test gate proven to deselect by default; fixture pinned by SHA-256 |
| 1 | #200 fixed on metered path | Failing `Safa` test now passes 3/3; thinking-block, refusal and per-model `max_tokens` readers tested; three-page-size raster target test green; 530+ Python green, Swift green locally and post-merge |
| 2 | Text-layer cross-check + flags | Embedded-page fixture exists (2.0) or the embedded branch is deliberately unshipped with its issue filed; failure-path tests green, including reclaimed pages (the majority case) and the filename-collision case |
| 3 | Transport seam, pinned to paid | All tests green, zero behaviour change |
| 4 | Checkpointing, halted screen, real progress | Crash-at-day-3 test green; stale-checkpoint-plus-exit-3 yields `.failed`; chatty-child no-hang test green; profile-noise-produces-no-progress test green |
| 5 | CLI transport behind a setting | Scratch-cwd token ceiling asserted live under 500; receipt, env-scrub, and injection tests green |
| 6 | The flip | One real week measured against the 130-token floor |

## title

Move PostRoll AI calls onto the Claude Max subscription, and fix #200's program-page downscale, in that order

## overruledDissent

[
  "Dissent: 'just raise MAX_IMAGE_EDGE to 2576 and ship it.' Overruled and now structurally blocked. claude_client.py:78 feeds a clamp at :97-98, but ocr_program.py's four call sites pass no model= and take the 'sonnet' default, which resolves to claude-sonnet-4-6 (claude_client.py:38), a 1568px-cap model. The server re-downscales regardless, so the change is a guaranteed no-op that would have read as a fix. Phase 1.1 makes the cap a property of the resolved model so the wrong fix cannot be written.",
  "Dissent: 'bump rasterise scale from 2 to 4 and move on.' Overruled after measuring what rasterise actually multiplies. It scales the PDF POINT size (ProgramPDFBuilder.swift:184), so a 387x612pt page becomes 1548x2448 while a 3024x4032pt MediaBox becomes 12096x16128, on files that already run 30MB for two pages, and both overshoot or undershoot the 2576 target the change exists to serve. Phase 1.3 computes scale per page against a target long edge instead.",
  "Dissent: 'the halted state only needs the exit code and the checkpoint to agree.' Overruled. The child is zsh -l -c (PythonBridge.swift:1747), so a failure before exec returns the SHELL's status and Python may never have run, while a checkpoint from a previous run still sits on disk saying halted. Two signals that both describe state this run never wrote is the self-agreeing check L70 names. Phase 4.2 adds a Swift-generated run_id that Python must echo, and 4.1 stamps a fresh checkpoint before the first Claude call.",
  "Dissent: 'CLAUDE.md is the per-call context cost, so --setting-sources \\\"\\\" handles it.' Overruled by measurement. PostRoll has no repo-root CLAUDE.md at all. The residual 5,842 cache_read tokens are the project auto-memory selected by cwd, which that flag does not touch. Since PythonBridge.swift:1737 cds into the repo root, the default path was the 45x-expensive one. Phase 5.2 pins an explicit scratch cwd and asserts the floor live.",
  "Dissent: 'swapping OCR to Sonnet 5 is a model-string change plus thinking handling.' Overruled. Sonnet 5's new tokenizer emits roughly 30% more tokens for the same text and max_tokens caps thinking plus text together, so the existing truncation guard at claude_client.py:173 can fire on a 16-page program that fits fine today, with thinking fully disabled. Phase 0.4 measures output_tokens and Phase 1.4 makes max_tokens per-model.",
  "Dissent: 'the freshness check already used at AssetGenerationView.swift:694 is good enough, the reclaimed-pages case is an edge case.' Overruled and inverted. All 19 events in events.json have programImagePaths == [], so fingerprint(of: []) returns \\\"\\\" and that check is false for every event on the machine. Reusing it would disable Phase 2 on 100% of its intended population, not on an edge case.",
  "Dissent: 'phase gates can just say all tests green.' Overruled. .github/workflows/tests.yml gates the swift job on `github.event_name != 'pull_request'`, so the 436 Swift tests run only after merge. Saying 'green' without naming that would have made every gate in this plan unenforceable for half the codebase while reading as rigorous."
]

## idealVsDoable

The ideal version differs in four places, all deferred for reasons that are about correctness or Dan's choice rather than effort.

First, the ideal version runs the 436 Swift tests on every pull request, so a phase gate means the same thing for both languages. It is deferred because the workflow deliberately skips macOS runners on PRs to avoid a 10x minute multiplier on a private repo, and that is a spend decision belonging to Dan (escalated decision 1). The plan compensates with a mandatory local run pasted into the PR body, which is weaker: it depends on the agent actually running it and on the local Xcode 26.6 agreeing with CI's macos-15 default on actor isolation, which it is already known not to.

Second, the ideal version would isolate resolution from resampling on the #200 page, proving which of the two actually loses the character. It cannot, because the real reduction is 2.57x and the two variables are inseparable on this input. Control A2 (BICUBIC against LANCZOS) is offered as the closest available substitute.

Third, the ideal Phase 2 ships the provenance heuristic asserted against both a real publisher-text page and a real Vision-drawn page. No publisher-text specimen exists on this machine, so the plan makes creating one a numbered prerequisite for Dan, and if he cannot produce one, the embedded branch does not ship at all rather than shipping half-assumed.

Fourth, the ideal version would make the subscription path measurably faster than the 15 to 20 minutes Dan accepted, by batching day generation concurrently. That is deliberately not attempted here: concurrency against a hard five-hour cap with no overage cushion (overageStatus rejected, out_of_credits) turns a graceful per-day halt into several simultaneous partial failures, and Phase 4.1's per-day checkpoint is what makes the halt safe in the first place. Speed work belongs after one real week has been measured, not before.

## escalatedDecisions

[
  {
    "question": "The 436 Swift tests never run on pull requests (the workflow skips macOS runners on PRs to avoid a 10x private-repo minute multiplier). Every phase gate in this plan is therefore Python-enforced and Swift-honour-system until after merge. How should that be closed?",
    "options": [
      "Add a PR-triggered Swift job and accept the 10x macOS minute billing, so every gate is real before merge",
      "Keep the current setup and rely on a local xcodebuild run pasted into each PR body plus the post-merge main run, treating a red post-merge run as an immediate revert",
      "Add a PR-triggered Swift job that runs only a fast subset (the suites this plan touches: ProcessRunner, ProgramPDFBuilder, AssetGenerationDisplay), leaving the full suite post-merge"
    ]
  },
  {
    "question": "Program OCR is the most vision-sensitive and most token-hungry call in the pipeline, and Phase 0 will measure roughly a 3x input-token increase from the 2576px pages plus a tokenizer increase on output. Where should OCR run once the subscription path exists?",
    "options": [
      "Pin OCR to the metered API permanently and move only the cheaper text calls to the subscription",
      "Move OCR to the subscription with everything else and let the cap logic handle it",
      "Decide from the Phase 0.4 numbers: subscription if a full program run costs under an agreed share of the five-hour window, metered otherwise"
    ]
  },
  {
    "question": "Phase 0 controls C and D test claude-sonnet-5 and claude-opus-5 on the same real page. If both read 'Safa' correctly, which does OCR pin to?",
    "options": [
      "claude-sonnet-5, the cheaper tier, if it reads the page correctly",
      "claude-opus-5 regardless of cost, since program OCR feeds every downstream caption and blog",
      "Decide per-call: sonnet-5 for the main extract, opus-5 only for the fallback passes that fire when the first read looks thin"
    ]
  },
  {
    "question": "No program PDF on this machine carries a publisher text layer (all three baked PDFs came from HEIC or PNG images), so Phase 2.2's provenance heuristic has a real specimen for only one of its two branches. What ships?",
    "options": [
      "Dan uploads one real publisher program PDF first (numbered steps are in Phase 2.0), so both branches are asserted against reality",
      "Ship the Vision branch only, treat every page as the weaker flag-only authority, and file the issue that turns on the embedded branch when a specimen arrives",
      "Ship both branches with the embedded side asserted against a synthetic PDF generated in the test"
    ]
  },
  {
    "question": "CliTransport must run from a scratch directory with no project memory (measured: 130 tokens per call versus 5,845 from the repo root). That means the CLI no longer sees the repo by default, which affects enrich_program, the one caller that legitimately needs file access. How should its scope be granted?",
    "options": [
      "Explicit --add-dir arguments naming exactly the directories that call needs, with everything else invisible",
      "Give enrich_program its own transport instance whose cwd is the repo root, accepting the 5,845-token cost on that one call only",
      "Have enrich_program read the files in Python and pass their contents in the prompt, so the CLI needs no file access at all"
    ]
  },
  {
    "question": "The #200 fixture is a real program page carrying performers' names and Instagram handles. Committing it puts that in git history permanently. How should the test get its input?",
    "options": [
      "Gitignored local fixture directory plus a skip guard when absent, so the test is real locally and silently skipped in CI",
      "Commit a redacted crop showing only the 'Safa' line, so the regression test runs in CI forever",
      "Commit nothing and keep the assertion as a live-marked manual check run before each release"
    ]
  }
]

## openRisks

[
  "The 130-token-per-call floor is a property of Claude Code 2.1.226's behaviour with an explicit scratch cwd. A future release could start loading something new from a different source, and the whole cap arithmetic would silently shift by up to 45x. Phase 5.2's live token-ceiling assertion is the only thing that would catch it, and it only runs when someone opts into --run-live.",
  "Dan's account reports overageStatus 'rejected' and overageDisabledReason 'out_of_credits', so the five-hour window is a hard wall with nothing behind it. If the reported rate_limit_event fields change shape or stop appearing in the stream, the warn threshold and the halt both go silent and the first symptom is a mid-week wall with no warning.",
  "The app draws on the same Max allowance as Dan's own Claude Code sessions, and nothing in this plan can see his other sessions' consumption. The warn threshold is computed from what the app itself spends plus whatever the rate_limit_event reports, so a heavy day of his own work can move the wall underneath a run that believed it had headroom.",
  "The CLI reported contextWindow 200000 for claude-sonnet-4-6 while the API documents 1M. If the two transports genuinely disagree on what fits, a program or photo batch that succeeds on the paid path can fail on the subscription path, which makes the revert switch non-symmetric in a way the plan only partially addresses.",
  "Phase 1.3 raises raster resolution and Phase 1.1 raises the upload cap, on baked PDFs that already run 30MB for two pages. Disk growth and peak memory during rasterisation are bounded by the clamp but not measured; a very large multi-page program is the untested case.",
  "The Swift half of every gate is unverified until after merge unless escalated decision 1 says otherwise, and local Xcode 26.6 is already known to differ from CI's macos-15 default on actor isolation. Phases 4 and 5 add concurrency-adjacent Swift code (a readabilityHandler-based pipe reader), which is exactly the category most likely to diverge.",
  "Phase 4.3 replaces readDataToEndOfFile with an incremental reader on both pipes in ProcessRunner, which every Python call in the app funnels through. A regression there breaks OCR, generation, and export at once, not only the week run, and its existing tests cover the old drain pattern.",
  "If Phase 0's control B passes (more pixels alone fixing the read on claude-sonnet-4-6), the diagnosis behind Phases 1.1 and 1.4 is wrong and the model swap, the thinking handling, and the per-model max_tokens work are all unnecessary. The plan gates on this, but only if whoever runs Phase 0 actually stops rather than proceeding on momentum.",
  "Phase 2.5's substring check against the text layer will produce false-positive flags on stylised program pages where Vision garbles the glyphs (the champion measured 'Sottlieb, Jake' and 'aunno'). If the flag rate is high enough to be noise, Dan will start dismissing flags wholesale, which is L36's cry-wolf failure and would make the cross-check worse than nothing."
]
