"""Read Swift source the way a compiler does, not the way a reader does (#436).

Five Python-to-Swift parity guards asserted the exact rendering of a
declaration in raw source text. Every one of them could be satisfied by a
comment: a doc comment quoting the old declaration keeps the guard green while
the real constant drifts, and for the guards that split on a marker, a comment
containing the marker hijacks which text gets checked. A guard that is green on
prose is indistinguishable from one that works (L103), and it can even be
satisfied by a comment explaining that the thing it checks was removed.

The repo already knew this: `VisibleRefusalGuardTests` and
`DiscardedFileWriteGuardTests` strip comments for exactly this reason, and two
guards carry not-satisfied-by-a-comment mutation entries. This family had never
been swept, so the stripping lives here once rather than being copied into five
files where it can drift (L41).

Comment text is blanked rather than deleted, so line numbers and the shape of
the file survive: a guard that splits on a marker and reads to the end of the
line still reads the same line.
"""

from __future__ import annotations


def swift_without_comments(source: str) -> str:
    """`source` with every Swift comment blanked out.

    Handles `//` to end of line, `/* */` blocks including Swift's nesting, and
    leaves string literals alone: a `//` inside `"https://..."` is not a
    comment, and blanking it would corrupt the very declarations these guards
    read.
    """
    out: list[str] = []
    i = 0
    n = len(source)
    depth = 0          # open /* */ nesting
    in_string = False

    while i < n:
        char = source[i]
        pair = source[i:i + 2]

        if depth > 0:
            if pair == "/*":
                depth += 1
                out.append("  ")
                i += 2
                continue
            if pair == "*/":
                depth -= 1
                out.append("  ")
                i += 2
                continue
            # Newlines survive so the file keeps its shape.
            out.append("\n" if char == "\n" else " ")
            i += 1
            continue

        if in_string:
            out.append(char)
            if char == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if char == '"':
                in_string = False
            elif char == "\n":
                # An unterminated literal ends at the newline rather than
                # swallowing the rest of the file.
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            out.append(char)
            i += 1
            continue

        if pair == "//":
            while i < n and source[i] != "\n":
                out.append(" ")
                i += 1
            continue

        if pair == "/*":
            depth = 1
            out.append("  ")
            i += 2
            continue

        out.append(char)
        i += 1

    return "".join(out)
