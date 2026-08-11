"""The wordmark: one place that owns it, and it is required (#334).

Dan's mark is a file that ships in this repo. Every template used to be handed
it as `LOGO_BLACK if Path(LOGO_BLACK).exists() else None` and every generator
carried its own copy of "open it, scale it to my LOGO_WIDTH, or draw nothing".
Five copies of one behaviour, and the behaviour was wrong: a mark that cannot be
opened became no mark at all, silently, on work going to clients.

Nothing looked for the absence either. The legibility bands are built from the
same `if logo_path`, so a reel with no mark also had no band, and the check that
exists to catch an unreadable signature is structurally unable to notice a
missing one.

So the absence is a broken install, not a setting. `required` refuses, naming
the file, the way a chosen photo that is not on disk already does. `load` keeps
one meaning for None: nothing was asked for. A path that IS given and is not
there raises, because at that point something asked for a mark and the render
cannot honour it.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

from .missing_media import MissingMediaError, require_present


#: The slot name every message about the mark uses, so one input reads as one
#: condition wherever it surfaces.
LABEL = "the PostRoll wordmark"

ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"

#: Black on cream, white on photographs. Picking the wrong one has shipped an
#: invisible mark twice, so the two are named rather than derived.
BLACK = str(ASSETS_DIR / "logo-black.png")
WHITE = str(ASSETS_DIR / "logo-white.png")


def required(path: str | Path | None) -> str:
    """`path` when the wordmark is there, else refuse the render naming it.

    For a caller that has DECIDED this render carries a signature. Handing back
    None so the template can draw nothing is exactly the defect: an unsigned
    reel is indistinguishable from a signed one to every check in the suite, and
    from success to the person exporting it.
    """
    if not path:
        raise MissingMediaError(LABEL, "no path was given for it")
    return require_present(path, LABEL)


def load(path: str | Path | None, width: int) -> Image.Image | None:
    """The wordmark scaled to `width`, or None when no mark was asked for.

    `width` is per template: the plate's colophon, the collage strip and the
    screen reel's footer each size it to their own layout, which is the one
    thing the five copies of this genuinely differed on.
    """
    resolved = require_present(path, LABEL)
    if resolved is None:
        return None
    logo = Image.open(resolved).convert("RGBA")
    scale = width / logo.width
    return logo.resize((int(logo.width * scale), int(logo.height * scale)),
                       Image.LANCZOS)
