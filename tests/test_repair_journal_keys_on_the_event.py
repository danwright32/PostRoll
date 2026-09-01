"""#1162: a repair record says which POST it belongs to.

The journal's `event` field was written by four scripts that disagreed about
what it meant. `generate_blog` wrote the event NAME (its `--event` argument);
`swap_blog_photos`, `revise_blog` and `retry_blog_repair` each wrote
`venue or ""`, so the VENUE, or an empty string when there was none. One field,
two meanings, and nothing anywhere reported the disagreement (L15, L176).

That is fatal to showing the record in the app. Dan shoots the same venues over
and over, so a panel filtered on that field would show every post from The Green
Room 42 as if it were this one. A record confidently attributed to the wrong post
is worse than no record at all, which is the whole reason the journal exists.

So every record carries the event's own id, and the reader selects on it and
only on it. A record with no id belongs to no post and is never shown on one: it
is not evidence about the post being looked at, and guessing from the venue is
the defect this replaces (L214).
"""

from __future__ import annotations

import json
import uuid

import pytest

from postroll.ai.repair_log import RepairLog, records_for_event


EVENT = str(uuid.uuid4())
OTHER = str(uuid.uuid4())


@pytest.fixture
def journal(tmp_path):
    return tmp_path / "blog-repairs.jsonl"


def _lines(path):
    return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]


# --- every kind of record carries the id ------------------------------------

def test_every_record_kind_carries_the_event_id(journal):
    """Not just `attempt`. A pass that recorded only some of its kinds against
    the post would show a partial history that reads as a complete one (L98)."""
    log = RepairLog(journal, event="Greatest Hits", event_id=EVENT,
                    script="generate_blog")
    log.attempt(target="p1.jpg", marker="p1.jpg", codes=["alt_text_bad"],
                before="was", after="now", outcome="repaired", reason="")
    log.moved(marker="p1.jpg", rule="orphan", placed=True, reason="")
    log.declined(code="alt_text_repeated_opening", count=2,
                 reason="no repairer", issue="#1105")
    log.finish(ran=True, selected=1, attempted=1, remaining=100.0,
               placed=["p1.jpg"])

    written = _lines(journal)
    assert len(written) == 4, "one record per call, so the kinds can be counted"
    for record in written:
        assert record["event_id"] == EVENT, (
            f"a {record['kind']} record carries no event id, so it can never be "
            f"shown on the post it belongs to")


def test_the_event_name_is_still_recorded_beside_the_id(journal):
    """The id answers WHICH post; the name is what a person reads. Replacing
    the name with the id would make the terminal reporter unreadable."""
    log = RepairLog(journal, event="Greatest Hits", event_id=EVENT,
                    script="generate_blog")
    log.attempt(target="p1.jpg", marker="p1.jpg", codes=[], before="a",
                after="b", outcome="repaired", reason="")

    record = _lines(journal)[0]
    assert record["event"] == "Greatest Hits"
    assert record["event_id"] == EVENT


# --- the reader selects on the id, and only on it ---------------------------

def test_only_this_events_records_come_back(journal):
    """The defect this exists to stop: two posts, and the panel must not mix
    them."""
    RepairLog(journal, event="Night One", event_id=EVENT, script="generate_blog"
              ).attempt(target="a.jpg", marker="a.jpg", codes=[], before="a",
                        after="b", outcome="repaired", reason="")
    RepairLog(journal, event="Night Two", event_id=OTHER, script="generate_blog"
              ).attempt(target="b.jpg", marker="b.jpg", codes=[], before="c",
                        after="d", outcome="repaired", reason="")

    mine = records_for_event(EVENT, path=journal)

    assert len(mine) == 1, "the reader returned another post's records"
    assert mine[0]["marker"] == "a.jpg"


def test_two_posts_at_the_same_venue_are_kept_apart(journal):
    """The case that made this necessary. Dan shoots the same rooms
    repeatedly, so the venue cannot tell two of his posts apart."""
    same_venue = "The Green Room 42"
    RepairLog(journal, event=same_venue, event_id=EVENT,
              script="swap_blog_photos").attempt(
        target="a.jpg", marker="a.jpg", codes=[], before="a", after="b",
        outcome="repaired", reason="")
    RepairLog(journal, event=same_venue, event_id=OTHER,
              script="swap_blog_photos").attempt(
        target="b.jpg", marker="b.jpg", codes=[], before="c", after="d",
        outcome="repaired", reason="")

    mine = records_for_event(EVENT, path=journal)

    assert [r["marker"] for r in mine] == ["a.jpg"], (
        "two posts sharing a venue were treated as one post, which is the "
        "defect the id replaces")


def test_a_record_with_no_event_id_belongs_to_no_post(journal):
    """Written before this shipped, or by something that did not pass an id.

    It must not be attributed to whichever post happens to be open. Falling
    back to the venue or the name here would reintroduce exactly the guess
    this change removes (L214, L223).
    """
    journal.write_text(json.dumps({
        "at": "2026-09-01T00:00:00+00:00", "script": "generate_blog",
        "event": "Night One", "kind": "attempt", "marker": "a.jpg",
        "before": "a", "after": "b", "outcome": "repaired", "codes": [],
    }) + "\n", encoding="utf-8")

    assert records_for_event(EVENT, path=journal) == []
    assert records_for_event("", path=journal) == [], (
        "an empty id matched an unkeyed record, so every post with no id would "
        "collect every orphaned record in the journal")


def test_an_unreadable_journal_is_raised_rather_than_reported_empty(journal):
    """An empty answer would tell Dan the app changed nothing in a post where
    it may have changed a great deal (L10, L11). The reader already refuses
    this; the selector must not flatten it back."""
    from postroll.ai.repair_log import RepairLogUnreadable

    journal.mkdir()   # a directory where the journal should be: present, unreadable

    with pytest.raises(RepairLogUnreadable):
        records_for_event(EVENT, path=journal)
