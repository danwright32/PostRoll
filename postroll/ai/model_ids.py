"""What a model id reduces to, decided once (#361).

`claude-haiku-4-5-20251001` and `claude-haiku-4-5` are the same model for both
things the app asks about an id: what a call costs, and how large an image the
model will accept before reducing it itself.

That rule used to live in two files, as a regex in `usage_log` and as a slice in
`page_regions`. They agreed on every id in use, and were free to disagree on the
next one. A disagreement would have shown up as a wrong cost figure or a wrongly
sized program page rather than as an error, so nothing would have flagged it.

Deliberately tiny and dependency-free: `page_regions` imports it at module level
and must not drag the Anthropic SDK in behind it.
"""

from __future__ import annotations

import re

#: A dated snapshot suffix, e.g. the `-20251001` in `claude-haiku-4-5-20251001`.
_DATED_SUFFIX = re.compile(r"-\d{8}$")


def base_model(model: str) -> str:
    """`claude-haiku-4-5-20251001` -> `claude-haiku-4-5`."""
    return _DATED_SUFFIX.sub("", (model or "").strip())
