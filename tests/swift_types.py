"""A structural read of the Swift type declarations in this app (#1022).

Not a Swift parser, and not trying to be. It answers three questions and
refuses when it cannot: which types a file declares (including the extensions
that carry half of them), which stored properties and coding keys each one has,
and what is inside a named function on one of them.

Separate from the guards that use it because the brace walking is the part
worth getting right once. Every reader strips comments first through
`source_text`, since a guard that can be satisfied by a doc comment quoting the
declaration is indistinguishable from one that works (L103).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from source_text import code_of

#: A type declaration or an extension of one. `extension` is here because half
#: the Codable conformances in this app live in one: `struct Event { ... }` in
#: one place and `extension Event: Codable { init(from:) ... }` in another, so a
#: reader that only knows about the `struct` sees a type with no decoder and a
#: decoder belonging to nothing.
DECLARATION = re.compile(
    r"(?m)^[ \t]*(?:@\w+\s+)*(?:public |private |fileprivate |internal |)"
    r"(?:final )?(struct|class|enum|extension)\s+([A-Za-z_][\w.]*)")

#: A stored property declared directly on a type. Excludes `static`, which is
#: not encoded, and anything computed, which is filtered separately.
STORED_PROPERTY = re.compile(
    r"(?m)^[ \t]*(?:@\w+\s+)*(?:public |private |fileprivate |internal |)"
    r"(?:lazy )?(var|let)\s+([A-Za-z_]\w*)\s*(:|=)")

#: Deliberately NOT anchored to the start of a line. Four of these enums are
#: written on one line (`enum CodingKeys: String, CodingKey { case file, reason }`),
#: and a line anchored pattern read them as an enum with no cases, which is
#: indistinguishable from a type that encodes nothing (L215).
CODING_KEY_CASE = re.compile(r"case\s+([^\n}]+)")


@dataclass
class Block:
    """One brace-delimited region, and what declared it."""
    kind: str
    name: str
    open_index: int
    close_index: int

    def contains(self, index: int) -> bool:
        return self.open_index < index < self.close_index

    @property
    def size(self) -> int:
        return self.close_index - self.open_index


@dataclass
class SwiftType:
    """Every block in one file that declares or extends one named type."""
    name: str
    blocks: list[Block] = field(default_factory=list)


def _matching_brace(text: str, open_index: int) -> int | None:
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return None


def blocks_in(text: str) -> list[Block]:
    """Every type declaration and extension in `text`, innermost included."""
    found = []
    for m in DECLARATION.finditer(text):
        brace = text.find("{", m.end())
        close = _matching_brace(text, brace) if brace >= 0 else None
        if close is None:
            # Not skipped. A declaration whose braces this cannot balance means
            # the reader has lost its place in the file, and every attribution
            # after it is then wrong rather than absent. Dropping it quietly
            # would shrink the sweep and read as a file with fewer types in it,
            # which is exactly the answer a working sweep gives (L11, L215).
            raise ValueError(
                f"could not find the body of `{m.group(1)} {m.group(2)}`: the "
                f"brace walk in swift_types cannot read this file, so nothing "
                f"built on it can be trusted")
        found.append(Block(kind=m.group(1), name=m.group(2),
                           open_index=brace, close_index=close))
    return found


def depth_between(text: str, start: int, index: int) -> int:
    """Brace depth at `index`, counted from just after `start`.

    Zero means directly inside the block that opened at `start`, rather than
    inside a function, a closure or a computed property within it. Without this
    a local `let c = try decoder.container(...)` inside `init(from:)` reads as a
    stored property of the type.

    Safe to count raw braces because `code_of` has already blanked comments AND
    string contents, so there is no `{` left that the compiler would not see.
    """
    return text.count("{", start + 1, index) - text.count("}", start + 1, index)


def owner_of(blocks: list[Block], index: int) -> Block | None:
    """The INNERMOST block containing `index`.

    Innermost rather than first, because a nested type sits inside its parent's
    braces and attributing its decoder to the parent reports a type that has one
    when it does not, and hides one that does.
    """
    holding = [b for b in blocks if b.contains(index)]
    if not holding:
        return None
    return min(holding, key=lambda b: b.size)


def types_in(path: Path) -> tuple[str, list[Block], dict[str, SwiftType]]:
    """The file's stripped source, its blocks, and its types keyed by name."""
    text = code_of(path)
    blocks = blocks_in(text)
    types: dict[str, SwiftType] = {}
    for block in blocks:
        types.setdefault(block.name, SwiftType(block.name)).blocks.append(block)
    return text, blocks, types


def body_of_function(text: str, blocks: list[Block], signature: str,
                     owner: SwiftType) -> str | None:
    """The body of `signature` declared on `owner`, or None if it has none."""
    for m in re.finditer(re.escape(signature), text):
        holder = owner_of(blocks, m.start())
        if holder is None or holder.name != owner.name:
            continue
        if depth_between(text, holder.open_index, m.start()) != 0:
            continue
        brace = text.find("{", m.end())
        if brace < 0:
            continue
        close = _matching_brace(text, brace)
        if close is None:
            continue
        return text[brace:close]
    return None


def declares(text: str, blocks: list[Block], signature: str,
             owner: SwiftType) -> bool:
    return body_of_function(text, blocks, signature, owner) is not None


def coding_keys(text: str, blocks: list[Block], owner: SwiftType) -> list[str] | None:
    """The property names in `owner`'s own `CodingKeys`, or None if it has none.

    The NAME, not the wire key: `case photoCount = "photo_count"` is the
    property `photoCount`, which is what a decoder assigns.
    """
    for m in re.finditer(r"enum CodingKeys\b", text):
        holder = owner_of(blocks, m.start())
        if holder is None or holder.name != owner.name:
            continue
        if depth_between(text, holder.open_index, m.start()) != 0:
            continue
        brace = text.find("{", m.end())
        close = _matching_brace(text, brace) if brace >= 0 else None
        if close is None:
            continue
        names: list[str] = []
        for case in CODING_KEY_CASE.finditer(text[brace:close]):
            for part in case.group(1).split(","):
                name = part.split("=")[0].strip()
                if re.fullmatch(r"[A-Za-z_]\w*", name):
                    names.append(name)
        return names
    return None


def stored_properties(text: str, blocks: list[Block], owner: SwiftType) -> list[str]:
    """The stored properties declared directly on `owner`.

    Computed properties are excluded by looking for a `{` before the end of the
    declaration: `var isEmpty: Bool { ... }` is not encoded and must not be
    demanded of a decoder.
    """
    names: list[str] = []
    for m in STORED_PROPERTY.finditer(text):
        holder = owner_of(blocks, m.start())
        if holder is None or holder.name != owner.name:
            continue
        if depth_between(text, holder.open_index, m.start()) != 0:
            continue
        line_end = text.find("\n", m.end())
        rest = text[m.end():line_end if line_end > 0 else len(text)]
        if m.group(3) == ":" and "{" in rest and "=" not in rest.split("{")[0]:
            continue  # computed, or one with an observer, either way not a plain store
        names.append(m.group(2))
    return names
