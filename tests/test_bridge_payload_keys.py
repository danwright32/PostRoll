"""Tests for the payload-key extractor itself (#262).

The extractor is the detector the contract guard depends on. A detector that
silently returns fewer keys than the code really writes would let the guard
pass for exactly the case it exists to catch, so it is tested against sources
whose answer is known by hand, including the shapes where it must REFUSE
rather than guess.
"""

from __future__ import annotations

import textwrap

import pytest

from bridge_payload_keys import DynamicKey, UndeterminedKey, payload_keys_from_source


def _keys(src: str, **kwargs) -> set[str]:
    return payload_keys_from_source(textwrap.dedent(src), **kwargs)


class TestReturnedDictLiterals:

    def test_it_reads_the_keys_of_a_returned_dict_literal(self):
        assert _keys(
            '''
            def build():
                return {"title": t, "body": b, "photo_count": n}
            ''',
            function="build",
        ) == {"title", "body", "photo_count"}

    def test_it_unions_every_return_in_the_function(self):
        # An early return carrying a different shape is still part of what this
        # payload can contain, so a consumer has to know about both.
        assert _keys(
            '''
            def build():
                if quick:
                    return {"index": 0, "path": p}
                return {"index": i, "path": p, "rationale": r}
            ''',
            function="build",
        ) == {"index", "path", "rationale"}

    def test_it_ignores_returns_belonging_to_a_nested_function(self):
        assert _keys(
            '''
            def build():
                def helper():
                    return {"not_mine": 1}
                return {"mine": 1}
            ''',
            function="build",
        ) == {"mine"}


class TestSubscriptAssignment:

    def test_it_reads_keys_assigned_onto_a_named_payload_variable(self):
        assert _keys(
            '''
            def build(out):
                out["cover"] = path
                out["cover_pick"] = pick
            ''',
            function="build",
            variable="out",
        ) == {"cover", "cover_pick"}

    def test_it_ignores_assignments_onto_a_different_variable(self):
        assert _keys(
            '''
            def build(out):
                out["mine"] = 1
                other["theirs"] = 2
            ''',
            function="build",
            variable="out",
        ) == {"mine"}

    def test_it_reads_keys_from_a_dict_literal_assigned_to_the_variable(self):
        assert _keys(
            '''
            def build():
                out = {"posts": p, "warnings": w}
                return out
            ''',
            function="build",
            variable="out",
        ) == {"posts", "warnings"}


class TestItRefusesToGuess:
    """The failure mode that matters most.

    An extractor that shrugs at a key it cannot read reports a smaller set than
    the code writes, and the guard then certifies a payload it never saw in
    full. Every one of these must raise rather than return.
    """

    def test_a_non_constant_subscript_key_raises_unless_declared(self):
        with pytest.raises(UndeterminedKey, match="day_name"):
            _keys(
                '''
                def build(out):
                    out[day_name] = None
                ''',
                function="build",
                variable="out",
            )

    def test_a_declared_dynamic_key_expands_to_its_values(self):
        assert _keys(
            '''
            def build(out):
                out[day_name] = None
                out["errors"] = e
                ''',
            function="build",
            variable="out",
            dynamic={"day_name": DynamicKey(values=["sunday", "monday"])},
        ) == {"sunday", "monday", "errors"}

    def test_a_dict_literal_with_a_computed_key_raises(self):
        with pytest.raises(UndeterminedKey):
            _keys(
                '''
                def build():
                    return {name: 1, "known": 2}
                ''',
                function="build",
            )

    def test_a_splatted_dict_raises_because_its_keys_are_elsewhere(self):
        with pytest.raises(UndeterminedKey):
            _keys(
                '''
                def build():
                    return {**base, "known": 2}
                ''',
                function="build",
            )

    def test_a_missing_function_raises_rather_than_returning_nothing(self):
        # An empty set from a typo'd name would read as "this payload writes
        # nothing", which every comparison passes.
        with pytest.raises(LookupError, match="absent"):
            _keys('def build(): return {"a": 1}', function="nope")

    def test_a_variable_that_is_never_written_raises(self):
        with pytest.raises(LookupError, match="out"):
            _keys(
                '''
                def build():
                    return {"a": 1}
                ''',
                function="build",
                variable="out",
            )

    def test_a_source_that_yields_no_keys_at_all_raises(self):
        # The worst answer this can give, because zero keys agrees with every
        # consumer. It happens for real: a payload built inline inside a call
        # (`write_text(json.dumps({...}))`) is read by neither the return path
        # nor the assignment path, and the guard would have certified it while
        # seeing none of it.
        with pytest.raises(LookupError, match="no keys"):
            _keys(
                '''
                def build():
                    write(dumps({"png": p, "layout": l}))
                ''',
                function="build",
            )

    def test_a_declared_dynamic_name_that_is_never_used_raises(self):
        # Otherwise a stale declaration keeps injecting keys the code stopped
        # writing, and the contract drifts in the direction nothing checks.
        with pytest.raises(LookupError, match="day_name"):
            _keys(
                '''
                def build(out):
                    out["errors"] = e
                ''',
                function="build",
                variable="out",
                dynamic={"day_name": DynamicKey(values=["sunday"])},
            )
