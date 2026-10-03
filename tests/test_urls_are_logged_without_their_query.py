"""#1473 (L741): a URL is logged without its query string or fragment.

A scrub that finds personal data by its shape cannot see a percent-encoded copy
of it, and a query string percent-encodes the @ of an email and the brackets.
So the query and fragment come off before a URL reaches a log, rather than
trusting a pattern to catch what is inside.

The one URL this repo logged was the profile link in a dropped handle
suggestion, printed to stderr, which the app writes to the run log and
postroll.log. Instagram's share links carry `?igsh=`, a share id that ties the
link to whoever shared it.
"""

from __future__ import annotations

from postroll.ai.enrich_program import _normalise_handle_suggestions
from postroll.url_for_log import url_for_log


def test_the_query_and_fragment_come_off():
    assert url_for_log("https://www.instagram.com/someone/?igsh=abc123#top") == (
        "https://www.instagram.com/someone/")


def test_a_percent_encoded_email_in_the_query_is_gone():
    logged = url_for_log("https://example.com/p?contact=jane%40example.com")
    assert "jane" not in logged and "%40" not in logged


def test_a_url_with_no_query_is_unchanged():
    assert url_for_log("https://example.com/a/b") == "https://example.com/a/b"


def test_text_that_is_not_a_url_is_left_alone_and_none_is_said():
    assert url_for_log("not a url") == "not a url"
    assert url_for_log(None) == "(none)"


def test_a_dropped_suggestion_logs_its_profile_without_the_share_id(capsys):
    _normalise_handle_suggestions([{
        "name": "Jane Doe", "handle": "janedoe",
        "profile_url": "https://www.instagram.com/someoneelse/?igsh=SECRETSHAREID",
    }])
    err = capsys.readouterr().err
    assert "someoneelse" in err, "the warning no longer names the profile"
    assert "SECRETSHAREID" not in err and "igsh" not in err, err


def test_credentials_in_front_of_the_host_come_off_too():
    logged = url_for_log("https://jane:s3cret@example.com:8443/p?x=1")
    assert logged == "https://example.com:8443/p"


def test_an_ipv6_host_keeps_its_brackets():
    assert url_for_log("https://u:p@[::1]:8080/p?x=1") == "https://[::1]:8080/p"


def test_credentials_come_off_even_when_the_url_cannot_be_parsed():
    assert "tok" not in url_for_log("https://user:tok@[bad/p?x=1")
    assert url_for_log("jane:s3cret@example.com/p?x=1") == "example.com/p"
