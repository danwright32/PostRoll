"""The numbers the collaborator ranking is fitted to, as a command (#1114).

#1005 rests on a liveliness floor and an assumed engagement rate. Both were
measured in one session on 2026-08-29 and existed nowhere but prose, in a
repository that could reproduce neither. A number with a date on it reads as
more trustworthy, not less (L316), and nobody could check whether the
population had moved.

So the population is committed, anonymised, and these are the derivations. The
fixtures here are hand built and tiny, because a percentile is arithmetic and a
test that reads the real 122 accounts is a test of the data rather than of the
function. The real population has its own checks at the bottom.
"""

from __future__ import annotations

import json
import pytest

from postroll.ai.collaborator_metric import (
    ASSUMED_BAND,
    Account,
    assumed_rate,
    liveliness_floor,
    load,
    measured_rates,
    percentile,
    summary,
)


def account(followers=1000, likes=50, comments=0, measured=True, likes_hidden=False):
    return Account(followers=followers, likes=likes, comments=comments,
                   measured=measured, likes_hidden=likes_hidden)


# ── One account's rate ───────────────────────────────────────────────────────

def test_a_rate_is_interactions_over_followers_with_comments_weighted():
    # The same shape as CollaboratorPick.engagementRate, which weights a
    # comment three times a like: a comment takes real effort, so it is a
    # stronger signal that an audience is alive.
    assert account(followers=1000, likes=50, comments=10).engagement_rate == 0.08


def test_an_account_meta_refused_has_no_rate_at_all():
    # Not a low rate. What is measured about it is that it is unmeasurable, and
    # scoring it as zero would sort it below accounts that were counted and
    # found wanting.
    assert account(measured=False, followers=1000, likes=50).engagement_rate is None


def test_zero_followers_produce_no_rate_rather_than_an_infinity():
    assert account(followers=0, likes=50).engagement_rate is None
    assert account(followers=None, likes=50).engagement_rate is None


def test_an_account_with_neither_likes_nor_comments_has_no_rate():
    assert account(likes=None, comments=None).engagement_rate is None


def test_a_withheld_like_count_still_scores_on_comments():
    # #1032's case seen from here: the account answered and withheld one
    # figure. Comments alone are a real measurement of a live audience.
    figures = account(followers=1000, likes=None, comments=10, likes_hidden=True)
    assert figures.engagement_rate == 0.03


# ── The percentile itself ────────────────────────────────────────────────────

def test_the_percentile_interpolates_the_way_the_tools_people_check_with_do():
    # Linear interpolation between the two nearest ranks, which is what numpy
    # and Excel agree on. A percentile that disagrees with the one somebody
    # checks the number against is worse than no function at all.
    assert percentile([1, 2, 3, 4], 50) == 2.5
    assert percentile([1, 2, 3, 4], 0) == 1
    assert percentile([1, 2, 3, 4], 100) == 4
    assert percentile([10], 37) == 10


def test_a_percentile_of_nothing_refuses_rather_than_answering_zero():
    # A percentile of an empty population is not a small number, it is no
    # number, and a caller reading zero would carry it into a ranking (L98).
    with pytest.raises(ValueError):
        percentile([], 10)


# ── The two figures ──────────────────────────────────────────────────────────

def test_the_floor_is_the_tenth_percentile_of_what_was_measured():
    accounts = [account(followers=100, likes=n) for n in range(1, 101)]
    rates = sorted(a.engagement_rate for a in accounts)

    assert liveliness_floor(accounts) == pytest.approx(percentile(rates, 10))


def test_unmeasured_accounts_do_not_drag_the_floor_down():
    # The positive control against the obvious mistake (L159): folding refused
    # accounts in as zero would put the floor at zero and demote nobody.
    measured = [account(followers=100, likes=n) for n in range(1, 11)]
    refused = [account(measured=False) for _ in range(90)]

    assert liveliness_floor(measured + refused) == liveliness_floor(measured)


def test_the_assumed_rate_comes_from_the_comparable_follower_band():
    # Accounts Meta refuses are overwhelmingly small, so a rate drawn from the
    # whole population would be pulled by audiences nothing like theirs.
    small = [account(followers=1000, likes=n) for n in range(20, 30)]
    huge = [account(followers=400_000, likes=1) for _ in range(50)]

    assert assumed_rate(small + huge) == pytest.approx(assumed_rate(small))


def test_an_empty_band_refuses_rather_than_inventing_a_rate():
    # The population moving out from under the band is exactly the thing this
    # module exists to make visible, so it must be loud rather than silent.
    outside = [account(followers=ASSUMED_BAND[1] + 1, likes=50) for _ in range(5)]

    with pytest.raises(ValueError, match="band"):
        assumed_rate(outside)


# ── Loading the committed population ─────────────────────────────────────────

def test_a_missing_population_refuses_by_name(tmp_path):
    with pytest.raises(FileNotFoundError, match="measure_account_population"):
        load(tmp_path / "gone.json")


def test_an_empty_population_is_refused_rather_than_summarised(tmp_path):
    path = tmp_path / "empty.json"
    path.write_text(json.dumps({"accounts": []}))

    with pytest.raises(ValueError):
        load(path)


# ── The committed population itself ──────────────────────────────────────────

def test_the_committed_population_names_nobody():
    # The one property that makes committing it safe. Every value is a number
    # or a boolean, so there is nowhere for a handle to be (L155, L222).
    for row in json.loads(
            (__import__("pathlib").Path(__file__).resolve().parent
             / "fixtures" / "account_population.json").read_text())["accounts"]:
        for key, value in row.items():
            assert value is None or isinstance(value, (int, float, bool)), (
                f"{key} holds {value!r}, which is not a number, so this file "
                "can carry an identity")


def test_the_floor_and_the_assumed_rate_are_what_1005_was_written_against():
    # The whole point of #1114. These were prose with a date on them; they are
    # now the output of a command, and this is what fails when the population
    # moves far enough to change them.
    #
    # Measured 2026-09-01 over 122 handles: 0.37% and 2.73%, which is what the
    # 2026-08-29 session recorded over 114. The tolerance is wide enough that
    # one account joining or leaving does not turn this red, and narrow enough
    # that a real shift does.
    figures = summary(load())

    assert figures["liveliness_floor"] == pytest.approx(0.0037, abs=0.0005)
    assert figures["assumed_rate"] == pytest.approx(0.0273, abs=0.0020)
    assert figures["rankable"] >= 60, (
        "the population has lost most of its measured accounts, so both "
        "figures above are percentiles of something much smaller than the "
        "distribution they were chosen from")


def test_the_measured_share_is_still_roughly_what_the_plan_assumed():
    # #1002's coverage table and #1006's whole justification rest on this.
    figures = summary(load())
    share = figures["measured"] / figures["accounts"]

    assert 0.55 <= share <= 0.80, (
        f"Meta now answers for {share:.0%} of the tagged accounts, against the "
        "68% the plan was built on. Both the ranking's assumed rate and the "
        "case for reading a follower count off the page change with this.")
