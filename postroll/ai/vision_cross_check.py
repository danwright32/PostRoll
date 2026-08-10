"""Cross-check OCR output against the Vision text layer already on disk (#209).

`ProgramPDFBuilder.drawTextLayer` runs Apple Vision text recognition at full
native resolution over every program page at upload time and bakes the strings
invisibly into the program PDF. That layer is a character-level authority for
SPELLING: on the real BLUDLINE program it holds "Safa @safa.wav" verbatim and
correct, which is the exact character Claude got wrong. The right answer was
already on the machine, on device, free, in a file that already existed.

It is authority for spelling and nothing else. The Vision reading order is
scrambled across columns, so it cannot say who is a soloist and who is a
composer, or which piece a note belongs to. Claude keeps all of that.

Anything Claude returns that Vision cannot confirm becomes an ordinary flag and
goes into the OCR review loop that already exists, rather than being corrected
automatically: Vision is the better speller, not the better reader, and a
silent substitution is the failure mode this is meant to prevent.
"""

from __future__ import annotations

import difflib
import re
import unicodedata
from typing import Any


class VisionTextUnavailable(Exception):
    """The text layer is missing, empty, or too thin to be an authority.

    Raised rather than returning no flags. A check that silently produces
    nothing is indistinguishable from a program with nothing wrong in it, so
    the first unbuilt or half-baked PDF would switch the whole thing off and
    report clean (#209 asks for it to fail loudly instead).
    """


#: Below this many distinct words the layer cannot be a program page. A PDF
#: whose bake failed can still carry a stray title, and treating that as
#: authority would flag every correct name in the program.
MIN_VISION_WORDS = 8

#: Tokens this short (initials, "de", "van") carry no spelling signal and appear
#: in any text, so matching them proves nothing either way.
MIN_TOKEN_LENGTH = 3

#: How close a Vision word has to be before it is offered as the correction.
#: Tight enough that an unrelated word is not proposed as somebody's name.
SUGGESTION_CUTOFF = 0.75

#: Handles need a looser one. Where a misread name differs by a character or
#: two, a wrong handle usually shares the stem and differs across the whole
#: suffix (@safa.music against the program's @safa.wav), which scores well below
#: the threshold a name is held to. This only decides whether the program's real
#: handle is OFFERED in the flag; nothing is substituted automatically.
HANDLE_SUGGESTION_CUTOFF = 0.6

_HANDLE = re.compile(r"@[A-Za-z0-9._]+")
_WORD = re.compile(r"[^\W_]+", re.UNICODE)


def _normalise(text: str) -> str:
    """Casefold and normalise composed characters, keeping the letters intact.

    Accents are spelling, so they survive; case and the layout punctuation
    around a name ("Yefim Kolodkin, conductor") are not.
    """
    return unicodedata.normalize("NFC", text).casefold()


def _words(text: str) -> set[str]:
    return {_normalise(w) for w in _WORD.findall(text)}


def _handles(text: str) -> set[str]:
    return {_normalise(h) for h in _HANDLE.findall(text)}


def _suggest(unknown: str, candidates: set[str], cutoff: float = SUGGESTION_CUTOFF) -> str:
    """The closest Vision spelling, or nothing at all.

    An empty suggestion is the honest answer when the program simply does not
    contain the name: inventing a near-match would be the same fabrication this
    module exists to catch.
    """
    matches = difflib.get_close_matches(
        _normalise(unknown), sorted(candidates), n=1, cutoff=cutoff)
    return matches[0] if matches else ""


def _cased_from(vision_text: str, normalised: str) -> str:
    """Recover the spelling as Vision actually printed it, for the suggestion."""
    for word in _WORD.findall(vision_text) + _HANDLE.findall(vision_text):
        if _normalise(word) == normalised:
            return word
    return normalised


def _walk_strings(node: Any, path: list[Any]):
    """Every string in the OCR payload, with the JSON path that reaches it."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield from _walk_strings(value, path + [key])
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from _walk_strings(value, path + [index])
    elif isinstance(node, str):
        yield path, node


def cross_check_against_vision(
    ocr_data: dict[str, Any],
    vision_text: str | None,
) -> list[dict[str, Any]]:
    """Flag every performer name and handle the Vision text cannot confirm.

    Returns flags in the shape `flag_issues` already produces, so they join the
    existing review loop rather than needing a surface of their own.
    """
    if not vision_text or not vision_text.strip():
        raise VisionTextUnavailable(
            "the program PDF carries no Vision text layer. It is baked at upload "
            "time, so this means the PDF is missing, was built before the text "
            "layer existed, or its async bake has not finished. Refusing to "
            "report a clean program on the strength of a check that did not run.")

    vision_words = _words(vision_text)
    vision_handles = _handles(vision_text)

    if len(vision_words) < MIN_VISION_WORDS:
        raise VisionTextUnavailable(
            f"the Vision text layer holds only {len(vision_words)} distinct "
            f"word(s), which is not a program page. Treating it as a spelling "
            f"authority would flag every correct name in the program.")

    flags: list[dict[str, Any]] = []

    def add(field_path, current, suggestion, concern, context):
        flags.append({
            "id": f"vision_{len(flags)}",
            "field_path": field_path,
            "current_value": current,
            "suggested_value": suggestion,
            "concern": concern,
            "program_context": context,
        })

    # ── performer names ───────────────────────────────────────────────────────
    for index, performer in enumerate(ocr_data.get("performers") or []):
        if not isinstance(performer, dict):
            continue
        name = (performer.get("name") or "").strip()
        if not name:
            continue

        # Per token, not per whole name. The scrambled reading order routinely
        # splits a name across lines and columns, so requiring the full string
        # would flag every correct name in a two-column program.
        missing = [
            token for token in _WORD.findall(name)
            if len(token) >= MIN_TOKEN_LENGTH and _normalise(token) not in vision_words
        ]
        if not missing:
            continue

        suggestion = _suggest(missing[0], vision_words)
        add(
            ["performers", index, "name"],
            name,
            _cased_from(vision_text, suggestion) if suggestion else "",
            f"the program's own text layer does not contain "
            f"{', '.join(repr(t) for t in missing)}",
            (f"Vision read {_cased_from(vision_text, suggestion)!r} at full "
             f"resolution" if suggestion
             else "nothing close to it appears anywhere in the program"),
        )

    # ── handles, wherever they appear ─────────────────────────────────────────
    # They have no field of their own in the schema, so they are checked
    # wherever they turn up. Matched on their exact characters rather than a
    # stem, because @safa is a different account from @safa.wav and crediting
    # one for the other is the substitution this is here to prevent.
    seen: set[str] = set()
    for path, value in _walk_strings(ocr_data, []):
        for handle in _HANDLE.findall(value):
            key = _normalise(handle)
            if key in vision_handles or key in seen:
                continue
            seen.add(key)
            suggestion = _suggest(handle, vision_handles, HANDLE_SUGGESTION_CUTOFF)
            add(
                path,
                handle,
                _cased_from(vision_text, suggestion) if suggestion else "",
                f"the program's own text layer does not contain the handle {handle}",
                (f"Vision read {_cased_from(vision_text, suggestion)!r} instead"
                 if suggestion else "no handle like it appears in the program"),
            )

    return flags
