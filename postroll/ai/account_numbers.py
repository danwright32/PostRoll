"""Read one Instagram account's audience figures through Meta (#1002).

The collaborator ranking runs on follower, like and comment counts that Dan has
been typing in by hand. This fetches them, for the accounts Meta will answer
for, which measured 68% of the real handles in his events on 2026-08-29.

Seven outcomes, not two. "No numbers" arrives from seven causes and only three
of them are the end of the story; the other four are due for another attempt,
and one of them (`TOKEN_REJECTED`) names a remedy only Dan can perform. Folding
them into a single failure would leave every one of those states looking like
an account nobody has counted yet, which is the thing this feature exists to
stop (L11).

Meta answers code 110 for EVERY refusal, identically, whether the account is a
personal one it cannot report on or a handle nobody holds. So telling those two
apart rests entirely on a logged out fetch of the profile page, and that fetch
lives here rather than in the later scraping work (#1006): without it this
module cannot produce `NOT_PROFESSIONAL` or `NO_SUCH_ACCOUNT` at all, and a
gate nothing implements is not a gate.

Nothing in here reaches the network by itself. Both requests go through one
injected callable and every wait through an injected sleep, so the suite proves
the schedule rather than living through it (L2, L524).

Calibrated against the live population on 2026-09-01, through this module, and
the calibration changed three things that every invented fixture had passed:

* The page classifier matched a literal "(@name)". Instagram HTML escapes the
  at sign, so it matched no real page at all: 40 of 40 refused accounts came
  back unparseable while the tests were green.
* Absence was keyed on a 404. Instagram answers **200** for a handle nobody
  holds, so that verdict could never be produced. It is keyed on Instagram's
  own error route name now, measured across the 60 refused accounts: 59 carried
  a title naming the handle and exactly 1 carried the error route, matching an
  invented control handle.
* Rate limiting is the normal case, not an edge one. 82 of 122 handles came
  back limited on a second sweep, with the allowance 275% spent, and the
  backoff was retrying every one of them into a wall.

The reading after those fixes: 39 `not_professional`, 1 observed
`no_such_account`, the rest limited. `no_such_account` is still not WRITTEN;
see `fetch`.
"""

from __future__ import annotations

import html
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from enum import Enum
from statistics import median
from typing import Any, Callable, Mapping, Sequence

from .meta_app import GRAPH_API_HOST, GRAPH_API_VERSION, QUERYING_ACCOUNT_ID


class Outcome(Enum):
    """What this fetch established, in the seven states Dan can act on."""

    #: Figures came back. Individual figures may still be withheld; see
    #: `Figures.likes_hidden`.
    MEASURED = "measured"
    #: The account exists and is a personal account, which `business_discovery`
    #: cannot report on at all. No token, permission or retry recovers it.
    NOT_PROFESSIONAL = "not_professional"
    #: Nobody holds this handle. Only ever written on a definite 404.
    NO_SUCH_ACCOUNT = "no_such_account"
    #: Something answered, and what it said does not decide the question. The
    #: honest outcome, and deliberately the one every uncertainty falls into.
    COULD_NOT_CLASSIFY = "could_not_classify"
    RATE_LIMITED = "rate_limited"
    NETWORK_FAILED = "network_failed"
    #: The credential is not usable. Never retried: no number of attempts
    #: mints a new token, and the remedy is in `docs/META-APP.md`.
    TOKEN_REJECTED = "token_rejected"


#: The outcomes that are the end of the story for this account.
#:
#: Written as the set of terminal ones rather than as the set of retryable
#: ones, because a state added later and left out of a list of "retry these"
#: would silently become permanent, which is the more expensive direction.
_TERMINAL = frozenset({Outcome.MEASURED, Outcome.NOT_PROFESSIONAL,
                       Outcome.NO_SUCH_ACCOUNT})


