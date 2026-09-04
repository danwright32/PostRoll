"""#1195: the evidence for letting the fetch write NO_SUCH_ACCOUNT.

`allow_no_such_account` is off, and rightly. The verdict is TERMINAL: nothing
ever asks about that account again, so a wrong one is unrecoverable by design
and invisible afterwards, and one observe cycle producing one absent verdict
cannot calibrate that (L248).

What was missing is the evidence itself. `would_have_been` was set on every
cycle and read by nobody, so the one observation from 2026-09-01 survived only
as a sentence in the issue. Stored data needs a reader (L46).

These hold the reader to being honest about how far along it is, and to never
answering "ready" on a sample that cannot support the decision.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from check_no_such_account_calibration import (  # noqa: E402
    CYCLES_WANTED, NEW_HANDLES_WANTED, main, observations, verdict)


def cycle(*, absent=1, new=NEW_HANDLES_WANTED, asked=122, on="2026-09-01"):
    return {
        "measured_on": on,
        "asked": asked,
        "outcomes": {"measured": asked - absent},
        "would_have_been": {"no_such_account": absent} if absent else {},
        "new_since_last": new,
    }


def test_one_cycle_is_not_enough():
    ready, why = verdict([cycle()])

    assert not ready
    assert any("cycle" in reason for reason in why)


def test_enough_cycles_on_a_moving_population_is_ready():
    ready, why = verdict([cycle(new=None)] + [cycle() for _ in range(CYCLES_WANTED - 1)])

    assert ready, f"the evidence #1195 asks for is recorded and it still says: {why}"


def test_the_same_population_observed_repeatedly_is_not_several_populations():
    """The issue asks for "a population that is not the same 122 handles every
    time". A population that never changes is one population observed several
    times, which is the sample size problem wearing a different hat (L354)."""
    ready, why = verdict([cycle(new=None)] + [cycle(new=0) for _ in range(CYCLES_WANTED)])

    assert not ready
    assert any("population" in reason for reason in why)


def test_cycles_with_no_absent_verdict_at_all_are_not_evidence():
    """Switching the gate on when nothing has ever been classified absent would
    change nothing while reading as a decision made on evidence (L98, L543)."""
    ready, why = verdict([cycle(new=None, absent=0)]
                         + [cycle(absent=0) for _ in range(CYCLES_WANTED)])

    assert not ready
    assert any("absent verdict" in reason for reason in why)


def test_it_never_says_ready_and_gives_a_reason():
    """A verdict that says both is one nobody can act on (L11)."""
    for cycles in ([], [cycle()], [cycle(new=None)] + [cycle() for _ in range(9)]):
        ready, why = verdict(cycles)
        assert not (ready and why)


def test_no_record_is_a_different_outcome_from_not_enough(capsys, monkeypatch,
                                                          tmp_path):
    """No record means the cycle has not been run since it started recording,
    which is a different thing to do about it than a short sample (L11)."""
    import check_no_such_account_calibration as tool

    monkeypatch.setattr(tool, "OBSERVATIONS", tmp_path / "nothing.json")
    tool.main([])

    said = capsys.readouterr().out
    assert "no observe cycle has been recorded" in said
    assert "not ready" not in said, (
        "an empty record is being reported as a short sample, so running the "
        "cycle and waiting for more of them read as the same next step")


def test_it_reports_the_dates_and_the_counts_it_was_asked_for(capsys, monkeypatch,
                                                              tmp_path):
    """#1195 asks for "the count and the dates recorded". A summary that gave
    neither would be a progress bar rather than evidence."""
    import check_no_such_account_calibration as tool

    store = tmp_path / "obs.json"
    store.write_text(json.dumps({"cycles": [cycle(on="2026-09-01", absent=1)]}),
                     encoding="utf-8")
    monkeypatch.setattr(tool, "OBSERVATIONS", store)
    tool.main([])

    said = capsys.readouterr().out
    assert "2026-09-01" in said
    assert "122" in said


def test_the_reader_survives_a_record_that_is_not_there():
    assert observations(REPO_ROOT / "tests" / "fixtures" / "nothing-here.json") == []


def test_the_gate_is_still_off():
    """The thing not to do. #1195 is explicit: do not switch it on because the
    classifier looks right. That is the shape #1002's calibration caught, where
    the first version of this same classifier passed every invented fixture and
    matched nothing at all in the real world.

    This fails if somebody flips the default without the evidence, which is the
    one change this whole issue exists to gate."""
    import inspect

    from postroll.ai.account_numbers import fetch

    default = inspect.signature(fetch).parameters["allow_no_such_account"].default
    assert default is False, (
        "allow_no_such_account defaults ON. If the evidence #1195 asks for is "
        "now recorded, that is a decision to make deliberately and to say so "
        "here; if it is not, a terminal verdict is being written on a sample "
        "that cannot support it")

# --- the writing side ---------------------------------------------------------

def test_a_cycle_is_appended_rather_than_replacing_the_last(tmp_path, monkeypatch):
    """The population fixture beside this replaces itself every cycle, which is
    right for a current shape and useless for a question about SEVERAL cycles.
    That is the whole defect: a file that replaces itself can never say how many
    times something was observed."""
    import tools.measure_account_population as tool
    from collections import Counter

    store = tmp_path / "obs.json"
    monkeypatch.setattr(tool, "OBSERVATIONS", store)

    tool.record_observation(handles=["a", "b"], outcomes=Counter({"measured": 2}),
                            would_have_been=Counter(), new_since_last=None)
    tool.record_observation(handles=["b", "c"], outcomes=Counter({"measured": 2}),
                            would_have_been=Counter({"no_such_account": 1}),
                            new_since_last=1)

    cycles = json.loads(store.read_text(encoding="utf-8"))["cycles"]
    assert len(cycles) == 2
    assert cycles[0]["asked"] == 2
    assert cycles[1]["would_have_been"] == {"no_such_account": 1}


def test_no_handle_reaches_the_record(tmp_path, monkeypatch):
    """A tool that reads a live system delivers real names into transcripts,
    scrollback and logs by a route no repository scanner inspects (L222). The
    handles here are what somebody tagged, so none of them may land."""
    import tools.measure_account_population as tool
    from collections import Counter

    store = tmp_path / "obs.json"
    monkeypatch.setattr(tool, "OBSERVATIONS", store)
    handles = ["averydistinctivehandle", "anotherveryodd_one"]

    tool.record_observation(handles=handles, outcomes=Counter(),
                            would_have_been=Counter(), new_since_last=None)

    body = store.read_text(encoding="utf-8")
    for handle in handles:
        assert handle not in body, f"{handle} reached the record"


def test_the_digests_cannot_be_compared_against_another_cycles(tmp_path,
                                                               monkeypatch):
    """The salt is regenerated every cycle, so the digests are comparable
    within ONE comparison and worthless afterwards. A fixed salt would make the
    record a stable identifier for every handle it has ever seen, and the set
    this asks about is small enough to run back through any hash (L222)."""
    import tools.measure_account_population as tool
    from collections import Counter

    store = tmp_path / "obs.json"
    monkeypatch.setattr(tool, "OBSERVATIONS", store)
    for _ in range(2):
        tool.record_observation(handles=["same", "handles"], outcomes=Counter(),
                                would_have_been=Counter(), new_since_last=0)

    cycles = json.loads(store.read_text(encoding="utf-8"))["cycles"]
    assert cycles[0]["salt"] != cycles[1]["salt"], "the salt is reused"
    assert cycles[0]["digests"] != cycles[1]["digests"], (
        "the same handles digest to the same values across cycles, so the "
        "record identifies them")


def test_new_since_last_counts_what_the_previous_cycle_had_not_seen(tmp_path,
                                                                    monkeypatch):
    import tools.measure_account_population as tool
    from collections import Counter

    store = tmp_path / "obs.json"
    monkeypatch.setattr(tool, "OBSERVATIONS", store)
    tool.record_observation(handles=["a", "b", "c"], outcomes=Counter(),
                            would_have_been=Counter(), new_since_last=None)

    assert tool._new_since_last(["a", "b", "c"]) == 0
    assert tool._new_since_last(["a", "b", "c", "d", "e"]) == 2
    assert tool._new_since_last(["x", "y"]) == 2


def test_the_first_cycle_has_nothing_to_be_new_against(tmp_path, monkeypatch):
    """None rather than zero, and they are different: a first cycle has not
    failed to bring new handles, it simply has no previous one (L11)."""
    import tools.measure_account_population as tool

    monkeypatch.setattr(tool, "OBSERVATIONS", tmp_path / "nothing.json")

    assert tool._new_since_last(["a", "b"]) is None


def test_an_absent_verdict_is_counted_even_though_it_was_not_written():
    """`would_have_been` is set only in observe mode, which is the mode the gate
    keeps it in. Counting it is the entire point: the verdict never lands, so
    the only trace it leaves is the count (L46)."""
    from postroll.ai.account_numbers import Figures, Outcome

    figures = Figures(handle="somebody", outcome=Outcome.COULD_NOT_CLASSIFY,
                      would_have_been=Outcome.NO_SUCH_ACCOUNT)

    assert figures.would_have_been is Outcome.NO_SUCH_ACCOUNT, (
        "the field the whole calibration reads is gone, so the cycles would "
        "record nothing and the evidence could never accumulate")
