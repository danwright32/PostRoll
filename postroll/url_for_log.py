"""A URL as it may be written to a log: without its query string or fragment.

A scrub that finds personal data by its shape cannot see a percent-encoded
copy of it, and a query string percent-encodes exactly the characters such a
scrub looks for (the @ of an email, brackets). Share ids, signatures and API
keys travel there too. So the query and fragment come off before a URL is
logged or alerted, rather than trusting a pattern to catch what is inside
(#1473, L741). The scheme, host and path are what a reader needs to know which
page it was.
"""

from __future__ import annotations

from urllib.parse import urlsplit, urlunsplit


def url_for_log(url: str | None) -> str:
    """`url` with its query string and fragment removed, for a log line."""
    if url is None:
        return "(none)"
    try:
        parts = urlsplit(url)
    except ValueError:
        # Not parseable as a URL, so there is no query to find; but it may
        # still hold one after a "?", so cut there rather than pass it through.
        return url.split("?", 1)[0].split("#", 1)[0]
    if not parts.scheme and not parts.netloc:
        return url.split("?", 1)[0].split("#", 1)[0]
    # The host and port only: a netloc can carry `user:token@` in front of
    # them, and that is a credential.
    try:
        host = parts.hostname or ""
        port = parts.port
    except ValueError:
        host, port = parts.netloc.rsplit("@", 1)[-1], None
    netloc = f"{host}:{port}" if port else host
    return urlunsplit((parts.scheme, netloc, parts.path, "", ""))
