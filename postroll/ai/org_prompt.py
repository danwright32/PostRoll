"""What a prompt says about an event's organisation, in one place (#689).

An event can have no organisation: a director hiring Dan to shoot a play is not
one, and there is nothing to type. Two prompts name the organisation, the
caption's and the blog's, and left as they were both write "- Organization: "
with nothing after it and then instruct the model about a value that is not
there. A model asked to derive a hashtag from nothing, or to write a name
"exactly as given" when nothing was given, fills the gap itself, and an invented
organisation goes out on a real post reading as a fact. That is worse than an
omission, which at least reads as missing (L161).

One module rather than the same two branches written twice, because the two
prompts would drift and the one that drifts is the one nobody is looking at
(L30, L41).

The absence is STATED rather than merely left out. A rule that disappears leaves
the model to fill the gap from the venue or the programme; a rule that is there
is one it can follow.
"""

from __future__ import annotations


def detail_line(org: str, *, note: str = "", absent: str = "") -> str:
    """The "- Organization: ..." line, or the absence, ready to interpolate.

    Carries its own leading newline so an absent organisation leaves no blank
    line behind in the details list.

    `note` is whatever the prompt wants to say about a real organisation (the
    blog insists on the name being written exactly as given). `absent` is what
    to say when there is none; the default states the absence plainly.
    """
    if org.strip():
        return f"\n- Organization: {org}{note}"
    return absent or (
        "\n- There is NO organization for this event. Do not name one, and do "
        "not infer one from the venue, the programme or the event name."
    )


def hashtag_rule(org: str) -> str:
    """The caption prompt's line about an organisation hashtag.

    Its own function because the caption is the only prompt that asks for
    hashtags, and because this is the line that produced the worst available
    failure: a hashtag derived from an empty string is one the model makes up.
    """
    if org.strip():
        return f'- Include an organization hashtag derived from "{org}".'
    return ("- This event has NO organization. Do NOT include an organization "
            "hashtag, and do not invent an organization name, handle or hashtag "
            "for it from the venue, the programme or anywhere else.")
