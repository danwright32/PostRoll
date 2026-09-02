"""Fetching Instagram account figures through Meta's business_discovery (#1002).

Seven outcomes, because "no numbers" from seven causes is one state Dan cannot
act on. Three are terminal and four are due for another attempt, and the code
that decides which is one classifier reading structured fields, never message
text (L35).

Nothing here reaches the network. Both the Graph API and the logged out profile
page go through one injected transport, so a suite able to reach Meta is a
suite that spends somebody's quota and depends on the weather (L2).

Every wait goes through an injected sleep that records what it was asked for,
so the backoff is asserted as a schedule rather than lived through (L524).
"""

from __future__ import annotations

import json
import pytest

from postroll.ai.account_numbers import (
    ATTEMPTS,
    Figures,
    Outcome,
    PageVerdict,
    Response,
    TransportError,
    classify_page,
    fetch,
    is_terminal,
)
from postroll.ai.meta_app import GRAPH_API_VERSION


TOKEN = "EAA" + "x" * 196


# ── Building answers Meta could really give ──────────────────────────────────

def graph_ok(*, followers=1000, media_count=50, media=None, account_id="17841400000000000"):
    """A business_discovery answer in the shape the live API returned on
    2026-09-01, verified against natgeo and carnegiehall."""
    if media is None:
        media = [{"like_count": 100, "comments_count": 5,
                  "media_product_type": "FEED", "id": "1"}]
    return Response(
        status=200,
        headers={"x-app-usage": json.dumps({"call_count": 3, "total_time": 1,
                                            "total_cputime": 1})},
        body=json.dumps({
            "business_discovery": {
                "followers_count": followers,
                "media_count": media_count,
                "media": {"data": media},
                "id": account_id,
            },
            "id": "17841403653163673",
        }),
    )


def graph_error(code, *, status=400, message="Something went wrong",
                subcode=None, kind="OAuthException"):
    """Meta puts the actionable part in `code`. `message` is deliberately
    misleading in several tests below, because a classifier reading it would
    pass those and be wrong on the day the wording changes."""
    error = {"message": message, "type": kind, "code": code,
             "fbtrace_id": "AbCdEf"}
    if subcode is not None:
        error["error_subcode"] = subcode
    return Response(
        status=status,
        headers={"x-app-usage": json.dumps({"call_count": 90, "total_time": 5,
                                            "total_cputime": 5})},
        body=json.dumps({"error": error}),
    )


#: The two page shapes, copied from what instagram.com really served on
#: 2026-09-01 rather than invented (L48). Both matter, and both differ from
#: what this module was first written against:
#:
#: * the handle in `og:title` is HTML ESCAPED, `&#064;` and not `@`, so a
#:   matcher looking for a literal "@name" matches nothing at all. It matched
#:   nothing at all: 40 of 40 refused accounts came back unparseable.
#: * a handle nobody holds answers **200**, not 404, with no `og:title` and
#:   Instagram's own error route name in the payload. A rule keyed on 404 can
#:   never fire.
#:
#: Measured over the 60 accounts Meta refused in the live population: 59 had
#: the first shape and 1 had the second, matching an invented handle used as a
#: control exactly.
def profile_page(handle, *, status=200):
    return Response(
        status=status,
        headers={},
        body=('<meta property="og:title" content="A Name '
              f'(&#064;{handle}) &#x2022; Instagram photos and videos" />'),
    )


def missing_page():
    """A handle nobody holds, as Instagram really answers for one."""
    return Response(status=200, headers={},
                    body='<title>Instagram</title><script>"PolarisErrorRoot"</script>')


def wall_page(status=200):
    """Neither: a 200 carrying no profile and no error route."""
    return Response(status=status, headers={}, body="<html>nothing</html>")


