# PostRoll

A Mac app that turns a night of performing-arts photography into a week of
posts: it reads the program, writes the captions and the blog draft in Dan
Wright Photography's voice, renders the story graphics and reels, and exports a
folder ready to upload.

It is a SwiftUI app (`PostRollApp/`) over a Python media and AI pipeline
(`postroll/`). The app shells out to Python for everything that touches Claude,
Pillow or ffmpeg.

- Product spec: [postroll-prd.md](postroll-prd.md)
- Visual design system: [PostRollApp/DESIGN.md](PostRollApp/DESIGN.md)

## Set up on a new Mac

Six steps. Run them in order from the repo root.

**1. Install the tools that aren't Python packages.**

```
brew install ffmpeg xcodegen
```

`ffmpeg` and `ffprobe` (both come from that one formula) render every reel.
Without them the app reports which one is missing and refuses to substitute a
still image. `xcodegen` generates the Xcode project.

**2. Create the Python environment.**

```
python3 -m venv venv && venv/bin/python -m pip install -r requirements.txt pytest
```

**3. Generate the Xcode project.**

```
cd PostRollApp && xcodegen generate && cd ..
```

`PostRoll.xcodeproj` is generated from `PostRollApp/project.yml` and is not
hand-edited. Adding a source file means adding it to `project.yml` and
regenerating.

**4. Create the local signing identity, once per Mac.**

```
./PostRollApp/setup-signing.sh
```

This makes a stable self-signed identity. Without it each rebuild is a
different bundle to macOS, so every folder-access grant is forgotten and the
permission prompts come back on every launch.

**5. Build, sign, verify and install.**

```
make install
```

That runs `PostRollApp/build-install.sh`, which is the only supported way to
install: it clears extended attributes, signs with the stable identity, and
refuses to finish if the installed bundle fails signature verification.

**6. Point git at the repo's own hooks, once per clone.**

```
git config core.hooksPath .githooks
```

This turns on `.githooks/pre-push`, which refuses a push while iCloud numbered
copies of tracked files (`DesignStamp 2.swift`) sit in the working tree (#299).
This repo lives under `~/Documents` with iCloud sync on, so those copies appear
on their own, are byte identical to the originals, and silently absorb edits
meant for the real file. The check is `tools/check_icloud_duplicates.py`; the
test suite runs it over the working tree too, so a copy fails the build even
without the hook. Skip it for one push, out loud, with
`SKIP_ICLOUD_DUP_CHECK=1 git push ...`.

## Configuration

**The Anthropic API key** is set inside the app: Settings, paste the key, Save.
It is stored in the login Keychain and handed to the Python subprocess through
its environment. This is a metered API and a week's generation is a real
recurring cost (see section 12 of the PRD).

**Everything else** is read from your login shell, because the app runs Python
through `zsh -l`. Put these in `~/.zshrc`:

| Variable | Required | What it does |
| --- | --- | --- |
| `JAMENDO_CLIENT_ID` | For auto-fetched reel music | Jamendo API client id. Without it, reels need an audio file uploaded by hand. |
| `ANTHROPIC_API_KEY` | No | Only a fallback. The app's Keychain entry takes priority; set this only if you want to run the Python pipeline from a terminal. |

Optional overrides, none of which need setting for normal use:

| Variable | What it does |
| --- | --- |
| `POSTROLL_DATA_DIR` | Where events, photos, programs and previews live. Defaults to `~/Library/Application Support/PostRoll`. Used by the tests to stay off live data. |
| `POSTROLL_PROJECT_DIR` | Where the Python checkout lives. Defaults to `~/Documents/PostRoll`. |
| `POSTROLL_BRAND_VOICE` | Path to the writable brand-voice file. Set by the app; override only for testing. |
| `POSTROLL_CLAUDE_BIN` | Path to the `claude` binary, used on the CLI fallback path. |
| `JAMENDO_TRACKS_URL` | Overrides the Jamendo endpoint. Test seam. |

## Running the tests

```
make test          # Swift model and service suites
make test-python   # the Python pipeline suites
```

Both run in CI on every push to `main` (`.github/workflows/tests.yml`). The
Swift job is scoped to `main` and manual runs because macOS runner minutes bill
at ten times the Linux rate on a private repo.

The Swift unit tests compile the model and service layer directly into the test
bundle, with no app host, so they cannot reach the live data store. The UI tests
(`PostRollApp/UITests`) drive the real app against a sandboxed
`POSTROLL_DATA_DIR` and are excluded from CI.

## Layout

```
PostRollApp/          the SwiftUI app
  Sources/Models      Event, PostingDay and the rest of the stored shapes
  Sources/Services    storage, export, the Python bridge, background managers
  Sources/Views       one file per screen in the week's workflow
  Tests/              the unit suites; UITests/ drives the real app
postroll/             the Python pipeline
  ai/                 captions, blog, OCR, enrichment, the Claude client
  media/              collage, story, before/after and reel renderers
tests/                the Python suites
```