def is_terminal(outcome: Outcome) -> bool:
    """Whether anything is served by asking about this account again.

    NOT terminal does not mean retry forever, and one case deserves saying out
    loud: an unrecognised Meta code becomes `COULD_NOT_CLASSIFY`, which is
    retryable, so an error nobody understood is retried by default. That is the
    deliberate choice of the two available, because the alternative writes an
    account off permanently on the strength of a code nobody has read, and a
    terminal outcome has no way back (L248).

    The cost is real: a handle that always produces an unknown code is asked
    about forever unless something bounds it. Nothing here can bound it, because
    this module answers about one account and holds no history. The bound
    belongs to the caller that schedules the fetches, and it is named in #1004
    along with the rate that `RATE_LIMITED` has to be counted against, since an
    expected failure with no notion of volume makes one blip and a total outage
    arrive on the same path (L35, L77, L110).
    """
    return outcome in _TERMINAL


class PageVerdict(Enum):
    """What the logged out profile page established, which is usually nothing.

    Four, and only two of them are answers. Anything that is not a definite yes
    or a definite no becomes `COULD_NOT_CLASSIFY` upstream, never
    `NO_SUCH_ACCOUNT`: Instagram serving a login wall to this machine would
    otherwise mark every refused account as permanently dead.
    """

    FOUND = "found"
    ABSENT = "absent"
    BLOCKED = "blocked"
    UNPARSEABLE = "unparseable"


class TransportError(Exception):
    """The request did not complete. Raised by the transport, never by Meta."""


@dataclass(frozen=True)
class Response:
    """One HTTP answer, in the only three parts anything here reads."""

    status: int
    headers: Mapping[str, str]
    body: str


@dataclass(frozen=True)
class Figures:
    """What one account turned out to be, however that turned out."""

    handle: str
    outcome: Outcome
    #: Meta's stable id for the account. Stored so a later fetch can notice the
    #: id behind a handle changed and refuse to merge across it (#1003):
    #: `business_discovery` looks up by a mutable display name.
    instagram_id: str | None = None
    followers: int | None = None
    #: The median of the sampled posts, not the mean: one viral post otherwise
    #: reports an audience that does not exist on an ordinary day.
    likes: int | None = None
    comments: int | None = None
    #: The account answered and withheld its like count (#1032). Different from
    #: `likes is None` because nothing was measured: this says a measurement was
    #: refused, which is a third thing, and must never reach arithmetic as zero.
    likes_hidden: bool = False
    #: The mix of the sampled posts. Reels drew 1.29x feed likes at the median
    #: on the 2026-08-29 sample, and 11 of 46 accounts differed by more than
    #: double, so a figure that jumps between fetches is often the mix moving
    #: rather than the audience (#1003).
    reels: int = 0
    feed: int = 0
    #: Meta's own account of what this call cost, parsed from `x-app-usage`.
    #: Recorded on every call including the ones that failed, because the
    #: reading that matters most is taken as the limit is reached.
    quota: dict[str, Any] | None = None
    #: The follower count came from the profile page, not from Meta (#1006).
    #:
    #: Distinguishable because it is a different KIND of claim. Meta reports a
    #: number; the page reports a rounded one, "12.7K" being anywhere in a 100
    #: wide band, and it is read for accounts Meta will not answer for at all,
    #: whose engagement rate is therefore assumed rather than measured (#1005).
    #: A scraped figure rendering as one Meta reported would overstate both.
    followers_from_page: bool = False
    #: What would have been written if `allow_no_such_account` were on. Set only
    #: in observe mode, so the cycle that calibrates it has something to read.
    would_have_been: Outcome | None = None
    #: For a person, never parsed. Nothing branches on this.
    detail: str = ""


# ── Classifying what Meta said ───────────────────────────────────────────────

#: Meta's code for "the thing you asked about is not something I will report
#: on". Returned for a personal account and for a handle nobody holds alike,
#: which is why the page fetch below exists.
_UNRESOLVABLE = 110

#: Codes that mean the credential is finished. `190` is the OAuth family; the
#: subcodes under it are all still a token that has to be replaced.
_TOKEN_CODES = frozenset({102, 190, 463, 467})

#: Codes that mean too much, too fast. `4` is the app level cap, `17` the user
#: level one, `32` the page level one, `613` the custom rate limit.
_RATE_CODES = frozenset({4, 17, 32, 613})