class Calls:
    """One transport for both the Graph API and the profile page, recording
    what it was asked for so a test can assert the page was NOT fetched."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.urls: list[str] = []

    def __call__(self, url, headers):
        self.urls.append(url)
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


class Sleeps:
    """Records what the backoff asked for instead of waiting for it."""

    def __init__(self):
        self.seconds: list[float] = []

    def __call__(self, seconds):
        self.seconds.append(seconds)


def run(handle, answers, **kwargs):
    calls = Calls(answers)
    sleeps = Sleeps()
    result = fetch(handle, token=TOKEN, http=calls, sleep=sleeps, **kwargs)
    return result, calls, sleeps


# ── The measured case ────────────────────────────────────────────────────────

def test_a_professional_account_is_measured():
    figures, calls, _ = run("natgeo", [graph_ok(followers=268_652_873, media=[
        {"like_count": 1804, "comments_count": 15, "media_product_type": "REELS", "id": "1"},
        {"like_count": 2490, "comments_count": 63, "media_product_type": "REELS", "id": "2"},
        {"like_count": 9003, "comments_count": 168, "media_product_type": "FEED", "id": "3"},
    ])])

    assert figures.outcome is Outcome.MEASURED
    assert figures.followers == 268_652_873
    # 2490 is the median of 1804, 2490 and 9003. The mean is 4432, which the
    # 9003 post drags up by most of a thousand: one unusual post would report
    # an audience that does not turn out on an ordinary day.
    assert figures.likes == 2490
    assert figures.comments == 63
    assert figures.reels == 2 and figures.feed == 1
    assert len(calls.urls) == 1, "a measured account never touches the profile page"


def test_the_request_pins_the_api_version_from_the_one_constant():
    _, calls, _ = run("natgeo", [graph_ok()])
    assert f"/{GRAPH_API_VERSION}/" in calls.urls[0], calls.urls[0]


def test_the_quota_headers_are_recorded_on_a_successful_call():
    # The limit is expressed in Meta's units, so those are the units to watch
    # it in. The probe's "114 calls in 2 minutes with no rate limiting" is not
    # evidence: 80 of those 120 seconds were its own sleep.
    figures, _, _ = run("natgeo", [graph_ok()])
    assert figures.quota is not None
    assert figures.quota["call_count"] == 3


def test_the_quota_headers_are_recorded_on_a_refusal_too():
    # The reading that matters most is the one taken as the limit is reached,
    # and that call is a failure by definition. Three answers because a rate
    # limit is retried, and the quota recorded is the LAST reading rather than
    # the first, which is the one nearest the limit.
    figures, _, _ = run("natgeo", [graph_error(4, status=429)] * ATTEMPTS)
    assert figures.outcome is Outcome.RATE_LIMITED
    assert figures.quota is not None and figures.quota["call_count"] == 90


# ── A withheld like count is not a zero (#1032) ──────────────────────────────

def test_an_account_that_withholds_its_like_count_says_so():
    # Measured on the 2026-08-29 sample: 33 of 927 posts returned null likes
    # across 8 of 78 accounts, one of them on all 12 of its posts. Hidden is
    # not zero and not absent.
    figures, _, _ = run("someone", [graph_ok(media=[
        {"like_count": None, "comments_count": 9, "media_product_type": "FEED", "id": "1"},
        {"like_count": None, "comments_count": 4, "media_product_type": "FEED", "id": "2"},
    ])])

    assert figures.outcome is Outcome.MEASURED
    assert figures.likes is None, "a withheld figure must never arrive as a number"
    assert figures.likes_hidden is True
    assert figures.comments == 6


def test_an_account_measured_at_genuinely_zero_is_not_called_hidden():
    # The positive control for the assertion above (L159). Without it, a fetch
    # that called every like count hidden would satisfy it.
    figures, _, _ = run("quiet", [graph_ok(media=[
        {"like_count": 0, "comments_count": 0, "media_product_type": "FEED", "id": "1"},
    ])])

    assert figures.likes == 0
    assert figures.likes_hidden is False


# ── The four failures, classified on structure not wording ───────────────────

def test_a_rejected_token_is_its_own_outcome_and_is_never_retried():
    figures, _, sleeps = run("natgeo", [graph_error(190)])

    assert figures.outcome is Outcome.TOKEN_REJECTED
    assert sleeps.seconds == [], "retrying cannot mint a new token"


def test_a_rate_limit_is_retried_on_a_backing_off_schedule():
    figures, calls, sleeps = run(
        "natgeo", [graph_error(4, status=429), graph_error(4, status=429), graph_ok()])

    assert figures.outcome is Outcome.MEASURED
    assert len(calls.urls) == 3
    assert sleeps.seconds == [1.0, 2.0], (
        "the schedule itself is the assertion, not the fact that something waited")


def test_a_rate_limit_that_never_clears_is_reported_rather_than_looping():
    figures, calls, sleeps = run("natgeo", [graph_error(4, status=429)] * 9)

    assert figures.outcome is Outcome.RATE_LIMITED
    assert len(calls.urls) == 3, "bounded, so a limited hour cannot become an endless loop"
    assert sleeps.seconds == [1.0, 2.0]


def test_a_transport_that_raises_is_a_network_failure_not_a_missing_account():
    figures, _, _ = run("natgeo", [TransportError("dns"), TransportError("dns"),
                                   TransportError("dns")])

    assert figures.outcome is Outcome.NETWORK_FAILED
    assert not is_terminal(figures.outcome), "a network blip is due another attempt"


def test_the_classifier_reads_the_code_and_never_the_message():
    # A message saying "rate limit" under code 190 is a rejected token. Reading
    # the wording would classify this as retryable and retry it forever against
    # a credential that will never work again.
    figures, _, _ = run("natgeo", [graph_error(190, message="Rate limit reached, try later")])
    assert figures.outcome is Outcome.TOKEN_REJECTED

    # And the other way round: a code 4 whose message mentions the token.
    figures, _, _ = run("natgeo", [graph_error(4, message="invalid access token"),
                                   graph_error(4), graph_error(4)])
    assert figures.outcome is Outcome.RATE_LIMITED


def test_an_unrecognised_error_is_not_guessed_at():
    figures, _, _ = run("natgeo", [graph_error(99_999, kind="GraphMethodException")])

    assert figures.outcome is Outcome.COULD_NOT_CLASSIFY
    assert not is_terminal(figures.outcome)


# ── The quota is a percentage, and over 100 nothing helps ────────────────────

def over_allowance(percent=275):
    """Meta's answer once the app is past its hourly allowance.

    `x-app-usage` carries PERCENTAGES of the allowance, not counts. Measured on
    2026-09-01: a sweep of 122 handles run twice reached `call_count` 275, and
    82 of the 122 came back rate limited.
    """
    return Response(
        status=429,
        headers={"x-app-usage": json.dumps({"call_count": percent, "total_time": 157,
                                            "total_cputime": 0})},
        body=json.dumps({"error": {"message": "limit", "type": "OAuthException",
                                   "code": 4, "fbtrace_id": "x"}}),
    )


def test_a_quota_header_that_will_not_parse_is_no_reading_rather_than_a_low_one():
    # The safe direction, and the one worth pinning: a header Meta sent that
    # cannot be read must not come out as a small number, which would look like
    # plenty of allowance left and let the fetch retry into a wall. Two causes
    # share this None on purpose, an absent header and an unreadable one,
    # because the only question asked of the value is whether the allowance is
    # known to be spent, and neither can answer it.
    unreadable = Response(
        status=429, headers={"x-app-usage": "not json at all"},
        body=json.dumps({"error": {"message": "limit", "type": "OAuthException",
                                   "code": 4, "fbtrace_id": "x"}}))

    figures, calls, sleeps = run("natgeo", [unreadable] * ATTEMPTS)

    assert figures.quota is None, "an unreadable reading is not a reading"
    assert figures.outcome is Outcome.RATE_LIMITED
    assert len(calls.urls) == ATTEMPTS, (
        "with no reading saying the allowance is spent, the transient case is "
        "still retried rather than given up on")
    assert sleeps.seconds == [1.0, 2.0]


def test_an_unrecognised_code_is_retryable_and_that_is_a_decision():
    # Stated as its own assertion rather than left implied by is_terminal's
    # table. Writing an account off permanently on a code nobody has read is
    # the alternative, and a terminal outcome has no way back (L248), so this
    # is the deliberate half of a choice with two bad sides. The bound that
    # stops it retrying forever belongs to the caller and is named in #1004.
    figures, _, _ = run("natgeo", [graph_error(2_635, kind="GraphMethodException")])

    assert figures.outcome is Outcome.COULD_NOT_CLASSIFY
    assert not is_terminal(figures.outcome)
    assert "2635" in figures.detail, (
        "the code nobody classified is named, or the next person cannot find "
        "out what it was")


def test_being_over_the_hourly_allowance_is_not_retried_at_all():
    # The allowance is a rolling hour. Three attempts two seconds apart cannot
    # outlast it, and every one of them spends more of the thing that is
    # exhausted. Measured before this existed: a sweep retried 82 accounts
    # three times each into a wall, 246 calls that could not have succeeded.
    figures, calls, sleeps = run("natgeo", [over_allowance()])

    assert figures.outcome is Outcome.RATE_LIMITED
    assert len(calls.urls) == 1, "the reading already says another call cannot work"
    assert sleeps.seconds == [], "and waiting seconds cannot outlast a rolling hour"
    assert figures.quota["call_count"] == 275


def test_a_rate_limit_under_the_allowance_is_still_retried():
    # The positive control (L159). Without it the assertion above is satisfied
    # by a module that gave up on every rate limit, which would drop the
    # transient case the backoff exists for.
    figures, calls, sleeps = run(
        "natgeo", [graph_error(4, status=429), graph_ok()])

    assert figures.outcome is Outcome.MEASURED
    assert len(calls.urls) == 2
    assert sleeps.seconds == [1.0]


def test_the_allowance_reading_is_reported_even_when_it_arrives_late():
    # Under the allowance on the first answer, over it on the second. The
    # reading that decides is the newest one, not the one the run started with.
    figures, calls, sleeps = run(
        "natgeo", [graph_error(4, status=429), over_allowance()])

    assert figures.outcome is Outcome.RATE_LIMITED
    assert len(calls.urls) == 2
    assert sleeps.seconds == [1.0], "one wait, then the reading said stop"


# ── Code 110 is every refusal, so the page decides ───────────────────────────

def test_a_personal_account_is_told_apart_from_a_dead_handle_by_the_page():
    # Meta returned code 110 for all 36 measured failures identically, so the
    # only thing separating a personal account from a handle that does not
    # exist is a logged out page fetch. That fetch is here, in the same module,
    # rather than in the later scrape phase: without it this outcome cannot be
    # produced at all, and a plan may not claim a gate it does not have.
    figures, calls, _ = run("aperson", [graph_error(110), profile_page("aperson")])

    assert figures.outcome is Outcome.NOT_PROFESSIONAL
    assert len(calls.urls) == 2
    assert "aperson" in calls.urls[1] and "graph.facebook.com" not in calls.urls[1]


def test_a_handle_nobody_holds_is_called_dead_on_instagrams_own_error_page():
    figures, _, _ = run("nosuchhandle", [graph_error(110), missing_page()],
                        allow_no_such_account=True)

    assert figures.outcome is Outcome.NO_SUCH_ACCOUNT
    assert is_terminal(figures.outcome)


def test_a_blocked_page_is_never_read_as_a_dead_handle():
    # The trap this whole path has to avoid. Instagram serving a login wall to
    # a datacentre address would otherwise mark every refused account as one
    # that does not exist, permanently and terminally.
    figures, _, _ = run("aperson",
                        [graph_error(110), Response(status=429, headers={}, body="")],
                        allow_no_such_account=True)

    assert figures.outcome is Outcome.COULD_NOT_CLASSIFY
    assert not is_terminal(figures.outcome)


def test_a_page_that_is_neither_a_profile_nor_an_error_is_not_guessed_at():
    # The commonest thing a scraper actually meets, and the one that must never
    # be read as a dead handle: a 200 that carries neither marker.
    figures, _, _ = run("aperson", [graph_error(110), wall_page()],
                        allow_no_such_account=True)

    assert figures.outcome is Outcome.COULD_NOT_CLASSIFY


def test_observe_mode_records_the_verdict_it_would_have_written():
    # One real cycle before this outcome may be written, and an observe run
    # that recorded nothing would leave the cycle unable to say anything
    # (L535, L142). The verdict is produced and held, not suppressed.
    figures, _, _ = run("nosuchhandle", [graph_error(110), missing_page()])

    assert figures.outcome is Outcome.COULD_NOT_CLASSIFY
    assert figures.would_have_been is Outcome.NO_SUCH_ACCOUNT
    assert "observe" in figures.detail.lower()


def test_observe_mode_holds_back_nothing_else():
    # The positive control (L159): observe mode is about ONE outcome. A run
    # that downgraded everything would satisfy the assertion above.
    figures, _, _ = run("aperson", [graph_error(110), profile_page("aperson")])

    assert figures.outcome is Outcome.NOT_PROFESSIONAL
    assert figures.would_have_been is None


# ── The page classifier, asked directly ──────────────────────────────────────

@pytest.mark.parametrize("response,expected", [
    (profile_page("wanted"), PageVerdict.FOUND),
    (missing_page(), PageVerdict.ABSENT),
    (Response(status=404, headers={}, body=""), PageVerdict.ABSENT),
    (Response(status=403, headers={}, body=""), PageVerdict.BLOCKED),
    (Response(status=429, headers={}, body=""), PageVerdict.BLOCKED),
    (wall_page(), PageVerdict.UNPARSEABLE),
    (Response(status=500, headers={}, body=""), PageVerdict.UNPARSEABLE),
])
def test_the_page_verdicts_are_produced_from_real_shapes(response, expected):
    assert classify_page(response, handle="wanted") is expected


def test_the_handle_in_the_title_is_read_through_its_html_escaping():
    # The whole reason the first version classified nothing. Instagram writes
    # "&#064;" where a reader sees "@", so a matcher looking for the character
    # matches no real page at all while passing every invented fixture.
    assert "&#064;" in profile_page("wanted").body
    assert classify_page(profile_page("wanted"), handle="wanted") is PageVerdict.FOUND


def test_a_page_titled_for_a_different_account_is_not_that_account():
    # Instagram redirects some misspellings, so a 200 carrying somebody else's
    # title would otherwise confirm the wrong person exists.
    assert classify_page(profile_page("someoneelse"),
                         handle="wanted") is PageVerdict.UNPARSEABLE


def test_an_error_page_that_also_names_the_handle_is_still_a_profile():
    # The positive control for the marker's precedence (L159). Instagram's
    # bundle mentions many route names, so the error route alone must not
    # outrank a title that names the account.
    page = Response(status=200, headers={},
                    body=profile_page("wanted").body + '"PolarisErrorRoot"')

    assert classify_page(page, handle="wanted") is PageVerdict.FOUND


# ── Which outcomes are done with ─────────────────────────────────────────────

def test_exactly_three_outcomes_are_terminal():
    terminal = {o for o in Outcome if is_terminal(o)}
    assert terminal == {Outcome.MEASURED, Outcome.NOT_PROFESSIONAL,
                        Outcome.NO_SUCH_ACCOUNT}


def test_every_outcome_is_decided_one_way_or_the_other():
    # An outcome nothing classifies would default into whichever branch runs
    # last, and a default is indistinguishable from a decision (L113).
    for outcome in Outcome:
        assert isinstance(is_terminal(outcome), bool)


def test_the_result_carries_the_handle_it_was_asked_about():
    figures, _, _ = run("NatGeo", [graph_ok()])
    assert isinstance(figures, Figures)
    assert figures.handle == "natgeo", "keyed the way the account book keys"
