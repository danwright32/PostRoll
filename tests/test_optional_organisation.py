"""An event with no organisation, through the caption pipeline (#689).

Dan can now create an event with a name and nothing else: a director hiring him
to shoot a play is not an organisation, and there is nothing to type. Every
reader that assumed the field was filled in starts seeing an empty one.

The worst of those readers is the caption prompt. Left as it was, it carries an
Organization line with nothing after it and asks for a hashtag derived from an
empty string, and a model asked to derive a hashtag from nothing invents one.
An invented organisation hashtag goes out on a real post and reads as a fact,
which is worse than an omitted one, because an omission at least reads as
missing (L161).

So these assert the prompt itself, not the model's behaviour: what the prompt
does not ask for cannot come back wrong for this reason.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from postroll.ai import org_prompt
from postroll.ai.generate_captions import PROMPT_TEMPLATE, org_prompt_lines

REPO_ROOT = Path(__file__).resolve().parent.parent


# ── the two lines the prompt says about an organisation ──────────────────────


def test_an_organisation_that_is_there_is_named_and_asked_for():
    """The control. Everything below is about the empty case, and a helper that
    had simply stopped emitting either line would satisfy all of it (L159)."""
    detail, rule = org_prompt_lines("DCINY")
    assert "DCINY" in detail
    assert "Organization: DCINY" in detail
    assert 'derived from "DCINY"' in rule


@pytest.mark.parametrize("org", ["", "   ", "\n", "\t "])
def test_no_organisation_is_never_written_as_an_empty_value(org):
    detail, rule = org_prompt_lines(org)
    assert "Organization: " not in detail, (
        f"the prompt still carries a blank detail line: {detail!r}"
    )
    assert "derived from" not in rule, (
        f"the model is asked to derive a hashtag from nothing: {rule!r}"
    )


@pytest.mark.parametrize("org", ["", "   "])
def test_the_absence_is_stated_in_the_details_too(org):
    """Not only in the hashtag rule. The details list is where the model reads
    what the event IS, and a list that simply skips the organisation invites it
    to supply one from the venue."""
    detail, _ = org_prompt_lines(org)
    assert "NO organization" in detail, detail
    assert "do not infer one" in detail.lower(), detail


@pytest.mark.parametrize("org", ["", "   "])
def test_no_organisation_is_stated_rather_than_merely_left_out(org):
    """A rule that is missing leaves the model to fill the gap from the venue or
    the event name. A rule that is stated is one it can follow."""
    _, rule = org_prompt_lines(org)
    assert "NO organization" in rule
    assert "invent" in rule


# ── the whole prompt, built ──────────────────────────────────────────────────


def _prompt_with(org: str) -> str:
    """The real template, filled the way generate_caption fills it.

    Through the template rather than through a copy of the two lines, because
    the defect being guarded against is a value reaching the PROMPT, and a test
    that only ever looked at the helper could not notice the template growing a
    third place that names the organisation.
    """
    detail, rule = org_prompt_lines(org)
    fields = {name: f"<{name}>" for name in _template_fields()}
    fields["org_line"] = detail
    fields["org_hashtag_rule"] = rule
    return PROMPT_TEMPLATE.format(**fields)


def _template_fields() -> set[str]:
    import string
    return {f for _, f, _, _ in string.Formatter().parse(PROMPT_TEMPLATE) if f}


def test_the_built_prompt_never_says_organization_with_nothing_after_it():
    prompt = _prompt_with("")
    assert "Organization:" not in prompt, (
        "the prompt carries an Organization line with nothing on it, which the "
        "model will fill in for itself"
    )
    assert 'derived from ""' not in prompt


def test_the_built_prompt_still_names_a_real_organisation():
    prompt = _prompt_with("DCINY")
    assert "Organization: DCINY" in prompt
    assert 'organization hashtag derived from "DCINY"' in prompt


def test_the_organisation_is_named_in_exactly_one_place_in_the_prompt():
    """Two places demanding an organisation hashtag is two places to keep in
    step, and the one that gets missed is the one that keeps asking (L41)."""
    prompt = _prompt_with("")
    assert prompt.lower().count("organization hashtag") == 1, (
        "more than one line in the prompt talks about an organization hashtag, "
        "so making it conditional in one of them is not enough"
    )


# ── the blog prompt, which names the organisation too ────────────────────────


def _blog_prompt_with(org: str) -> str:
    from postroll.ai.generate_blog import PROMPT_TEMPLATE as BLOG_TEMPLATE
    import string
    fields = {f for _, f, _, _ in string.Formatter().parse(BLOG_TEMPLATE) if f}
    values = {name: f"<{name}>" for name in fields}
    values["org_line"] = org_prompt.detail_line(org, note="  <note>")
    return BLOG_TEMPLATE.format(**values)


def test_the_blog_prompt_never_says_organization_with_nothing_after_it():
    """The caption is not the only prompt that names it. The blog's line carries
    an instruction to write the name EXACTLY as given, which asked about nothing
    is an instruction to produce something."""
    prompt = _blog_prompt_with("")
    assert "Organization: " not in prompt, prompt[:400]
    assert "NO organization" in prompt


def test_the_blog_prompt_still_names_a_real_organisation():
    assert "Organization: DCINY" in _blog_prompt_with("DCINY")


def test_both_prompts_state_the_absence_the_same_way():
    """One module, so the two cannot drift into telling the model different
    things about the same event (L41)."""
    caption_detail, _ = org_prompt_lines("")
    assert caption_detail == org_prompt.detail_line("")


# ── the command line ─────────────────────────────────────────────────────────


def test_the_command_line_does_not_require_an_organisation():
    """The gate that would otherwise refuse the whole run.

    Run for real rather than by reading the argparse setup: `required=True`
    fails at parse time with an exit code and nothing generated, and that is a
    behaviour rather than a spelling.
    """
    result = subprocess.run(
        [sys.executable, "-m", "postroll.ai.generate_captions"],
        capture_output=True, text=True, cwd=REPO_ROOT, timeout=120,
    )

    # argparse exits 2 and lists exactly what it will not run without, before
    # any photo is read or any model is called, so this is the whole behaviour
    # and it costs nothing.
    assert result.returncode == 2, result.stdout + result.stderr

    # The refusal line alone, not the whole of stderr: the usage banner above it
    # names every OPTION there is, `--org` among them, so a check over all of
    # stderr would be answered by the option existing at all rather than by it
    # being required (L156).
    required = [line for line in result.stderr.splitlines()
                if "the following arguments are required" in line]
    assert len(required) == 1, result.stderr
    assert "--org" not in required[0], (
        "the run is still refused without an organisation, so an event with "
        f"none can never generate a caption at all: {required[0]}"
    )
    # The control: something is still required, so an argparse that had stopped
    # refusing anything could not satisfy this (L159).
    assert "--event" in required[0], required[0]
