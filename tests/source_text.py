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


# The compilation condition project.yml sets on the TEST target only, so a seam
# compiled behind it cannot be reached from the shipping app.
TEST_ONLY_CONDITION = "POSTROLL_TESTS"


def swift_as_the_test_bundle_sees_it(source: str) -> str:
    """`source` with the code the test bundle does not compile blanked out.

    A guard about what a TEST can reach has to read the source the way the test
    target's compiler does, not the way the file reads (#722). `AnalyticsStore`
    keeps the initializer that names Dan's live analytics file behind
    `#if !POSTROLL_TESTS`, so a test omitting the path is a build error rather
    than a silent read of live data. A guard reading the raw file would find
    that initializer, see a live default, and fail on code the test bundle never
    compiles.

    Only conditions on `POSTROLL_TESTS` are resolved. Every other `#if` is left
    alone, including its directives, because this is not a Swift preprocessor
    and pretending otherwise would quietly drop a branch on some condition
    nobody thought about. Nesting of other `#if`s inside a resolved block is
    tracked, so the right `#endif` closes it.

    Blanked rather than deleted, so line numbers survive and a guard can name
    the line it objected to.
    """
    kept: list[str] = []
    # One frame per open `#if`: whether the lines inside it are compiled into the
    # test bundle, and whether the condition is one this resolves at all. An
    # unrelated condition keeps BOTH of its branches, so `#else` must not flip
    # it: doing that dropped the else branch of every `#if DEBUG` in the file.
    stack: list[tuple[bool, bool]] = []

    for line in source.splitlines(keepends=True):
        stripped = line.strip()
        directive = stripped.startswith("#if") or stripped.startswith("#else") \
            or stripped.startswith("#elseif") or stripped.startswith("#endif")

        if stripped.startswith("#if"):
            condition = stripped[len("#if"):].strip()
            if condition == TEST_ONLY_CONDITION:
                stack.append((True, True))
            elif condition == f"!{TEST_ONLY_CONDITION}":
                stack.append((False, True))
            else:
                # Not ours: everything inside stays as written.
                stack.append((True, False))
        elif stripped.startswith("#else") and stack:
            compiled_here, ours = stack[-1]
            stack[-1] = (not compiled_here if ours else True, ours)
        elif stripped.startswith("#endif") and stack:
            stack.pop()

        compiled = all(frame for frame, _ in stack)
        # A directive line is never code, so it is blanked either way rather
        # than left for a guard to trip over.
        kept.append("\n" if (directive or not compiled) and line.endswith("\n")
                    else ("" if (directive or not compiled) else line))

    return "".join(kept)


def swift_without_string_literals(source: str) -> str:
    """`source` with the contents of every string literal blanked.

    A guard looking for a CONSTRUCTION in code has to ignore the same
    construction written inside a string. `AppOwnersTests` keeps a Swift snippet
    in a multiline literal as another guard's fixture, and the #722 scan named
    that file as reaching live data. A guard that fires on the content it exists
    to preserve is one that gets turned off (L104).

    Interpolations are KEPT, because `\\(AnalyticsStore().posts.count)` is real
    code the compiler checks, and blanking it would hide a live construction
    sitting inside a message.

    Raw literals (`#"..."#`) carry no escapes and no interpolations, and reading
    one as if it did is what broke the first version of this: the regex in
    `AppOwnersTests` contains `\\(`, which was taken for an interpolation, and
    the scan then ran to the end of the file looking for a closing paren and
    blanked nothing at all. Nothing failed loudly; the guard simply stopped
    seeing that file.

    Newlines survive so line numbers still point at the right place.
    """
    out: list[str] = []
    i = 0
    n = len(source)

    def blank(text: str) -> str:
        return "".join("\n" if c == "\n" else " " for c in text)

    def opener(at: int) -> tuple[int, str] | None:
        """The literal starting at `at`, as (hash count, quote run), or None."""
        j = at
        while j < n and source[j] == "#":
            j += 1
        hashes = j - at
        if source[j:j + 3] == '"""':
            return hashes, '"""'
        if source[j:j + 1] == '"':
            return hashes, '"'
        return None

    while i < n:
        found = opener(i) if (source[i] == '"' or source[i] == "#") else None
        if found is None:
            out.append(source[i])
            i += 1
            continue

        hashes, quote = found
        raw = hashes > 0
        closer = quote + "#" * hashes
        out.append(blank(source[i:i + hashes + len(quote)]))
        i += hashes + len(quote)
        chunk = i

        while i < n:
            if source[i:i + len(closer)] == closer:
                break
            if not raw and source[i:i + 2] == "\\(":
                # Real code inside the literal: kept, parens balanced.
                out.append(blank(source[chunk:i]))
                depth = 0
                j = i + 1
                while j < n:
                    if source[j] == "(":
                        depth += 1
                    elif source[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                out.append(source[i:j + 1])
                i = chunk = j + 1
                continue
            if not raw and source[i] == "\\":
                i += 2
                continue
            if quote == '"' and source[i] == "\n":
                # An unterminated single-line literal must not swallow the rest
                # of the file, the same way the comment stripper refuses to.
                break
            i += 1

        out.append(blank(source[chunk:i]))
        if source[i:i + len(closer)] == closer:
            out.append(blank(closer))
            i += len(closer)

    return "".join(out)


def swift_code_only(source: str) -> str:
    """`source` with comments and string contents blanked: what the code DOES.

    The reading a guard about constructions, calls or declarations wants. Either
    half alone leaves a way to satisfy or trip the guard with prose: a comment
    quoting a declaration (#436) or a snippet inside a test fixture (#722).
    """
    return swift_without_string_literals(swift_without_comments(source))
