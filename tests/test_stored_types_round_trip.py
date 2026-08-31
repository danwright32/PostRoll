"""#1022: a hand written decoder must read back everything the encoder writes.

Thirty five `init(from decoder: Decoder)` implementations across ten files rely
on the COMPILER's `encode(to:)`. The two halves of the round trip are therefore
maintained differently, and adding a stored property updates only one of them:
it compiles clean, it is written to disk, and it is never read back, so it
resets to its default on the next load with nothing failing (L317).

The loss is silent and surfaces far away as a blank value rather than as an
error, and it applies to stored event data including work that costs API calls
to produce. It is also invisible to review: the field is present in the model,
present in the CodingKeys, and simply absent from one function.

#1001 named it on the two account types and #1097 on one of them. #1008 hit the
same trap on `DayCaption` and escaped only because whoever added the field
happened to add the decoder line at the same time. So this is the class rather
than the instances (L30): every type is checked, and the next added field fails
on all of them at once rather than on the one somebody remembered.

Structural rather than a round trip in Swift, because a round trip needs a
fully populated instance of each type and there is no way to build thirty five
of those except by hand, which is a registry that checks only what somebody
remembered to list (L96).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from source_text import swift_files
from swift_types import (
    coding_keys,
    declares,
    body_of_function,
    owner_of,
    stored_properties,
    types_in,
)

REPO = Path(__file__).resolve().parent.parent
SOURCES = REPO / "PostRollApp" / "Sources"

DECODER = "init(from decoder: Decoder)"
ENCODER = "func encode(to encoder: Encoder)"


def _files() -> list[Path]:
    return [p for p in swift_files(SOURCES) if DECODER in p.read_text(encoding="utf-8")]


def hand_decoded_types() -> list[tuple[str, str]]:
    """(file name, type name) for every type with a hand written decoder."""
    found = []
    for path in _files():
        text, blocks, types = types_in(path)
        for name, swift_type in types.items():
            if declares(text, blocks, DECODER, swift_type):
                found.append((path.name, name))
    return sorted(set(found))


SUBJECTS = hand_decoded_types()


def test_the_sweep_actually_found_the_decoders():
    # A sweep that came out empty passes every case below while checking
    # nothing (L98). The count is a floor rather than an exact number so
    # adding a type is not a failure, but losing half of them is.
    assert len(SUBJECTS) >= 25, f"only found {SUBJECTS}"


def test_every_decoder_in_the_tree_belongs_to_a_type_this_sweep_checks():
    """No decoder may be invisible to the rule.

    A decoder the walker cannot attribute is exempt from the check written to
    catch it, and it is exempt silently, which is the shape of guard that reads
    as protection while protecting nothing (L96, L320). Half of these live in
    `extension Event: Codable` rather than in the `struct`, so a reader that
    only knew about type declarations would miss thirteen of them and still
    report a clean sweep.
    """
    for path in _files():
        text, blocks, types = types_in(path)
        checked = {name for name, t in types.items()
                   if declares(text, blocks, DECODER, t)}
        for m in re.finditer(re.escape(DECODER), text):
            holder = owner_of(blocks, m.start())
            assert holder is not None, (
                f"{path.name}: a decoder at offset {m.start()} is inside no type "
                f"this sweep can name, so nothing checks it")
            assert holder.name in checked, (
                f"{path.name}: the decoder on {holder.name} is not attributed to "
                f"a type this sweep checks")


@pytest.mark.parametrize("file_name,type_name", SUBJECTS,
                         ids=lambda v: v if isinstance(v, str) else str(v))
def test_a_hand_written_decoder_reads_every_field_the_encoder_writes(file_name, type_name):
    path = next(p for p in _files() if p.name == file_name)
    text, blocks, types = types_in(path)
    swift_type = types[type_name]

    if declares(text, blocks, ENCODER, swift_type):
        pytest.skip("both halves are written by hand, so neither can drift alone")

    # What the SYNTHESIZED encoder will write. An explicit `CodingKeys` is the
    # authority when there is one: a property left out of it is deliberately not
    # persisted and must not be demanded of the decoder. Without one, every
    # stored property is encoded.
    keys = coding_keys(text, blocks, swift_type)
    if keys is not None:
        assert keys, (
            f"{type_name} declares a CodingKeys this could not read a single case "
            f"out of. An enum that parsed as empty is indistinguishable from a "
            f"type that encodes nothing, and it would exempt itself from the "
            f"whole rule (L215).")
    expected = keys if keys is not None else stored_properties(text, blocks, swift_type)

    body = body_of_function(text, blocks, DECODER, swift_type)
    assert body is not None

    if not expected:
        # A type with nothing keyed to miss: an enum decoded straight out of a
        # single value container. `self = ...` replaces the whole value, so
        # there is no field a later addition could leave behind. Asserted
        # rather than assumed, because "no fields found" is otherwise the same
        # answer as "this reader could not see them" (L11).
        assert re.search(r"\bself\s*=", body), (
            f"{type_name} has a hand written decoder, no CodingKeys, no stored "
            f"properties this could find, and does not assign `self`, so this "
            f"case passes without checking anything")
        return

    missing = [name for name in expected
               if not re.search(rf"\b(?:self\.)?{re.escape(name)}\s*=", body)]
    assert not missing, (
        f"{file_name}: {type_name} encodes {missing} and never reads {'it' if len(missing) == 1 else 'them'} "
        f"back. The compiler writes the field, the hand written decoder ignores "
        f"it, and it resets to its default on the next load with nothing "
        f"failing. Either assign it in `init(from:)` or take it out of "
        f"CodingKeys so it is not written either (#1022, L317).")