def _error_code(payload: Mapping[str, Any]) -> int | None:
    """The code Meta actually sent, or None when this is not an error at all.

    The ONE place an error is read. Everything downstream branches on this
    integer and never on `message`: the wording is prose Meta rewrites at will,
    a substring match on it is wrong the day it changes, and it is wrong in the
    expensive direction, because a "rate limit" message under a dead token
    would be retried against a credential that can never work again (L35).
    """
    error = payload.get("error")
    if not isinstance(error, dict):
        return None
    code = error.get("code")
    return code if isinstance(code, int) else -1


#: The `og:title` meta tag, whose content names the account when one exists.
_OG_TITLE = re.compile(r'<meta property="og:title" content="([^"]{0,300})"', re.I)

#: The `og:description` meta tag, which carries the follower count.
_OG_DESCRIPTION = re.compile(
    r'<meta property="og:description" content="([^"]{0,400})"', re.I)

#: The follower figure inside it, with the suffix Instagram rounds to.
#:
#: Measured on 2026-09-01: "269M Followers, 195 Following, 32K Posts". The
#: comma group is for counts under a thousand thousand, which are written out.
_FOLLOWERS = re.compile(r"([\d,]+(?:\.\d+)?)\s*([KMB]?)\s+Followers", re.I)

#: What each suffix multiplies by.
_MAGNITUDE = {"": 1, "K": 1_000, "M": 1_000_000, "B": 1_000_000_000}


def followers_in_description(body: str) -> int | None:
    """The follower count Instagram prints on the logged out page, or None.

    Outside Instagram's terms, and deliberately the last thing in this feature
    so nothing else depends on it (#1006). Reachable only from a definite
    `NOT_PROFESSIONAL`, never from a transient failure.

    None rather than zero whenever it cannot be read. A page whose wording
    changed must read as a figure nobody has, not as an account with no
    audience, which would sort it to the bottom of a ranking as though it had
    been measured and found wanting (L67).

    Accuracy, measured for the 78 accounts the API also answered for on
    2026-08-29: the page count and the API count agree to a median 0.0%
    difference, worst 4.3%, which is the rounding in a value like "12.7K".

    Coverage, measured through this function against the live pages on
    2026-09-01: 17 of 17 accounts Meta refused yielded a count, ranging from 0
    to 3,422 with a median of 1,240. Measured rather than assumed, because the
    first version of the classifier beside this one passed every invented
    fixture and matched nothing at all in the real world.

    Zero is a real answer and is kept. An account with no followers cannot be
    ranked anyway, since a rate is interactions over followers, and reporting
    it as unknown would claim less than was seen.
    """
    described = _OG_DESCRIPTION.search(body)
    if not described:
        return None
    found = _FOLLOWERS.search(html.unescape(described.group(1)))
    if not found:
        return None
    try:
        value = float(found.group(1).replace(",", ""))
    except ValueError:
        return None
    return int(value * _MAGNITUDE[found.group(2).upper()])


#: The name of the route Instagram renders when a handle resolves to nothing.
#:
#: MEASURED on 2026-09-01, not guessed. A handle nobody holds answers 200, not
#: 404, carrying no `og:title` and this string; a handle that exists answers
#: 200 with an `og:title` naming it and without this string. Checked across the
#: 60 accounts Meta refused in the live population: 59 had the first shape and
#: exactly 1 had the second, matching an invented control handle exactly.
#:
#: It is an internal name and it will change. That is survivable in the safe
#: direction: when it stops appearing, a dead handle reads as UNPARSEABLE and
#: therefore as `COULD_NOT_CLASSIFY`, which is retryable and says nothing false.
#: It is only unsafe if the string starts appearing on pages that DO exist, so
#: a title naming the handle outranks it below.
_ERROR_ROUTE = "PolarisErrorRoot"


