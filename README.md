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
brew install ffmpeg xcodegen python@3.11
```

`ffmpeg` and `ffprobe` (both come from that one formula) render every reel.
Without them the app reports which one is missing and refuses to substitute a
still image. `xcodegen` generates the Xcode project.

**2. Create the Python environment.**

```
/opt/homebrew/opt/python@3.11/bin/python3.11 -m venv venv && venv/bin/python -m pip install -r requirements.txt pytest
```

Named explicitly rather than `python3`, which is whatever the shell finds
first. This venv was once built on the Python inside Xcode.app, which meant an
Xcode update could take the whole generation pipeline with it, and it held the
Mac on 3.9 while CI ran 3.11 (#656). 3.11 is what every CI job installs, so
matching it is what makes a green run here mean anything. `make check-toolchain`
refuses both mistakes, and `build-install.sh` runs it before installing.

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
| `POSTROLL_PROJECT_DIR` | Where the Python checkout lives. Defaults to the folder the app was built from, which the build records into the bundle, so moving the checkout and reinstalling is enough. Set this only to point a build at a different checkout. |
| `POSTROLL_BRAND_VOICE` | Path to the writable brand-voice file. Set by the app; override only for testing. |
| `POSTROLL_CLAUDE_BIN` | Path to the `claude` binary, used on the CLI fallback path. |
| `JAMENDO_TRACKS_URL` | Overrides the Jamendo endpoint. Test seam. |

## Running the tests

```
make test          # Swift model and service suites
make test-python   # the Python pipeline suites
```

The Python suite runs in `.github/workflows/tests.yml` and the Swift half in
`.github/workflows/swift.yml`, and BOTH run on every pull request as well as
every push to `main`, whatever the change touched. macOS runner minutes do bill
at ten times the Linux rate on a private repo, and that cost is accepted
deliberately (#431): the two attempts at narrowing it, first skipping the Swift
job on pull requests and then filtering it by path, each hid a real failure.

The Swift unit tests compile `Sources` directly into the test bundle, with no
app host, so they cannot reach the live data store. There is no UI test target:
a headless runner cannot reliably drive a window, and a test nothing runs is
indistinguishable from no test, so it was removed rather than left to rot
(#524).

## Re-recording a design fingerprint

```
make record-fingerprints
```

`tests/test_media_design_fingerprint.py` fails whenever a media template's
source moves, and asks which of two things happened: the template renders
differently now, so `MEDIA_DESIGN_VERSIONS` has to be bumped, or it renders
identically and only the record needs updating.

Answer it with the command above rather than by editing
`tests/fixtures/media_design_fingerprints.json`. It runs the reference frames
that photograph each moved template and records only what they vouch for,
refusing by name for anything else: a template no reference frame covers, a
reference frame with uncommitted changes, or a check that skipped, failed or
reported nothing. A hand written re-record cannot tell the two cases apart, and
telling them apart is the entire job of the guard (#660).

It renders real reels, so it takes minutes rather than seconds, and it needs
ffmpeg and the macOS system fonts.

## Waiting for a pull request's checks

```
python tools/wait_for_checks.py <pr-number>
```

Do not read `gh pr checks` by hand before merging. In the window between a push
and the checks being registered it reports nothing at all, which is
indistinguishable from everything passing, and twice on 2026-08-14 that was
nearly merged on (#564).

The tool derives the checks it is waiting for from the workflow files, so
adding a job raises the bar with no edit to the tool, and it exits `0` only
when every one of them has settled green. `1` means red, `2` means a check
never appeared, `3` means the deadline passed with something still running, and
`4` means it could not read the workflows or reach `gh`. Only `0` may be merged
on.

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
