"""The comment stripper the parity guards read Swift through (#436).

Every one of those guards asserts that a Swift declaration renders exactly a
certain way. If this returns the comments along with the code, each of them can
be satisfied by a doc comment quoting the declaration while the real constant
drifts. If it eats a string literal, the declarations it is supposed to protect
disappear and the guards fail for a reason unrelated to what they check.
"""

from __future__ import annotations

from tests.source_text import (
    swift_as_the_test_bundle_sees_it,
    swift_code_only,
    swift_without_comments,
)


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


# ---------------------------------------------------------------------------
# What the TEST BUNDLE compiles (#722)
# ---------------------------------------------------------------------------

def test_code_the_app_only_compiles_is_dropped() -> None:
    source = "let a = 1\n#if !POSTROLL_TESTS\nlet live = AppPaths.analyticsFile\n#endif\nlet b = 2\n"
    seen = swift_as_the_test_bundle_sees_it(source)
    assert "AppPaths.analyticsFile" not in seen
    assert "let a = 1" in seen and "let b = 2" in seen


def test_a_test_only_seam_is_kept() -> None:
    # The positive condition is the one that exists FOR the test bundle, so
    # dropping it would make every seam look absent (L159).
    source = "#if POSTROLL_TESTS\nlet seam = 1\n#endif\n"
    assert "let seam = 1" in swift_as_the_test_bundle_sees_it(source)


def test_the_else_branch_of_an_app_only_block_is_kept() -> None:
    source = "#if !POSTROLL_TESTS\nlet live = 1\n#else\nlet fake = 2\n#endif\n"
    seen = swift_as_the_test_bundle_sees_it(source)
    assert "let fake = 2" in seen
    assert "let live = 1" not in seen


def test_an_unrelated_condition_keeps_both_of_its_branches() -> None:
    # This is not a Swift preprocessor. Resolving a condition nobody thought
    # about would silently drop a branch and the guard would report on code that
    # does not exist.
    source = "#if DEBUG\nlet d = 1\n#else\nlet r = 2\n#endif\n"
    seen = swift_as_the_test_bundle_sees_it(source)
    assert "let d = 1" in seen and "let r = 2" in seen


def test_an_app_only_block_nested_in_another_condition_still_closes() -> None:
    source = ("#if DEBUG\nlet d = 1\n#if !POSTROLL_TESTS\nlet live = 2\n#endif\n"
              "let after = 3\n#endif\nlet last = 4\n")
    seen = swift_as_the_test_bundle_sees_it(source)
    assert "let live = 2" not in seen, "the inner block was not dropped"
    assert "let after = 3" in seen, "the wrong #endif closed the dropped block"
    assert "let last = 4" in seen


def test_lines_keep_their_positions_across_a_dropped_block() -> None:
    source = "one\n#if !POSTROLL_TESTS\ntwo\n#endif\nthree\n"
    assert len(swift_as_the_test_bundle_sees_it(source).split("\n")) == len(source.split("\n"))


# ---------------------------------------------------------------------------
# Code only, with the string fixtures blanked (#722)
# ---------------------------------------------------------------------------

def test_a_store_named_inside_a_string_fixture_is_not_code() -> None:
    # AppOwnersTests carries a Swift snippet in a multiline string as the
    # fixture for another guard. A scan looking for live-data constructions
    # matched it and named an innocent file, and a guard that fires on content
    # it exists to preserve gets turned off (L104).
    source = (
        'let innocent = """\n'
        'let hosted = SomeScreen()\n'
        '    .environment(HashtagStore())\n'
        '"""\n'
        'let real = HashtagStore(loadingSaved: false)\n'
    )
    code = swift_code_only(source)
    assert "HashtagStore()" not in code
    assert "HashtagStore(loadingSaved: false)" in code


def test_a_single_quoted_literal_is_blanked_too() -> None:
    source = 'let s = "AnalyticsStore()"\nlet t = 1\n'
    code = swift_code_only(source)
    assert "AnalyticsStore()" not in code
    assert "let t = 1" in code


def test_an_escaped_quote_does_not_end_the_literal() -> None:
    source = 'let s = "a \\" AnalyticsStore()"\nlet after = 2\n'
    code = swift_code_only(source)
    assert "AnalyticsStore()" not in code
    assert "let after = 2" in code


def test_interpolated_code_survives_because_it_runs() -> None:
    # What is inside \\(...) is real code the compiler checks, so blanking it
    # would hide a live construction sitting in a message.
    source = 'let s = "count \\(AnalyticsStore().posts.count)"\n'
    assert "AnalyticsStore()" in swift_code_only(source)


def test_code_only_keeps_the_shape_of_the_file() -> None:
    source = 'let a = 1\nlet s = """\nx\ny\n"""\nlet b = 2\n'
    assert len(swift_code_only(source).split("\n")) == len(source.split("\n"))


def test_comments_are_gone_from_code_only() -> None:
    source = 'let a = 1 // AnalyticsStore()\n'
    assert "AnalyticsStore()" not in swift_code_only(source)


def test_a_raw_literal_carries_no_interpolation() -> None:
    # AppOwnersTests holds a regex in a raw literal containing \(, which is not
    # an interpolation there. Reading it as one sent the scan looking for a
    # closing paren to the end of the file, and it then blanked nothing at all
    # while reporting cleanly.
    source = (
        'let pattern = #"\\.environment\\(\\s*\\w*Manager\\("#\n'
        'let after = HashtagStore()\n'
    )
    code = swift_code_only(source)
    assert "environment" not in code, "the raw literal's contents were read as code"
    assert "HashtagStore()" in code, (
        "everything after the raw literal stopped being seen, so a guard reading "
        "this file would report it clean whatever it contained"
    )


def test_a_raw_literal_ends_only_at_its_own_hash_count() -> None:
    source = 'let a = ##"a "# still inside"##\nlet b = 2\n'
    code = swift_code_only(source)
    assert "still inside" not in code
    assert "let b = 2" in code
