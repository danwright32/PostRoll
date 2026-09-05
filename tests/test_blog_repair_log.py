"""#1135: the only evidence a silent repair leaves behind.

Rule 1 makes repairs SILENT. The panel says which findings survived and what the
pass did about them; it does not say what the alt text USED to be, and the
question anybody actually asks ("what did the app change in this post") arrives
after publication, by which time the run's stderr is long gone.

Not stderr: `PythonBridgeError.rotate` keeps 500 lines of a SHARED log and a
single blog run already prints 23 CHECK lines, so the evidence of a repair is
evicted within days (L191, L202).

Three kinds of record, and all three matter:

  * one ATTEMPT per repair attempt, with the text before and after;
  * one DECLINED per finding the pass did not attempt, carrying the written
    reason from the REPAIRERS table. This is what produces the per-code FIRING
    rate the deferral gates are stated against, and it is explicitly NOT a false
    positive count, which the field name says out loud (L90);
  * one PASS record on EVERY exit path, in a `finally`. Zero attempts must read
    as a recorded observation with its own wording, not as silence: rule 1
    removed every other signal, so without it a pass that made no attempt, a
    post with nothing to repair, a pass that threw before the loop, a pass whose
    table resolved nothing, a pass whose code was never reached, and a run
    killed at the process ceiling all read identically (L98, L11).

It never raises. Accounting must not take down a paid-for generation, exactly as
`usage_log.record` documents.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from postroll.ai.repair_log import (RepairLog, default_log_path, read_records)


@pytest.fixture
def log(tmp_path):
    return RepairLog(tmp_path / "blog-repairs.jsonl", event="Greatest Hits",
                     script="generate_blog")


# --- where it lives ---------------------------------------------------------

def test_the_log_honours_the_apps_own_data_directory(tmp_path, monkeypatch):
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))
    assert default_log_path().parent == tmp_path


def test_the_log_is_not_capped_or_rotated(log):
    """A capped store evicts the OLDEST real records first, and those are the
    expensive observations it exists to hold (L191). One line per repair on a
    handful of posts a week is kilobytes a year."""
    for i in range(500):
        log.attempt(target=f"{i}.jpg", marker=f"{i}.jpg", codes=["alt_text_length"],
                    before="a", after="b", outcome="repaired", reason="")
    log.finish(ran=True, selected=500, attempted=500, remaining=10.0)

    assert len(read_records(log.path)) == 501


# --- the three kinds --------------------------------------------------------

def test_an_attempt_records_what_the_text_was_and_what_it_became(log):
    log.attempt(target="a.jpg", marker="a.jpg", codes=["alt_text_length"],
                before="the old alt text", after="the new alt text",
                outcome="repaired", reason="")
    log.finish(ran=True, selected=1, attempted=1, remaining=100.0)

    attempt = [r for r in read_records(log.path) if r["kind"] == "attempt"][0]
    assert attempt["before"] == "the old alt text"
    assert attempt["after"] == "the new alt text"
    assert attempt["outcome"] == "repaired"
    assert attempt["marker"] == "a.jpg"
    assert attempt["at"], "no timestamp, so nothing can say when this happened"


def test_a_blocked_attempt_records_WHICH_of_its_causes_it_was(log):
    """Three causes, not one: model unreachable, call timed out, photograph
    unreadable. They invite different actions (L11)."""
    log.attempt(target="a.jpg", marker="a.jpg", codes=["alt_text_length"],
                before="x", after=None, outcome="blocked",
                reason="no photograph on disk for a.jpg")
    log.finish(ran=True, selected=1, attempted=1, remaining=100.0)

    attempt = [r for r in read_records(log.path) if r["kind"] == "attempt"][0]
    assert "photograph" in attempt["reason"]


def test_a_declined_record_says_it_is_not_a_false_positive_count(log):
    """The field name carries it, so a reader cannot mistake one for the other.

    A DECLINED record says the check FIRED, never that it fired WRONGLY, and
    rule 1 removed the surface where Dan might have said so (L90).
    """
    log.declined(code="invented_number", count=3,
                 reason="the only repair that deletes a claim from prose",
                 issue="#1150")
    log.finish(ran=True, selected=0, attempted=0, remaining=100.0)

    record = [r for r in read_records(log.path) if r["kind"] == "declined"][0]
    assert record["fired"] == 3
    assert "fired" in record
    assert "false_positive" not in json.dumps(record)
    assert record["issue"] == "#1150"


def test_a_pass_record_is_written_even_when_nothing_was_attempted(log):
    """Zero attempts is a recorded observation with its own wording, not
    silence."""
    log.finish(ran=True, selected=0, attempted=0, remaining=100.0)

    record = [r for r in read_records(log.path) if r["kind"] == "pass"][0]
    assert record["ran"] is True
    assert record["selected"] == 0
    assert record["attempted"] == 0
    assert record["wording"], "a pass that did nothing said nothing"


def test_a_pass_that_never_ran_reads_differently_from_one_that_found_nothing(log,
                                                                            tmp_path):
    other = RepairLog(tmp_path / "b.jsonl", event="E", script="generate_blog")
    log.finish(ran=True, selected=0, attempted=0, remaining=100.0)
    other.finish(ran=False, selected=0, attempted=0, remaining=0.0)

    clean = [r for r in read_records(log.path) if r["kind"] == "pass"][0]
    never = [r for r in read_records(other.path) if r["kind"] == "pass"][0]
    assert clean["wording"] != never["wording"], (
        "a post with nothing to repair and a pass that never ran say the same "
        "thing, which is the one state this record exists to tell apart")


def test_the_pass_record_carries_the_placed_photo_set(log):
    """The evidence blog_marker_missing_photo was providing incidentally, and
    stops providing once the pass acts on it (L277)."""
    log.finish(ran=True, selected=0, attempted=0, remaining=10.0,
               placed=["a.jpg", "b.jpg"])

    record = [r for r in read_records(log.path) if r["kind"] == "pass"][0]
    assert record["placed"] == ["a.jpg", "b.jpg"]


# --- it never takes a generation down ---------------------------------------

def test_an_unwritable_log_is_reported_and_does_not_raise(tmp_path, capsys):
    unwritable = tmp_path / "nope"
    unwritable.write_text("not a directory")
    log = RepairLog(unwritable / "blog-repairs.jsonl", event="E",
                    script="generate_blog")

    assert log.attempt(target="a", marker="a", codes=[], before="x", after="y",
                       outcome="repaired", reason="") is False
    assert log.finish(ran=True, selected=1, attempted=1, remaining=0.0) is False
    assert "could not" in capsys.readouterr().err.lower()


def test_a_run_with_an_unwritable_log_still_returns_a_complete_draft(tmp_path):
    """Accounting must never take down work that has already been paid for."""
    from unittest.mock import patch

    from PIL import Image

    from postroll.ai import generate_blog as gb

    photo = tmp_path / "DSC0001.jpg"
    Image.new("RGB", (40, 30), (1, 2, 3)).save(photo)
    prose = "It's a night that started late and the room didn't empty early."
    body = f"{prose}\n\n[PHOTO: DSC0001.jpg | A male performer sings]\n\n{prose}"
    unwritable = tmp_path / "nope"
    unwritable.write_text("not a directory")

    def fake(prompt, timeout=600, image_paths=None, image_labels=None, **k):
        if "Rewrite the alt text" in prompt:
            return {"alt": "Kate DiGangi sings into a microphone at The Green "
                           "Room 42 with one hand raised and the band behind"}
        return {"body": body, "photo_count": 1}

    with patch.object(gb, "run_json_prompt", side_effect=fake), \
         patch.dict(os.environ, {"POSTROLL_DATA_DIR": str(unwritable)}):
        result = gb.generate_blog(
            event="E", org="O", venue="The Green Room 42", date="2026-04-05",
            program={"performers": [{"name": "Kate DiGangi"}], "pieces": []},
            photo_paths=[str(photo)], skip_humanizer=True, skip_voice_pass=True)

    assert result["body"], "the draft was lost because a log could not be written"


# --- the reader -------------------------------------------------------------

def test_the_journal_has_a_reader_that_speaks_plainly(log, capsys):
    """A field with a writer and no reader is not evidence (L46)."""
    from tools.read_repair_log import report

    log.attempt(target="a.jpg", marker="a.jpg", codes=["alt_text_length"],
                before="the old alt text", after="the new alt text",
                outcome="repaired", reason="")
    log.declined(code="invented_number", count=2, reason="deletes a claim",
                 issue="#1150")
    log.finish(ran=True, selected=1, attempted=1, remaining=90.0,
               placed=["a.jpg"])

    report(log.path, event="Greatest Hits")
    printed = capsys.readouterr().out

    assert "the old alt text" in printed and "the new alt text" in printed
    assert "invented_number" in printed
    assert "a.jpg" in printed


def test_the_reader_says_so_when_there_is_nothing_for_that_event(log, capsys):
    """An empty answer is not a post with no repairs (L98)."""
    from tools.read_repair_log import report

    log.finish(ran=True, selected=0, attempted=0, remaining=10.0)
    report(log.path, event="A Different Event")
    printed = capsys.readouterr().out + capsys.readouterr().err

    assert "A Different Event" in printed


# --- the finally: every exit path leaves a record ---------------------------

def _pass_records(path):
    return [r for r in read_records(path) if r["kind"] == "pass"]


def test_a_pass_that_threw_before_its_loop_still_leaves_a_record(tmp_path):
    """A `finally` is defeated by anything that exits above it, so each of the
    ways out is exercised rather than assumed (L514, L515)."""
    from postroll.ai.blog_repair import repair_alt_text
    from postroll.ai.repair_log import RepairLog

    log = RepairLog(tmp_path / "j.jsonl", event="E", script="generate_blog")

    def exploding_check(*a, **k):
        raise RuntimeError("check_alt_text broke")

    from unittest.mock import patch
    with patch("postroll.ai.blog_repair.check_alt_text",
               side_effect=exploding_check):
        with pytest.raises(RuntimeError):
            repair_alt_text("prose\n\n[PHOTO: a.jpg | x]\n\nprose",
                            program=None, venue="V", photo_paths={},
                            runner=lambda *a, **k: {}, log=log)

    records = _pass_records(log.path)
    assert records, (
        "a pass that threw before its loop left no record, so it reads exactly "
        "like a post with nothing to repair")
    assert records[0]["ran"] is False


def test_a_pass_with_nothing_to_repair_leaves_a_record(tmp_path):
    from postroll.ai.blog_repair import repair_alt_text
    from postroll.ai.repair_log import RepairLog

    log = RepairLog(tmp_path / "j.jsonl", event="E", script="generate_blog")
    good = ("Kate DiGangi sings into a microphone at The Green Room 42 with "
            "one hand raised and the band lit blue behind her")

    repair_alt_text(f"prose\n\n[PHOTO: a.jpg | {good}]\n\nprose",
                    program={"performers": [{"name": "Kate DiGangi"}]},
                    venue="The Green Room 42", photo_paths={},
                    runner=lambda *a, **k: {}, log=log)

    records = _pass_records(log.path)
    assert records and records[0]["ran"] is True
    assert records[0]["selected"] == 0


def test_the_six_ways_out_do_not_all_read_the_same(tmp_path):
    """The whole reason the PASS record exists. Rule 1 removed every other
    signal, so these states have to be distinguishable HERE or nowhere."""
    from postroll.ai.repair_log import RepairLog

    wordings = set()
    for i, kwargs in enumerate([
        dict(ran=False, selected=0, attempted=0, remaining=0.0),
        dict(ran=True, selected=0, attempted=0, remaining=100.0),
        dict(ran=True, selected=3, attempted=3, remaining=100.0),
        dict(ran=True, selected=7, attempted=2, remaining=0.0),
    ]):
        log = RepairLog(tmp_path / f"{i}.jsonl", event="E", script="s")
        log.finish(**kwargs)
        wordings.add(_pass_records(log.path)[0]["wording"])

    assert len(wordings) == 4, f"two exits say the same thing: {wordings}"


def test_a_journal_that_is_THERE_and_unreadable_is_not_reported_as_empty(tmp_path):
    """An absent journal means no pass has run. An unreadable one means the
    evidence of every pass that DID is unavailable, and answering both with an
    empty list tells Dan no repair happened on a post where one did (L10, L11).
    """
    from postroll.ai.repair_log import RepairLogUnreadable

    # A directory where a file should be: present, and unreadable as text.
    there_but_not = tmp_path / "blog-repairs.jsonl"
    there_but_not.mkdir()

    with pytest.raises(RepairLogUnreadable) as caught:
        read_records(there_but_not)

    assert "could not be read" in str(caught.value)
    assert "no repairs" in str(caught.value)


def test_an_absent_journal_is_simply_empty(tmp_path):
    """The control: the distinction above must not make a first run an error."""
    assert read_records(tmp_path / "never-written.jsonl") == []


def test_a_journal_whose_every_line_is_corrupt_is_not_reported_as_empty(tmp_path):
    """The aggregate of a rule that is right per line (#1399).

    A line that will not parse is SKIPPED, deliberately, so one bad line does
    not hide every good one. When EVERY line is bad that returns an empty list,
    which is the same answer an untouched journal gives, and the two are
    opposite facts: one means no pass has run, the other means the evidence of
    every pass that did is gone (L10, L11, L215).
    """
    from postroll.ai.repair_log import RepairLogUnreadable

    journal = tmp_path / "blog-repairs.jsonl"
    journal.write_text("{not json\nalso not json\n", encoding="utf-8")

    with pytest.raises(RepairLogUnreadable) as caught:
        read_records(journal)

    assert "2" in str(caught.value), (
        "the refusal does not say how much it could not read")


def test_one_bad_line_still_does_not_hide_the_good_ones(tmp_path):
    """The control, and the rule being protected.

    Without it, "raise when nothing parsed" could be widened to "raise when
    anything failed to parse" and every test above would still pass, which is
    the deliberate behaviour this module documents being quietly removed.
    """
    journal = tmp_path / "blog-repairs.jsonl"
    journal.write_text(
        '{"kind": "pass", "event": "E", "wording": "ran"}\n'
        "{not json\n"
        '{"kind": "pass", "event": "E", "wording": "ran again"}\n',
        encoding="utf-8")

    kept = read_records(journal)

    assert [r["wording"] for r in kept] == ["ran", "ran again"]


def test_the_reader_tells_a_corrupt_journal_from_an_empty_one(tmp_path, capsys):
    """The consumer Dan actually opens. Repairs are silent, so this is the only
    evidence one left, and "No repair records" about a corrupt journal is the
    claim that nothing happened."""
    from tools.read_repair_log import report

    journal = tmp_path / "blog-repairs.jsonl"
    journal.write_text("{not json\n", encoding="utf-8")

    assert report(journal, event="E") == 2
    printed = capsys.readouterr().err
    assert "No repair records" not in printed


def test_the_reader_says_the_journal_was_unreadable_rather_than_empty(tmp_path,
                                                                     capsys):
    from tools.read_repair_log import report

    there_but_not = tmp_path / "blog-repairs.jsonl"
    there_but_not.mkdir()

    assert report(there_but_not, event="E") == 2
    printed = capsys.readouterr().err
    assert "could not be read" in printed
    assert "No repair records" not in printed


# --- a marker move reaches the journal (#1172) ------------------------------

def test_a_move_is_recorded_with_the_marker_and_the_rule(tmp_path):
    """The journal exists because repairs are SILENT and the panel does not
    survive publication. Photo placement changes what Dan published without
    saying so, and until this it left no durable trace at all."""
    log = RepairLog(tmp_path / "j.jsonl", event="Spring Gala",
                    script="generate_blog")

    assert log.moved(marker="two.jpg", rule="stacked_photos",
                     placed=True, reason="")

    record = read_records(tmp_path / "j.jsonl")[0]
    assert record["kind"] == "moved"
    assert record["marker"] == "two.jpg"
    assert record["rule"] == "stacked_photos"
    assert record["placed"] is True


def test_a_refused_move_is_recorded_as_its_own_outcome(tmp_path):
    """Placed and refused must not read the same. `check_blog` still reports
    the refusal on the panel, but the panel clears while the condition stays,
    so this is the only record that the app looked and declined (L98, L126)."""
    log = RepairLog(tmp_path / "j.jsonl", event="Spring Gala",
                    script="generate_blog")

    log.moved(marker="three.jpg", rule="stacked_photos", placed=False,
              reason="no prose below the stack to move into")

    record = read_records(tmp_path / "j.jsonl")[0]
    assert record["placed"] is False
    assert "no prose" in record["reason"]


def test_the_two_outcomes_are_distinguishable_in_the_record(tmp_path):
    """The control. If both wrote the same thing, the tests above would pass
    while the record answered neither question (L11)."""
    log = RepairLog(tmp_path / "j.jsonl", event="E", script="s")
    log.moved(marker="a.jpg", rule="stacked_photos", placed=True, reason="")
    log.moved(marker="b.jpg", rule="stacked_photos", placed=False, reason="why")

    placed = [r["placed"] for r in read_records(tmp_path / "j.jsonl")]
    assert placed == [True, False]


def test_the_reader_renders_a_move_and_a_refusal_differently(tmp_path, capsys):
    """A field with a writer and no reader is not evidence (L46), and the two
    outcomes must not print the same, or the record answers neither question."""
    from tools.read_repair_log import report

    log = RepairLog(tmp_path / "j.jsonl", event="Spring Gala", script="s")
    log.moved(marker="two.jpg", rule="stacked_photos", placed=True, reason="")
    log.moved(marker="three.jpg", rule="stacked_photos", placed=False,
              reason="no prose below the stack to move it into")

    report(tmp_path / "j.jsonl")
    said = capsys.readouterr().out

    assert "two.jpg" in said and "three.jpg" in said
    assert "no prose below" in said, "the refusal's reason was not rendered"
    moved_line = [l for l in said.splitlines() if "two.jpg" in l][0]
    refused_line = [l for l in said.splitlines() if "three.jpg" in l][0]
    assert moved_line != refused_line.replace("three", "two"), (
        "a move and a refusal print the same sentence, so the record cannot "
        "say which happened")


# ── no test may reach Dan's live data (#1179, #1180) ─────────────────────────
#
# Kept in this file rather than one of its own, deliberately. A new test file is
# unmeasured, and the duration record decides which files the fast run skips, so
# adding one forces a re-measurement; every reading available today was taken on
# a machine running Lightroom at 500% CPU and is not worth writing down (L224,
# L356). These tests are about this journal, so this is their home anyway.
#
# `RepairLog` defaulted its path to the live file, and `generate_blog`,
# `swap_blog_photos` and `retry_blog_repair` each construct one with no path, so
# every test driving those paths appended to Dan's real record. Measured before
# the fix, 2026-09-01: 2,775 records, all written that day, NONE belonging to
# any of the 21 real stored events.
#
# It leaked silently for its whole life because the write is append-only and
# best effort: a record landing in the wrong file fails nothing and no test goes
# red. The only way to see it was to read the artefact (L2, L196).

from postroll.data_root import data_root, running_under_test
from postroll.ai import usage_log


def test_the_suite_knows_it_is_a_test_run():
    """Everything below rests on this, so it is asserted rather than assumed.
    If pytest stopped setting the variable, every guard here would pass by
    being unable to tell a test from the app (L98)."""
    assert running_under_test()


def test_the_default_journal_path_is_not_the_live_one_under_test():
    """The refusal lives in the resource, because the three scripts CONSTRUCT
    their own log rather than receiving one, and a construction site inside the
    code under test is beyond any seam the caller could offer (L196)."""
    live = data_root() / "blog-repairs.jsonl"
    assert default_log_path() != live, (
        "a test run resolves the journal to the live file, so anything driving "
        "generate_blog, swap_blog_photos or retry_blog_repair appends to Dan's "
        "real record")


def test_a_log_built_the_way_the_scripts_build_it_writes_somewhere_harmless():
    """Measured by where the write LANDS, not by what the path says (L322)."""
    log = RepairLog(event="E", script="generate_blog")
    assert log.attempt(target="a.jpg", marker="a.jpg", codes=["alt_text_length"],
                       before="was", after="now", outcome="repaired", reason="")

    assert log.path.exists()
    assert log.path != data_root() / "blog-repairs.jsonl"
    written = [json.loads(line) for line in log.path.read_text().splitlines()]
    assert written[-1]["marker"] == "a.jpg"


def test_the_live_journal_is_never_the_target_of_a_write_under_test(tmp_path):
    """The control: a path handed in explicitly is still honoured, so the
    redirect above has not simply broken the seam it was protecting."""
    log = RepairLog(tmp_path / "mine.jsonl", event="E", script="s")
    log.attempt(target="a.jpg", marker="a.jpg", codes=[], before=None,
                after=None, outcome="blocked", reason="")

    assert (tmp_path / "mine.jsonl").exists()
    assert read_records(tmp_path / "mine.jsonl")


def test_the_redirect_is_per_run_rather_than_one_shared_file():
    """Two logs in one run may share a file; what matters is that the file is
    not the live one. Asserted so a future change to a fixed temp path is a
    deliberate choice rather than a surprise."""
    first = RepairLog(event="A", script="generate_blog").path
    second = RepairLog(event="B", script="swap_blog_photos").path
    live = data_root() / "blog-repairs.jsonl"

    assert first != live and second != live


def test_a_chosen_data_directory_is_still_honoured(tmp_path, monkeypatch):
    """The redirect must be no wider than its reason (L324).

    A test that sets POSTROLL_DATA_DIR has already pointed the app somewhere of
    its own, and that IS the seam this is protecting. The first version
    redirected unconditionally and broke
    `test_blog_repair_log.py::test_the_log_honours_the_apps_own_data_directory`,
    which asserts exactly that behaviour.
    """
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))

    assert default_log_path().parent == tmp_path
