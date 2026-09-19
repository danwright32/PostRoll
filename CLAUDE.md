# PostRoll

A Mac app that turns a night of performing arts photography into a week of posts: it reads the
program, writes the captions and the blog draft in Dan Wright Photography's voice, renders the
story graphics and reels, and exports a folder ready to upload.

`README.md` is long and current. `postroll-prd.md` is the product spec and `.impeccable.md` the
design context; read both before changing UI or domain logic.

## Where things are

- `PostRollApp/` is the SwiftUI app and `postroll/` the Python media and AI pipeline. The app
  shells out to Python for everything that touches Claude, Pillow or ffmpeg, so a change to either
  half usually needs the other read as well.
- `tests/` holds the Python suites (pytest, with `conftest.py` and `fixtures/` beside them);
  the Swift tests live in the app's Xcode project under `PostRollApp/`, which xcodegen
  generates from `PostRollApp/project.yml`. `tools/` and `scripts/` hold the helpers and
  `docs/` the record.
- `Makefile` is the entry point for all of it.

## Build and test

    make build          build the app
    make test           run everything
    make test-swift     the Swift suite only
    make test-python    the Python suite only
    make check-guards   the repository's own guards
    make check-toolchain   refuse when this Mac's Xcode is AHEAD of the one CI uses

## What to know before editing

- Go through the Makefile target rather than a raw xcodebuild or pytest command. Each target does
  setup the raw command does not, including the lock that keeps two xcodebuild suites off this Mac
  at once.
- Python runs on the interpreter `venv-python.sh` resolves, never the system one. `venv/` is
  gitignored, so it exists in the primary checkout and in no worktree, which is what that script
  exists to handle.
- Working in a worktree is how one session avoids editing the primary checkout underneath another.
  It is the normal way to work here, not an exception.
- The toolchain rule is one directional. CI's compiler ahead of this Mac's is fine, because it
  accepts everything this one does. This Mac ahead of CI is the hole: code that builds here is
  rejected there, and nothing local can tell you.
