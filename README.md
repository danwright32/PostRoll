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

After the first install you do not need this command again. When the running
app is older than the code, PostRoll says so on launch and offers to update
itself: the button runs `PostRollApp/update-postroll.sh`, which pulls if the
checkout is behind and then runs the same `build-install.sh`, so the tests
still gate the install. It runs as a separate process because installing quits
PostRoll and reopens it, and it records how it ended in
`app-update-outcome.json` under the data root, which is how a failure that
happened after the app was quit is reported at the next launch.

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
make test-python   # the Python pipeline suites, all of them
```

Between edits, when even two minutes is too long to wait on a one line change:

```
make test-python-fast
```

That deselects the handful of test files measured above the floor in
`tests/file_durations.py`, which is three of them today. It is a loop, not a
gate: `make test-python` and CI still run everything. Which files it skips comes
from a measurement rather than a guess (#766), so a new file heavy enough to
belong to the full run only is added to it by re-measuring:

```
make record-test-durations
```

A file's cost does not drift on its own, so nothing else needs that command.

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

## Recording a design change

`tests/test_media_design_fingerprint.py` fails whenever a media template's
source moves, and asks which of three things happened: the template renders
differently now, so `MEDIA_DESIGN_VERSIONS` has to be bumped, it renders
identically and only the record needs updating, or the encoder moved the pixels
while the design stood still. There is a command for each answer, and picking
the wrong one is the mistake this section exists to stop.

**The rendering changed, on purpose.** This is the door for a deliberate
redesign:

```
make record-design-change
```

The steps only work in one order, and each refusal for getting it wrong costs a
re-run of a suite that takes minutes: on 2026-08-20 the sequence was done five
times and the order was wrong twice (#786). This checks the version bump has
been made, regenerates the shared design stamp from its writer, re-records the
reference frames, and then STOPS and hands back the frames that moved. Looking
at them is the step nothing downstream can do for you, because the re-record is
the single way a broken frame becomes the expectation. Commit them, then run
`make record-fingerprints`, which refuses to vouch for a frame with uncommitted
changes and is what makes the order matter.

**The source moved and the rendering did not.** A rename, a refactor, a comment:

```
make record-fingerprints
```

Answer it with the command above rather than by editing
`tests/fixtures/media_design_fingerprints.json`. It runs the reference frames
that photograph each moved template and records only what they vouch for,
refusing by name for anything else: a template no reference frame covers, a
reference frame with uncommitted changes, or a check that skipped, failed or
reported nothing. A hand written re-record cannot tell the two cases apart, and
telling them apart is the entire job of the guard (#660).

**The pixels moved and the design did not.** An encode setting, a codec flag:

```
make record-codec-change
```

The third door (#818). #811 changed one encode argument on the clip reel and
moved 0.27% of its pixels, low amplitude spread over the frame, so the reference
frame failed and `make record-fingerprints` correctly refused, while the two
frames were indistinguishable side by side. The version bump was the only door
left, and a bump badges every cached asset of that template as out of date for a
change nobody can see.

This reads the shape of what moved, from the readings the comparisons already
take: how far the pixels moved on their worst channel, and how much of their own
box they fill. An encoder rounds, so its differences are shallow and scattered;
a moved or recoloured element leaves ink through its box. The thresholds and the
measured readings they sit between are in `tests/golden_drift.py`, and
`tests/test_codec_fidelity.py` holds them to those readings. Anything that reads
as a design change is refused with its numbers, and so is a check that skipped,
reported nothing, wrote no reading, or failed with its frame unchanged. What it
allows, it re-records and stops, because a low amplitude change local to one
element reads the same as an encoder and only a person looking at the two frames
can tell.

All three render real reels, so they take minutes rather than seconds, and all
three need ffmpeg and the macOS system fonts.

## The other commands

```
make build           # compile the app without installing it
make install-force   # install WITHOUT running the test suites first
make review-sheet    # render every screen the checks measure into one folder
make check-guards    # prove the registered guard tests still go red
make clean           # empty the build cache
```

`make review-sheet` keeps the previous run as a baseline and reports which
screens moved, which is how a visual change reviews itself instead of being
found by launching the app and navigating to each screen (#623). It says only
that a screen CHANGED: whether a screen is correct stays the business of the ink
and footprint checks.

`make check-guards` breaks the code each registered guard is meant to catch and
fails on any guard that stays green (#416). It is not part of `make test`: it
mutates the working tree and recompiles per entry, so it costs about 12 to 22
seconds each. Run it when a guard is added or changed; for just the entries your
diff touches, `venv/bin/python tools/check_guards.py --changed`.

`make install-force` skips the gate that `make install` runs. It exists for
getting a build onto the machine while something unrelated is red, and using it
means the installed app was never tested.

## Waiting for a pull request's checks

```
python tools/wait_for_checks.py <pr-number>
```

Do not read `gh pr checks` by hand before merging. It gets two things wrong,
and both of them read as an answer. In the window between a push and the checks
being registered it reports nothing at all, which is indistinguishable from
everything passing, and twice on 2026-08-14 that was nearly merged on (#564).
It also reports rows keyed by workflow and check name with no notion of which
commit produced them, so a push landing while the previous run finishes mixes
two commits' answers: on 2026-08-17 three consecutive pushes each reported the
previous commit's failure within seconds, and the mirror of that is a
superseded run reporting green for a commit nothing has judged (#669).

The tool derives the checks it is waiting for from the workflow files, so
adding a job raises the bar with no edit to the tool. It resolves the pull
request's head commit and asks the Actions API for the runs at exactly that
SHA, refusing any run or job that names another one, and it will not call a
commit green while a run at it has yet to finish. Every line it prints names
the commit it judged, so a green can be checked against the commit about to be
merged.

Merge with the tool rather than as a second step afterwards:

```
python tools/wait_for_checks.py <pr-number> --merge
```

A green proves that one named commit passed. A merge taken separately is
against whatever is at the top of the branch by then, so a push landing in the
seconds between the two merges a commit nothing has judged, and that is the one
step that cannot be undone (#674). With `--merge` the tool squash merges the
exact commit it judged, passing it to GitHub as `sha`, which refuses with a 409
when the head is no longer that commit. It reads the reply rather than trusting
the exit code: a merge is reported only when GitHub says it merged.

A green also has to have been earned against the base it would land on. Main
moves while a branch waits, so two changes that are each green against their
own base can merge into a main neither of them was ever run against (#680).
Before merging, the tool asks where the base branch is now and refuses a head
that does not contain it, naming how far behind it is and where main has got
to. Rebase, push, and wait again.

That comparison is taken immediately before the merge, which makes the window
seconds wide rather than closing it: GitHub's merge endpoint takes the head as
`sha` but has no matching precondition for the base. Closing it by construction
takes the repository setting "require branches to be up to date before
merging", which is not switched on for this repository.

It exits `0` only when every expected check has settled green, and with
`--merge` only when that commit is also merged. `1` means red, `2` means a
check never appeared, `3` means the deadline passed with something still
running, `4` means it could not read the workflows or reach `gh` (including
when it could not find out whether the branch is up to date), `5` means the
commit was green but the merge was refused, which is what a head moving in
between looks like, and `6` means the commit was green against a base that has
since moved. Only `0` may be merged on.

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
