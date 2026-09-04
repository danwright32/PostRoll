"""The numbers the collaborator ranking is fitted to, computed rather than quoted.

#1005 rests on two figures: a liveliness floor, below which an account is
demoted however large its audience, and an assumed engagement rate for the
accounts Meta will not report on. Both were measured in one session against the
live Instagram API on 2026-08-29 and existed nowhere but prose, in a repository
that could reproduce neither (#1114).

A number with a date on it reads as more trustworthy, not less (L316), and
nobody, including whoever implements the ranking, could check whether the
population had moved. So the population lives in version control, anonymised,
and these are the derivations. The figures become a command anyone can re-run,
and a shift in the population shows up as a changed number rather than as a
decision nobody revisits.

Anonymised means anonymised: follower count, typical likes, typical comments,
whether Meta answered, and nothing that names anybody (L155, L222). The
identities are not needed to compute a percentile, and an issue carrying real
evidence is the thing whoever implements it copies into fixtures.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

#: Where the committed population lives.
POPULATION = (Path(__file__).resolve().parents[2]
              / "tests" / "fixtures" / "account_population.json")

#: How much more a comment is worth than a like.
#:
#: Mirrors `CollaboratorPick.commentWeight`. A comment takes real effort, so it
#: is a stronger signal that an audience is alive and being shown the posts.
COMMENT_WEIGHT = 3

#: Which percentile of the measured rates becomes the liveliness floor.
#:
#: The 10th. Low enough to demote only accounts genuinely at the bottom of the
#: measured range rather than cutting through a crowded middle, where a small
#: move carries many accounts across at once (L172).
FLOOR_PERCENTILE = 10

#: Which percentile of the comparable band becomes the assumed rate.
#:
#: The 25th, deliberately pessimistic. What is measured about an account Meta
#: refuses is that it is unmeasurable; the rate is an assumption, so it errs low
#: rather than flattering an account nobody has counted.
ASSUMED_PERCENTILE = 25

#: The follower band the assumed rate is drawn from.
#:
#: Accounts Meta refuses are overwhelmingly small ones, so a rate drawn from the
#: whole population would be pulled by audiences nothing like theirs.
ASSUMED_BAND = (104, 3_422)


@dataclass(frozen=True)
class Account:
    """One anonymised account. No handle, by construction."""

    followers: int | None
    likes: int | None
    comments: int | None
    #: Whether Meta reported on this account at all.
    measured: bool
    #: The account answered and withheld its like count (#1032). Different from
    #: likes being absent: a refused measurement is not a missing one.
    likes_hidden: bool = False

    @property
    def engagement_rate(self) -> float | None:
        """Interactions per follower, comments weighted, or None if unrankable.

        The same shape as `CollaboratorPick.engagementRate`: None rather than
        zero for a missing or zero follower count, because a rate is
        interactions over followers and zero followers cannot produce one, and
        a defaulted zero sorts as though the account had been measured and
        found wanting.
        """
        if not self.measured:
            return None
        if not self.followers or self.followers <= 0:
            return None
        if self.likes is None and self.comments is None:
            return None
        interactions = (self.likes or 0) + (self.comments or 0) * COMMENT_WEIGHT
        return interactions / self.followers


def percentile(values: Sequence[float], which: int) -> float:
    """The linearly interpolated percentile, as numpy and Excel compute it.

    Written out rather than pulled in: this package has no numpy, and a
    percentile that disagrees with the one somebody checks the number against
    is worse than no function at all.

    Raises on an empty input, because a percentile of nothing is not a small
    number, it is no number, and a caller reading zero would carry it into a
    ranking (L98).
    """
    if not values:
        raise ValueError("no values, so there is no percentile to take")
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    position = (len(ordered) - 1) * which / 100
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def measured_rates(accounts: Iterable[Account]) -> list[float]:
    """Every engagement rate the population actually measured."""
    return [rate for account in accounts
            if (rate := account.engagement_rate) is not None]


def liveliness_floor(accounts: Iterable[Account]) -> float:
    """Below this rate an account is demoted however large its audience."""
    return percentile(measured_rates(accounts), FLOOR_PERCENTILE)


def assumed_rate(accounts: Iterable[Account],
                 band: tuple[int, int] = ASSUMED_BAND) -> float:
    """The rate to assume for an account Meta refused to report on."""
    low, high = band
    in_band = [rate for account in accounts
               if account.followers is not None
               and low <= account.followers <= high
               and (rate := account.engagement_rate) is not None]
    if not in_band:
        raise ValueError(
            f"no measured account falls in the {low} to {high} follower band, "
            "so there is nothing to draw an assumed rate from. The population "
            "has moved and the band has to be re-chosen against it.")
    return percentile(in_band, ASSUMED_PERCENTILE)


def load(path: Path | None = None) -> list[Account]:
    """The committed population.

    Refuses an empty file rather than returning an empty list, for the same
    reason `percentile` refuses one: every figure here is a percentile, and a
    percentile of nothing reads as a very small number to whoever gets it.
    """
    if path is None:
        path = POPULATION
    if not path.exists():
        raise FileNotFoundError(
            f"{path} is missing, so nothing can say what the collaborator "
            "metric was fitted to. Re-measure with "
            "`venv/bin/python tools/measure_account_population.py`.")
    rows = json.loads(path.read_text(encoding="utf-8")).get("accounts")
    if not rows:
        raise ValueError(f"{path} holds no accounts at all, so every percentile "
                         "computed from it is a number about nothing.")
    return [Account(**row) for row in rows]


def summary(accounts: Sequence[Account]) -> dict[str, object]:
    """Everything #1005 quotes, as a command rather than as a paragraph."""
    rates = measured_rates(accounts)
    band_rates = [rate for account in accounts
                  if account.followers is not None
                  and ASSUMED_BAND[0] <= account.followers <= ASSUMED_BAND[1]
                  and (rate := account.engagement_rate) is not None]
    return {
        "accounts": len(accounts),
        "measured": sum(1 for a in accounts if a.measured),
        "rankable": len(rates),
        "liveliness_floor": liveliness_floor(accounts),
        "assumed_rate": assumed_rate(accounts),
        "assumed_band_size": len(band_rates),
        "assumed_band_median": percentile(band_rates, 50),
        "median_rate": percentile(rates, 50),
        "hidden_like_counts": sum(1 for a in accounts if a.likes_hidden),
    }


def _main() -> int:
    for key, value in summary(load()).items():
        print(f"{key}: {value:.4f}  ({value:.2%})" if isinstance(value, float)
              else f"{key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
