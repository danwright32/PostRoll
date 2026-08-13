"""The comment stripper the parity guards read Swift through (#436).

Every one of those guards asserts that a Swift declaration renders exactly a
certain way. If this returns the comments along with the code, each of them can
be satisfied by a doc comment quoting the declaration while the real constant
drifts. If it eats a string literal, the declarations it is supposed to protect
disappear and the guards fail for a reason unrelated to what they check.
"""

from __future__ import annotations

from tests.source_text import swift_without_comments


def test_a_line_comment_is_gone() -> None:
    stripped = swift_without_comments("let x = 1 // static let minimumWords = 9\n")
    assert "minimumWords" not in stripped
    assert "let x = 1" in stripped


def test_a_doc_comment_quoting_a_declaration_cannot_satisfy_a_guard() -> None:
    # The exact shape of the defect: prose ABOUT the constant reading as the
    # constant.
    source = (
        "/// Mirrors Python. Was `static let minimumWords = 9` before #209.\n"
        "static let minimumWords = 12\n"
    )
    stripped = swift_without_comments(source)
    assert "static let minimumWords = 9" not in stripped
    assert "static let minimumWords = 12" in stripped


def test_a_block_comment_is_gone_and_nesting_is_followed() -> None:
    source = "let a = 1 /* outer /* inner */ still comment */ let b = 2\n"
    stripped = swift_without_comments(source)
    assert "still comment" not in stripped
    assert "let a = 1" in stripped and "let b = 2" in stripped


def test_a_double_slash_inside_a_string_survives() -> None:
    # Blanking this would corrupt the declarations these guards read.
    source = 'static let site = "https://dwphoto.ny"\n'
    assert swift_without_comments(source) == source


def test_an_escaped_quote_does_not_end_the_string() -> None:
    source = 'let quoted = "she said \\"no // yes\\"" // trailing\n'
    stripped = swift_without_comments(source)
    assert 'she said \\"no // yes\\"' in stripped
    assert "trailing" not in stripped


def test_lines_keep_their_positions() -> None:
    # Guards split on a marker and read to the end of that line, so the file
    # has to keep its shape rather than closing up.
    source = "one\n// two\nthree\n"
    assert len(swift_without_comments(source).split("\n")) == len(source.split("\n"))


def test_the_marker_hijack_is_closed() -> None:
    # The other half of #436: a comment carrying the marker used to decide
    # which text a split-on-marker guard read, so the guard measured the
    # comment and never reached the declaration.
    source = (
        "// static let collageDesignVersion = 1 (the old one)\n"
        "static let collageDesignVersion = 7\n"
    )
    marker = "static let collageDesignVersion = "
    stripped = swift_without_comments(source)
    assert stripped.split(marker, 1)[1].split("\n", 1)[0].strip() == "7"


def test_an_unterminated_literal_does_not_swallow_the_file() -> None:
    source = 'let broken = "oops\nstatic let after = 3\n'
    assert "static let after = 3" in swift_without_comments(source)


def test_real_swift_comes_back_unchanged_where_it_has_no_comments() -> None:
    source = 'enum A {\n    static let n = 4\n}\n'
    assert swift_without_comments(source) == source
