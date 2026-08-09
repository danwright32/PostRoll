"""#121: the JSON extractor must not count braces inside strings.

When a response is not pure JSON, the extractor walks from the first `{` and
counts depth to find the matching `}`. It counted every brace it saw, including
ones inside string values, so a caption containing a `}` closed the object
early and a `{` left it open to the end.

That is not a hypothetical for this app. Captions and blog bodies are prose
Claude wrote, and prose about a programme can contain a stray bracket. The
failure is also the bad kind: it does not raise, it returns a SHORTER object
that parses, so a caption comes back with fields silently missing.

Every case below is a real response shape: a JSON object wrapped in a sentence
of explanation, which is what the model does when it decides the request
deserved a comment.
"""

from __future__ import annotations

import pytest

from postroll.ai.claude_client import ClaudeError, _extract_json


# ── the reported defect ───────────────────────────────────────────────────────

def test_a_closing_brace_inside_a_string_does_not_end_the_object():
    text = ('Here is the caption you asked for:\n'
            '{"caption": "The set list read like a joke }", "hashtags": ["#a"]}\n'
            'Let me know if you want another.')

    data = _extract_json(text)

    assert data["caption"] == "The set list read like a joke }"
    assert data["hashtags"] == ["#a"], "the fields after the stray brace survive"


def test_an_opening_brace_inside_a_string_does_not_leave_it_open():
    text = ('Sure:\n'
            '{"caption": "A programme note opened with { and never closed", '
            '"hashtags": []}\n'
            'That is the whole caption.')

    data = _extract_json(text)

    assert data["hashtags"] == []


def test_a_bracket_inside_a_string_does_not_break_an_array():
    text = ('Result:\n'
            '[{"alt": "Two players, one seated ] one standing"}]\n'
            'Done.')

    data = _extract_json(text)

    assert data[0]["alt"] == "Two players, one seated ] one standing"


def test_an_escaped_quote_does_not_end_the_string():
    # A caption quoting a work title carries escaped quotes, and treating the
    # escaped one as the end of the string puts the walker back into
    # brace-counting mode in the middle of prose.
    text = ('Here:\n'
            r'{"caption": "They closed with \"Odyssey }\" and left", "hashtags": []}'
            '\nAnything else?')

    data = _extract_json(text)

    assert data["caption"] == 'They closed with "Odyssey }" and left'


def test_a_backslash_before_the_closing_quote_is_handled():
    text = r'Text: {"caption": "ends with a backslash \\", "hashtags": []} end'

    data = _extract_json(text)

    assert data["caption"] == "ends with a backslash \\"
    assert data["hashtags"] == []


# ── what already worked must keep working ─────────────────────────────────────

def test_plain_json_is_still_parsed():
    assert _extract_json('{"a": 1}') == {"a": 1}


def test_a_fenced_block_is_still_unwrapped():
    assert _extract_json('```json\n{"a": 1}\n```') == {"a": 1}


def test_an_array_response_is_still_parsed():
    assert _extract_json('[1, 2, 3]') == [1, 2, 3]


def test_json_wrapped_in_ordinary_prose_is_still_found():
    text = 'Here you go:\n{"caption": "no funny business", "hashtags": []}\nBye.'

    assert _extract_json(text)["caption"] == "no funny business"


def test_a_nested_object_is_still_walked_to_its_real_end():
    text = 'Result: {"outer": {"inner": {"deep": 1}}, "after": 2} done'

    data = _extract_json(text)

    assert data["after"] == 2, "the walker must not stop at the first nested close"


def test_a_response_with_no_json_still_raises():
    with pytest.raises(ClaudeError):
        _extract_json("I could not do that, sorry.")


def test_an_unterminated_object_still_raises():
    # Better a loud failure than a truncated object that parses.
    with pytest.raises(ClaudeError):
        _extract_json('Here: {"caption": "cut off mid')


def test_the_error_shows_what_came_back():
    # A parse failure with no sight of the response is undiagnosable.
    with pytest.raises(ClaudeError) as e:
        _extract_json("total nonsense from the model")

    assert "total nonsense" in str(e.value)
