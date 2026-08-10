"""How the blog draft's markdown is assembled (#282).

`# title\\n\\nbody` was written out by hand in three places: the Swift exporter
writing `0. Blog/draft.md`, this CLI writing the same file, and the clipboard
text on the review screen. That is the dual-CAPTIONS.txt parity hazard with an
extra copy, and two of the three are invisible to anyone editing the first.

`PostRollApp/Sources/Services/BlogFindingsDisplay.swift` holds the Swift half
(`BlogDraftText.copyText`), which is where these rules came from: it was the
careful one, and the two file writers were not.
`tests/fixtures/blog_draft.json` is the contract both satisfy.
"""

from __future__ import annotations


def blog_draft_text(title: str, body: str) -> str:
    """Markdown heading plus body, ready to paste or write to a file.

    The title is joined here rather than pushed into the body text: the body
    goes through the review passes and the deterministic checks, and a heading
    living inside it would be one more thing those rules have to know about.
    """
    name = (title or "").strip()
    text = (body or "").strip()
    if not name:
        return text
    if not text:
        return f"# {name}"
    # Not added twice: a body that already opens with the heading is left as it
    # is, so copying a post that was pasted back in stays clean.
    if text.startswith(f"# {name}"):
        return text
    return f"# {name}\n\n{text}"
