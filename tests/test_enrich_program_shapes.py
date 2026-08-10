"""The enrichment payloads have a shape in code, not only in a prompt (#273).

`fetch_performers_from_url`, `suggest_handles` and `fetch_piece_notes` returned
Claude's JSON array through untouched. Their field names existed only inside the
prompt text, so the app's decoders were hoping for `profile_url` and would take
an empty string for any field Claude named differently, silently, on a path
whose whole job is to fill in facts about real people.

A rule that lives only in a prompt is a hope (L27). These normalise at the
boundary instead, which also gives the key contract something to read.
"""

from __future__ import annotations

import pytest

from postroll.ai import enrich_program as ep


class TestPerformers:
    """Who was on stage. A different lookup from where to find them online, and
    a different shape: conflating the two is a mistake this suite exists to make
    impossible to ship."""

    def test_it_keeps_the_fields_the_app_decodes(self):
        out = ep._normalise_performers([{
            "name": "A Singer", "role": "soloist", "voice_or_instrument": "Soprano",
        }])
        assert out == [{"name": "A Singer", "role": "soloist",
                        "voice_or_instrument": "Soprano"}]

    def test_every_entry_carries_every_key_even_when_claude_omits_them(self):
        # The app reads by key. A missing key and an empty one are the same to
        # it, but only one of them is a shape it can rely on.
        out = ep._normalise_performers([{"name": "A Singer"}])
        assert set(out[0]) == {"name", "role", "voice_or_instrument"}

    def test_an_entry_with_no_name_is_dropped(self):
        # A performer with no name cannot be credited, matched or tagged, so it
        # is not a performer. Keeping it would put a blank row in front of Dan.
        assert ep._normalise_performers([{"role": "soloist"}, {"name": "Real"}]) \
            == [{"name": "Real", "role": "other", "voice_or_instrument": None}]

    def test_an_unstated_role_becomes_other_rather_than_a_guess(self):
        # The role drives how someone is credited, so inventing "soloist" would
        # put a claim in a caption that nothing supports.
        assert ep._normalise_performers([{"name": "X"}])[0]["role"] == "other"

    def test_a_non_dict_entry_is_dropped_rather_than_crashing(self):
        assert ep._normalise_performers(["just a string", {"name": "X"}]) == \
            [{"name": "X", "role": "other", "voice_or_instrument": None}]

    def test_fields_are_trimmed(self):
        assert ep._normalise_performers([{"name": "  A Singer  "}])[0]["name"] == "A Singer"

    def test_it_does_not_produce_the_handle_suggestion_shape(self):
        # The two lookups return different things and are decoded into different
        # models. Returning one where the other is expected drops every field
        # silently, because both decoders tolerate anything missing.
        out = ep._normalise_performers([{"name": "X", "handle": "@x"}])[0]
        assert "handle" not in out and "confidence" not in out


class TestHandleSuggestions:

    def test_it_keeps_the_fields_the_app_decodes(self):
        out = ep._normalise_handle_suggestions([{
            "name": "A Singer", "handle": "@singer",
            "profile_url": "https://instagram.com/singer",
            "confidence": "medium", "note": "bio matches",
        }])
        assert set(out[0]) == {"name", "handle", "profile_url", "confidence", "note"}
        assert out[0]["confidence"] == "medium"

    def test_a_suggestion_with_no_name_is_dropped(self):
        # The name is what the suggestion is matched back against; without it
        # there is nothing to apply it to.
        assert ep._normalise_handle_suggestions([{"handle": "@x"}]) == []

    def test_a_not_found_result_survives_as_a_real_answer(self):
        # "no account exists" is a finding, not a failure, and dropping it would
        # make Dan search again for someone already searched for.
        out = ep._normalise_handle_suggestions([
            {"name": "A Singer", "handle": None, "confidence": "low", "note": "not found"}])
        assert out[0]["handle"] is None
        assert out[0]["note"] == "not found"


class TestPieceNotes:

    def test_it_keeps_the_fields_the_app_decodes(self):
        out = ep._normalise_piece_notes([
            {"title": "A Work", "composer": "A Composer", "notes": "written in 1899"}])
        assert out == [{"title": "A Work", "composer": "A Composer", "notes": "written in 1899"}]

    def test_every_entry_carries_every_key(self):
        assert set(ep._normalise_piece_notes([{"title": "A Work"}])[0]) \
            == {"title", "composer", "notes"}

    def test_an_entry_with_no_title_is_dropped(self):
        # The title is how a note is matched back to a piece in the programme.
        assert ep._normalise_piece_notes([{"notes": "orphaned"}]) == []

    def test_a_piece_with_no_note_found_is_kept(self):
        # Keeping it records that the lookup happened and found nothing, which
        # is what stops the same piece being looked up again.
        assert ep._normalise_piece_notes([{"title": "A Work"}])[0]["notes"] is None


class TestDiscardsAreVisible:
    """A filter that throws data away has to say so.

    These drop entries that cannot be used, which is right, but a lookup that
    quietly returns half-formed results then looks exactly like a thin
    programme. Dan would have no way to tell "this event has three performers"
    from "seven came back and four were unusable", and the second is worth
    knowing before he pays for the lookup again.
    """

    def test_dropped_performers_are_counted_and_named(self, capsys):
        ep._normalise_performers([{"name": "Real"}, {"role": "soloist"}, {"bad": 1}])
        err = capsys.readouterr().err
        assert "2" in err
        assert "performer" in err.lower()

    def test_dropped_handle_suggestions_are_counted(self, capsys):
        ep._normalise_handle_suggestions([{"name": "Real"}, {"handle": "@orphan"}])
        assert "1" in capsys.readouterr().err

    def test_dropped_piece_notes_are_counted(self, capsys):
        ep._normalise_piece_notes([{"title": "A Work"}, {"notes": "orphaned"}])
        assert "1" in capsys.readouterr().err

    def test_a_clean_response_says_nothing(self, capsys):
        # A line on every run is a line nobody reads by the time it matters.
        ep._normalise_performers([{"name": "A"}, {"name": "B"}])
        ep._normalise_piece_notes([{"title": "A Work"}])
        assert capsys.readouterr().err == ""

    def test_an_empty_response_says_nothing(self, capsys):
        # Nothing came back, so nothing was discarded. Reporting a drop here
        # would point at the wrong problem.
        ep._normalise_performers([])
        assert capsys.readouterr().err == ""

    def test_it_reports_rather_than_raising(self, capsys):
        # A partly usable answer is still an answer. Refusing it would throw
        # away the entries that were fine.
        out = ep._normalise_performers([{"name": "Real"}, {"role": "soloist"}])
        assert len(out) == 1
        assert capsys.readouterr().err != ""


def test_the_two_lookups_keep_distinct_shapes():
    # Named explicitly because they were once the same function by mistake.
    same = [{"name": "X", "role": "soloist", "handle": "@x"}]
    assert set(ep._normalise_performers(same)[0]) \
        != set(ep._normalise_handle_suggestions(same)[0])


@pytest.mark.parametrize("fn", [ep._normalise_performers,
                                ep._normalise_handle_suggestions,
                                ep._normalise_piece_notes])
def test_an_empty_response_is_empty_not_an_error(fn):
    assert fn([]) == []