def classify_page(response: Response, *, handle: str) -> PageVerdict:
    """What the logged out profile page says about whether this handle exists.

    Deliberately hard to satisfy in both directions. `FOUND` needs the page's
    own `og:title` to name this handle, so a redirect to somebody else cannot
    confirm the wrong person. `ABSENT` needs Instagram to have rendered its own
    error route AND no title, so a login wall, a challenge or a server error
    can never be read as a handle nobody holds.

    The first version of this looked for a literal "(@name)" in the body and
    required a 404 for absence. Neither can ever match: Instagram HTML escapes
    the at sign as `&#064;`, and it answers 200 for a handle nobody holds. Run
    against the live population it classified 40 of 40 as unparseable while
    passing every invented fixture, which is what a fixture nobody measured
    buys (L48, L246).
    """
    if response.status == 404:
        return PageVerdict.ABSENT
    if response.status in (401, 403, 429):
        return PageVerdict.BLOCKED
    if response.status != 200:
        return PageVerdict.UNPARSEABLE

    found = _OG_TITLE.search(response.body)
    if found and f"@{handle.lower()}" in html.unescape(found.group(1)).lower():
        return PageVerdict.FOUND
    if found:
        # A title for somebody else. A redirect, and not an answer about the
        # handle that was asked about.
        return PageVerdict.UNPARSEABLE
    if _ERROR_ROUTE in response.body:
        return PageVerdict.ABSENT
    return PageVerdict.UNPARSEABLE


def _from_page(verdict: PageVerdict) -> Outcome:
    """The page's verdict as one of the seven, with every uncertainty landing
    on the honest one."""
    if verdict is PageVerdict.FOUND:
        return Outcome.NOT_PROFESSIONAL
    if verdict is PageVerdict.ABSENT:
        return Outcome.NO_SUCH_ACCOUNT
    return Outcome.COULD_NOT_CLASSIFY


# ── Reading the figures ──────────────────────────────────────────────────────

def _figures_from(media: Sequence[Mapping[str, Any]]) -> tuple[int | None, int | None,
                                                               bool, int, int]:
    """Typical likes and comments over the sampled posts, and the mix.

    A post whose `like_count` is absent is a REFUSED measurement, not a zero,
    so it is excluded from the like median and recorded as withheld. Comments
    are counted separately because an account can answer one and not the other.
    """
    likes = [m["like_count"] for m in media
             if isinstance(m.get("like_count"), int)]
    comments = [m["comments_count"] for m in media
                if isinstance(m.get("comments_count"), int)]
    hidden = any(m.get("like_count") is None for m in media)
    reels = sum(1 for m in media if m.get("media_product_type") == "REELS")
    feed = sum(1 for m in media if m.get("media_product_type") == "FEED")
    return (
        int(median(likes)) if likes else None,
        int(median(comments)) if comments else None,
        hidden and not likes,
        reels,
        feed,
    )


#: The share of the hourly allowance at which another call cannot succeed.
#:
#: `x-app-usage` reports PERCENTAGES of the allowance, not counts, over a
#: rolling one hour window. At or above 100 the app is throttled and every
#: further call is refused, so retrying spends more of the exhausted thing to
#: be told the same answer.
#:
#: MEASURED on 2026-09-01: sweeping the 122 real handles twice reached
#: `call_count` 275, and 82 of the 122 came back rate limited. Retrying each of
#: those three times is 246 calls that could not have worked. The probe on
#: 2026-08-29 recorded "114 calls in 2 minutes with no rate limiting", which was
#: never evidence: 80 of those 120 seconds were its own sleep.
ALLOWANCE_SPENT = 100


def _over_allowance(quota: dict[str, Any] | None) -> bool:
    """Whether Meta has already said another call cannot succeed.

    False when there is no reading at all. An absent header is not a statement
    that the allowance is fine, but it is also not one that it is spent, and
    refusing on a missing header would stop the fetch working wherever Meta
    chooses not to send one.
    """
    if not quota:
        return False
    return any(isinstance(quota.get(field), (int, float))
               and quota[field] >= ALLOWANCE_SPENT
               for field in ("call_count", "total_time", "total_cputime"))


def _quota(headers: Mapping[str, str]) -> dict[str, Any] | None:
    """Meta's usage header, parsed, or None when there is no reading.

    None rather than an empty dict: a call that reported no usage and one that
    reported none used are different facts, and the second is what a fresh hour
    looks like.

    Two different causes DO share that None: a header Meta did not send, and one
    it sent that will not parse. They are collapsed deliberately, because the
    only question asked of this value is whether the allowance is known to be
    spent, and the answer for both is "no reading", which is the same fact and
    takes the same safe branch. If anything ever REPORTS the quota to a person,
    that reader needs the two told apart (L11), and this is the note saying so.
    """
    for name, value in headers.items():
        if name.lower() != "x-app-usage":
            continue
        try:
            parsed = json.loads(value)
        except (TypeError, ValueError):
            return None
        return parsed if isinstance(parsed, dict) else None
    return None


