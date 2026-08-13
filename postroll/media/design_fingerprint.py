"""What each media template's design is made of, reduced to one hash (#294).

`MEDIA_DESIGN_VERSIONS` in `design_tokens.py` is bumped by hand. Nothing checked
that a bump actually happened when a template's geometry or tokens changed, so a
redesign could ship with the version untouched: the stamp then records the new
design under the old number, no day is ever badged, and every cached asset keeps
rendering the old look while the guard reports green the whole time. That is the
defect #160 and #286 were written for, returning through a different door.

A fingerprint is taken over the two things that decide what a template renders:

1. The code of the module that draws it, plus every module under
   `postroll/media/` that one imports, transitively. Parsed to an AST and
   dumped, so comments, docstrings, blank lines and reformatting do not move it,
   while a changed number, a changed call or a changed branch does.

   The boundary is `postroll/media/` on purpose. The reel generators also reach
   into `postroll.ai.audio_tags` and `postroll.audio` to choose their music, and
   following those would move all five reel fingerprints every time a search tag
   was tweaked. The design of a template is drawn here; which track plays over
   it is a different question, tracked separately.
2. The values of the design tokens that closure actually reads. Only those, so
   changing `MAT_PRINT` moves the templates that mat a single print and leaves
   the rest alone. A hash over the whole token file would move every template on
   every token change, and a check that fires on everything is one nobody reads.

`tests/test_media_design_fingerprint.py` holds the committed value per template,
beside the version it was taken at, and fails until both are reconciled.

The honest limit: nothing here can decide whether a code change alters a single
rendered pixel. It forces the question to be asked, at the moment the change is
made, by the person who knows the answer. That is the whole of what it claims.
"""

from __future__ import annotations

import ast
import hashlib
from pathlib import Path

from . import design_tokens

PACKAGE_ROOT = Path(__file__).resolve().parent.parent  # postroll/


#: Which module draws each template in `MEDIA_DESIGN_VERSIONS`.
#:
#: Kept here rather than derived from `generate_media.py`, because the call
#: sites take the output path a dozen different ways and a parser fitted to
#: today's shapes would silently stop matching. It is not allowed to be a list
#: of what somebody remembered, though: the test asserts it in BOTH directions,
#: so a template with no renderer and a renderer module claimed by no template
#: each fail (L96).
TEMPLATE_MODULES: dict[str, tuple[str, ...]] = {
    "collage": ("postroll.media.generate_collage",),
    "story": ("postroll.media.generate_story",),
    # Drawn by the story's own template, from a single photograph, which is why
    # its version moves with the story's.
    "cover": ("postroll.media.generate_story",),
    "before_after": ("postroll.media.generate_before_after",),
    "reel_screen": ("postroll.media.generate_reel_screen",),
    "reel_morph": ("postroll.media.generate_reel_morph",),
    "reel_slider": ("postroll.media.generate_reel_slider",),
    "reel_scroll": ("postroll.media.generate_reel_scroll",),
    # The still the Thursday crop editor draws over is built by
    # `build_reel_preview`, which lives in the scroll reel's module and shares
    # its layout maths.
    "reel_preview": ("postroll.media.generate_reel_scroll",),
    # Friday's clip reel is rendered, then the title card is composited over it,
    # so both decide what the finished file looks like.
    "reel_clip": ("postroll.media.render_clip_reel",
                  "postroll.media.generate_title_card"),
}


#: Design token names a fingerprint must ignore.
#:
#: The version numbers themselves. Including them would make bumping a version
#: change the fingerprint that demanded the bump, so the check could never
#: settle.
_IGNORED_TOKENS = frozenset({"MEDIA_DESIGN_VERSIONS", "COLLAGE_DESIGN_VERSION",
                             "UNVERSIONED_DAY_FILES"})

_TOKENS_MODULE = "postroll.media.design_tokens"


#: Where the modules being hashed are read from. Overridable so a test can
#: fingerprint a COPY of the tree instead of the checkout (#497).
#:
#: The four guards that prove this module notices a change used to write a
#: perturbed module into `postroll/media/` and restore it afterwards. That made
#: the whole suite unsafe to run in parallel, because a worker hashing the same
#: file mid-perturbation read the perturbation and reported a redesign that never
#: happened, and it meant a run interrupted between the write and the restore left
#: an edit in the working tree that nobody made.
#:
#: Only CODE is read from here. Token VALUES come from the imported
#: `design_tokens` module either way, since a value is what the running program
#: holds rather than what some copy of the file says.
DEFAULT_ROOT = PACKAGE_ROOT.parent


