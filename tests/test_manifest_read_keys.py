"""Tests for the manifest READ extractor (#266).

The mirror of the payload-key extractor. That one answers "which keys does
Python write"; this one answers "which keys does Python read out of a manifest
the app sent". Same discipline: it must refuse rather than under-report, because
a short read set agrees with any sender, which is exactly the case the guard
exists to catch.
"""

from __future__ import annotations

import textwrap

import pytest

from bridge_payload_keys import UndeterminedKey, manifest_reads_from_source


def _reads(src: str, **kwargs) -> set[str]:
    return manifest_reads_from_source(textwrap.dedent(src), **kwargs)


class TestFindingReads:

    def test_it_finds_get_with_a_default(self):
        assert _reads(
            '''
            def run(manifest):
                a = manifest.get("event_url", "")
                b = manifest.get("preset")
            ''',
            function="run", variable="manifest",
        ) == {"event_url", "preset"}

    def test_it_finds_required_subscripts(self):
        assert _reads(
            '''
            def run(manifest):
                e = manifest["event"]
                v = manifest["venue"]
            ''',
            function="run", variable="manifest",
        ) == {"event", "venue"}

    def test_it_finds_reads_on_a_nested_variable(self):
        # The per-day dict is pulled out of the manifest and read separately, so
        # its keys are part of the same contract.
        assert _reads(
            '''
            def run(manifest):
                day_info = manifest.get("days", {})
                photos = day_info.get("photos", [])
                notes = day_info.get("notes")
            ''',
            function="run", variable="day_info",
        ) == {"photos", "notes"}

    def test_it_ignores_reads_on_other_variables(self):
        assert _reads(
            '''
            def run(manifest, other):
                a = manifest.get("mine")
                b = other.get("theirs")
            ''',
            function="run", variable="manifest",
        ) == {"mine"}

    def test_it_ignores_writes(self):
        # A manifest is read-only on this side; a subscript ASSIGNMENT is not a
        # read and counting it would put a key in the contract nobody sends.
        assert _reads(
            '''
            def run(manifest):
                manifest["scratch"] = 1
                a = manifest["real"]
            ''',
            function="run", variable="manifest",
        ) == {"real"}

    def test_it_reads_the_whole_function_including_branches(self):
        assert _reads(
            '''
            def run(manifest):
                if manifest.get("friday"):
                    x = manifest["clips"]
                else:
                    x = manifest["photos"]
            ''',
            function="run", variable="manifest",
        ) == {"friday", "clips", "photos"}


class TestItRefusesToGuess:

    def test_a_computed_key_raises(self):
        with pytest.raises(UndeterminedKey, match="day_name"):
            _reads(
                '''
                def run(manifest):
                    x = manifest.get(day_name)
                ''',
                function="run", variable="manifest",
            )

    def test_a_computed_subscript_raises(self):
        with pytest.raises(UndeterminedKey):
            _reads(
                '''
                def run(manifest):
                    x = manifest[key]
                ''',
                function="run", variable="manifest",
            )

    def test_a_declared_dynamic_key_expands(self):
        assert _reads(
            '''
            def run(manifest):
                x = manifest.get(day_name)
                y = manifest["event"]
            ''',
            function="run", variable="manifest",
            dynamic={"day_name": ["sunday", "monday"]},
        ) == {"sunday", "monday", "event"}

    def test_a_missing_function_raises(self):
        with pytest.raises(LookupError, match="absent"):
            _reads('def run(m): return m["a"]', function="nope", variable="m")

    def test_a_variable_that_is_never_read_raises(self):
        # A typo'd variable name yields an empty set, and an empty read set
        # agrees with every sender.
        with pytest.raises(LookupError, match="no keys"):
            _reads(
                '''
                def run(manifest):
                    return 1
                ''',
                function="run", variable="manifest",
            )