# ── The call ─────────────────────────────────────────────────────────────────

#: How many times one account's Graph call is attempted before the transient
#: outcome is reported as the answer. Three, with the waits below between them.
#: Bounded rather than open ended: a limited hour would otherwise become a loop
#: with no end, holding the run open for as long as Meta stays unhappy (L110).
ATTEMPTS = 3

#: The waits between those attempts, in seconds, doubling.
#:
#: Named as a schedule rather than computed, so the test asserts the schedule
#: itself. Delivered through an injected sleep so no test ever lives through it.
BACKOFF_SECONDS = (1.0, 2.0)

#: How many recent posts to read figures from.
#:
#: Twelve. Enough that one unusual post cannot move the median much, few enough
#: that the response stays small. The 2026-08-29 sample read 927 posts across
#: 78 accounts, close to twelve each.
MEDIA_SAMPLE = 12


def _graph_url(handle: str, account_id: str) -> str:
    fields = (
        f"business_discovery.username({handle})"
        "{followers_count,media_count,media.limit(" + str(MEDIA_SAMPLE) + ")"
        "{like_count,comments_count,media_product_type}}"
    )
    return (f"{GRAPH_API_HOST}/{GRAPH_API_VERSION}/{account_id}"
            f"?fields={urllib.parse.quote(fields, safe='')}")


def _page_url(handle: str) -> str:
    return f"https://www.instagram.com/{urllib.parse.quote(handle)}/"