def module_path(dotted: str, root: Path | None = None) -> Path:
    """The source file of a first-party module, by dotted name."""
    if not dotted.startswith("postroll."):
        raise ValueError(f"not a first-party module: {dotted}")
    return (root or DEFAULT_ROOT) / (dotted.replace(".", "/") + ".py")


def _parse(dotted: str, root: Path | None = None) -> ast.Module:
    return ast.parse(module_path(dotted, root).read_text(encoding="utf-8"))


def _resolve(dotted: str, node: ast.ImportFrom) -> str | None:
    """The absolute module a `from ... import` inside `dotted` names.

    None for anything outside the postroll package: a change to Pillow or ffmpeg
    is not a change to this project's design, and pinning is what covers those.
    """
    if node.level == 0:
        return node.module if node.module and node.module.startswith("postroll") else None
    parts = dotted.split(".")[:-node.level]
    if node.module:
        parts += node.module.split(".")
    resolved = ".".join(parts)
    return resolved if resolved.startswith("postroll") else None


#: The package the design lives in. See the module docstring for why the closure
#: stops here rather than following every first-party import.
_DESIGN_PACKAGE = "postroll.media."


def _closure(dotted: str, root: Path | None = None) -> set[str]:
    """`dotted` and every `postroll.media` module it imports, transitively.

    The token module is excluded: its VALUES are hashed by name below, so
    including its source as well would move every template whenever any token
    changed, however unrelated.
    """
    seen: set[str] = set()
    pending = [dotted]
    while pending:
        current = pending.pop()
        if (current in seen or current == _TOKENS_MODULE
                or not current.startswith(_DESIGN_PACKAGE)):
            continue
        try:
            tree = _parse(current, root)
        except OSError:
            # A module named by an import that has no file of its own (a
            # package, a namespace). Nothing to hash, and nothing hidden: the
            # modules that draw things are all plain files.
            continue
        seen.add(current)
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                target = _resolve(current, node)
                if target:
                    pending.append(target)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name.startswith("postroll"):
                        pending.append(alias.name)
    return seen


def _strip_docstrings(tree: ast.AST) -> ast.AST:
    """Remove docstrings, so writing prose about a template is not a redesign."""
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                             ast.ClassDef)):
            body = node.body
            if (body and isinstance(body[0], ast.Expr)
                    and isinstance(body[0].value, ast.Constant)
                    and isinstance(body[0].value.value, str)):
                node.body = body[1:] or [ast.Pass()]
    return tree


def _code_hash(dotted: str, root: Path | None = None) -> str:
    return hashlib.sha256(
        ast.dump(_strip_docstrings(_parse(dotted, root)), annotate_fields=True).encode()
    ).hexdigest()


def referenced_tokens(dotted: str, root: Path | None = None) -> set[str]:
    """Design token names a module's closure reads.

    Both spellings the generators use: imported by name
    (`from .design_tokens import CREAM`) and reached through the module
    (`tokens.MAT_PRINT`). An attribute read is matched by name against what the
    token module actually defines, so `self.CREAM` on some other object cannot
    invent a token that does not exist.
    """
    defined = {name for name in vars(design_tokens)
               if name.isupper() and name not in _IGNORED_TOKENS}
    found: set[str] = set()
    for module in _closure(dotted, root):
        tree = _parse(module, root)
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                if _resolve(module, node) == _TOKENS_MODULE:
                    found.update(a.name for a in node.names if a.name in defined)
            elif isinstance(node, ast.Attribute) and node.attr in defined:
                found.add(node.attr)
    return found


def fingerprint(template: str, root: Path | None = None) -> str:
    """One hash over everything that decides how `template` renders.

    `root` is where the code is read from, defaulting to this checkout. See
    DEFAULT_ROOT for why anything else would want to pass it.
    """
    modules = TEMPLATE_MODULES[template]

    parts: list[str] = []
    closure: set[str] = set()
    for dotted in modules:
        closure |= _closure(dotted, root)
    for dotted in sorted(closure):
        parts.append(f"code {dotted} {_code_hash(dotted, root)}")

    tokens: set[str] = set()
    for dotted in modules:
        tokens |= referenced_tokens(dotted, root)
    for name in sorted(tokens):
        parts.append(f"token {name} {getattr(design_tokens, name)!r}")

    return hashlib.sha256("\n".join(parts).encode()).hexdigest()


def fingerprints(root: Path | None = None) -> dict[str, str]:
    """Every template's fingerprint, keyed as `MEDIA_DESIGN_VERSIONS` is."""
    return {name: fingerprint(name, root) for name in sorted(TEMPLATE_MODULES)}