def _real_transport(url: str, headers: Mapping[str, str]) -> Response:
    """The only place this package opens a socket.

    Every failure becomes `TransportError`, so the caller has one thing to
    catch and cannot mistake a DNS failure for an answer from Meta.
    """
    request = urllib.request.Request(url, headers=dict(headers))
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return Response(status=response.status,
                            headers={k.lower(): v for k, v in response.headers.items()},
                            body=response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as error:
        # An HTTP error IS an answer: Meta puts the code that classifies the
        # refusal in the body of a 400. Swallowing it as a transport failure
        # would turn every one of them into NETWORK_FAILED and retry forever.
        return Response(status=error.code,
                        headers={k.lower(): v for k, v in error.headers.items()},
                        body=error.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise TransportError(str(error)) from error


def fetch(
    handle: str,
    *,
    token: str,
    account_id: str = QUERYING_ACCOUNT_ID,
    http: Callable[[str, Mapping[str, str]], Response] = _real_transport,
    sleep: Callable[[float], None] | None = None,
    allow_no_such_account: bool = False,
) -> Figures:
    """One account's figures, or the reason there are none.

    `allow_no_such_account` is off by default and is the observe gate the plan
    asks for: an absent verdict is RECORDED as what it would have been and
    reported as `COULD_NOT_CLASSIFY`. The verdict is produced either way,
    because an observe phase that suppressed the reading would leave the cycle
    with nothing to calibrate against (L535).

    One observe cycle has run, on 2026-09-01, over 122 real handles. It
    produced exactly ONE absent verdict. That is not enough to switch this on:
    `NO_SUCH_ACCOUNT` is terminal, so nothing ever asks about that account
    again, and a wrong one is unrecoverable by design. A single observation
    cannot calibrate an outcome with no way back (L248).

    So it stays off, and it is not off forever by accident: #1195 is the issue
    that turns it on, and it names the reading required to do so (L65).
    """
    if sleep is None:
        import time
        sleep = time.sleep

    key = handle.strip().lstrip("@").lower()
    headers = {"Authorization": f"Bearer {token}"}
    url = _graph_url(key, account_id)

    last: Response | None = None
    transport_failure: str | None = None

    for attempt in range(ATTEMPTS):
        try:
            last = http(url, headers)
            transport_failure = None
        except TransportError as error:
            transport_failure = str(error)
            last = None
        else:
            code = _error_code(json.loads(last.body) if last.body else {})
            if code is None:
                return _measured(key, last)
            if code in _TOKEN_CODES:
                # Not retried. No number of attempts mints a new token, and
                # each one spends quota to be told the same thing.
                return Figures(handle=key, outcome=Outcome.TOKEN_REJECTED,
                               quota=_quota(last.headers),
                               detail="The Meta token was rejected. Mint a new one: "
                                      "see docs/META-APP.md.")
            if code == _UNRESOLVABLE:
                return _decide_by_page(key, last, http, allow_no_such_account)
            if code not in _RATE_CODES:
                return Figures(handle=key, outcome=Outcome.COULD_NOT_CLASSIFY,
                               quota=_quota(last.headers),
                               detail=f"Meta answered with code {code}, which nothing "
                                      "here classifies.")
            spent = _quota(last.headers)
            if _over_allowance(spent):
                # Meta has already answered the question the retry would ask.
                # The window is a rolling hour, which no backoff written in
                # seconds can outlast, and each attempt spends more of the
                # thing that is exhausted.
                return Figures(handle=key, outcome=Outcome.RATE_LIMITED, quota=spent,
                               detail="The app is over its hourly Meta allowance "
                                      f"({spent.get('call_count')}% of calls). Nothing "
                                      "will answer until the window rolls.")
        if attempt < len(BACKOFF_SECONDS):
            sleep(BACKOFF_SECONDS[attempt])

    if transport_failure is not None:
        return Figures(handle=key, outcome=Outcome.NETWORK_FAILED,
                       detail=f"Could not reach Meta after {ATTEMPTS} attempts: "
                              f"{transport_failure}")
    assert last is not None  # the loop either answered, raised, or set this
    return Figures(handle=key, outcome=Outcome.RATE_LIMITED,
                   quota=_quota(last.headers),
                   detail=f"Meta was still rate limiting after {ATTEMPTS} attempts.")


def _measured(key: str, response: Response) -> Figures:
    found = json.loads(response.body)["business_discovery"]
    media = found.get("media", {}).get("data", [])
    likes, comments, hidden, reels, feed = _figures_from(media)
    return Figures(
        handle=key,
        outcome=Outcome.MEASURED,
        instagram_id=found.get("id"),
        followers=found.get("followers_count"),
        likes=likes,
        comments=comments,
        likes_hidden=hidden,
        reels=reels,
        feed=feed,
        quota=_quota(response.headers),
        detail=f"Read from {len(media)} recent posts.",
    )


def _decide_by_page(key: str, refusal: Response,
                    http: Callable[[str, Mapping[str, str]], Response],
                    allow_no_such_account: bool) -> Figures:
    """Meta refused with the code it uses for everything, so ask the page.

    A transport failure HERE is not a network failure of the whole fetch: Meta
    answered, and what is missing is only the thing that would have told two
    refusals apart. So it is `COULD_NOT_CLASSIFY`, which is retryable, rather
    than a state that reads as though Meta never replied.
    """
    quota = _quota(refusal.headers)
    try:
        page = http(_page_url(key), {})
    except TransportError as error:
        return Figures(handle=key, outcome=Outcome.COULD_NOT_CLASSIFY, quota=quota,
                       detail="Meta would not report on this account, and the profile "
                              f"page could not be reached to say why: {error}")

    verdict = classify_page(page, handle=key)
    outcome = _from_page(verdict)
    if outcome is Outcome.NOT_PROFESSIONAL:
        # The one place a figure is taken off the page (#1006), and only from a
        # definite yes. Read from the page ALREADY fetched to classify the
        # account rather than fetching it a second time.
        followers = followers_in_description(page.body)
        return Figures(handle=key, outcome=outcome, quota=quota,
                       followers=followers,
                       followers_from_page=followers is not None,
                       detail="Meta would not report on this account; the "
                              "profile page was found."
                              + ("" if followers is None
                                 else f" Followers read off the page: {followers}."))
    if outcome is Outcome.NO_SUCH_ACCOUNT and not allow_no_such_account:
        return Figures(handle=key, outcome=Outcome.COULD_NOT_CLASSIFY, quota=quota,
                       would_have_been=Outcome.NO_SUCH_ACCOUNT,
                       detail="Observe mode: the profile page 404ed, which would be "
                              "no_such_account once this has been calibrated against "
                              "a real cycle.")
    return Figures(handle=key, outcome=outcome, quota=quota,
                   detail=f"Meta would not report on this account; the profile page "
                          f"was {verdict.value}.")
