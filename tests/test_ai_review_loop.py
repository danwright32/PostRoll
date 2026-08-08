"""Tests for the OCR flag + review loop."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import flag_issues as flag_issues_mod
from postroll.ai import review_flag
from postroll.ai.claude_client import ClaudeError
from postroll.ai.review_flag import apply_patch


# === flag_issues ===


def test_flag_issues_requires_image(sample_photo):
    with pytest.raises(ValueError, match="At least one image"):
        flag_issues_mod.flag_issues({"performers": []}, [])


def test_flag_issues_raises_on_missing_image(tmp_path):
    with pytest.raises(FileNotFoundError):
        flag_issues_mod.flag_issues(
            {"performers": []}, [tmp_path / "nope.jpg"]
        )


def test_flag_issues_normalizes_missing_fields(sample_photo):
    """Model may omit fields — normalization fills defaults."""
    fake_flags = [
        {
            "id": "bad_composer",
            "field_path": ["pieces", 5, "composer"],
            "current_value": "Petale Minuet",
            "suggested_value": "Petite Menuet",
            "concern": "Doesn't look like a composer",
            "program_context": "On page 2, under Sol Lee",
        },
        # Second flag missing several fields
        {"concern": "suspicious"},
    ]
    with patch(
        "postroll.ai.flag_issues.run_json_prompt", return_value=fake_flags
    ):
        result = flag_issues_mod.flag_issues({"pieces": []}, [sample_photo])

    assert len(result) == 2
    assert result[0]["id"] == "bad_composer"
    assert result[0]["field_path"] == ["pieces", 5, "composer"]
    assert result[0]["suggested_value"] == "Petite Menuet"
    # Second flag should have defaults filled
    assert result[1]["id"] == "flag_1"
    assert result[1]["field_path"] == []
    assert result[1]["current_value"] == ""
    assert result[1]["suggested_value"] == ""
    assert result[1]["concern"] == "suspicious"


def test_flag_issues_raises_on_non_array_response(sample_photo):
    with patch(
        "postroll.ai.flag_issues.run_json_prompt",
        return_value={"not": "a list"},
    ):
        with pytest.raises(ClaudeError, match="Expected JSON array"):
            flag_issues_mod.flag_issues({}, [sample_photo])


def test_flag_issues_empty_list_is_valid(sample_photo):
    """If nothing is suspicious, an empty array is a valid response."""
    with patch("postroll.ai.flag_issues.run_json_prompt", return_value=[]):
        result = flag_issues_mod.flag_issues({"performers": []}, [sample_photo])
    assert result == []


# === review_flag (conversational handler) ===


def test_respond_to_flag_question_returns_no_patch(sample_photo):
    """When the user asks a question, response has no patch and resolved=False."""
    fake = {
        "assistant_reply": "I see it on the cover, upper right, near the logo.",
        "patch": None,
        "resolved": False,
    }
    with patch(
        "postroll.ai.review_flag.run_json_prompt", return_value=fake
    ):
        result = review_flag.respond_to_flag(
            flag={
                "id": "bad_guest",
                "field_path": ["other"],
                "current_value": "With Special Guest: Hotel",
                "concern": "'Hotel' looks suspicious",
                "program_context": "Cover page",
            },
            ocr_data={"other": "With Special Guest: Hotel"},
            image_paths=[sample_photo],
            conversation=[],
            user_message="can you provide more context about where you see that?",
        )
    assert result["patch"] is None
    assert result["resolved"] is False
    assert "cover" in result["assistant_reply"]


def test_respond_to_flag_correction_returns_patch(sample_photo):
    fake = {
        "assistant_reply": "Updated. Replaced the special guest with Nutley School of Music.",
        "patch": [
            {
                "op": "replace",
                "path": ["other"],
                "value": "With Special Guest: Nutley School of Music",
            }
        ],
        "resolved": True,
    }
    with patch(
        "postroll.ai.review_flag.run_json_prompt", return_value=fake
    ):
        result = review_flag.respond_to_flag(
            flag={
                "id": "bad_guest",
                "field_path": ["other"],
                "current_value": "With Special Guest: Hotel",
                "concern": "'Hotel' looks suspicious",
                "program_context": "Cover",
            },
            ocr_data={"other": "With Special Guest: Hotel"},
            image_paths=[sample_photo],
            conversation=[],
            user_message="the special guest is actually Nutley School of Music",
        )
    assert result["resolved"] is True
    assert result["patch"] is not None
    assert len(result["patch"]) == 1
    assert result["patch"][0]["op"] == "replace"


def test_respond_to_flag_passes_history_to_prompt(sample_photo):
    captured = {}

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, **kwargs):
        captured["prompt"] = prompt
        return {"assistant_reply": "ok", "patch": None, "resolved": False}

    with patch(
        "postroll.ai.review_flag.run_json_prompt", side_effect=fake_run_json
    ):
        review_flag.respond_to_flag(
            flag={
                "id": "x",
                "field_path": ["other"],
                "current_value": "",
                "concern": "",
                "program_context": "",
            },
            ocr_data={"other": ""},
            image_paths=[sample_photo],
            conversation=[
                {"role": "assistant", "text": "First turn from assistant."},
                {"role": "user", "text": "First turn from user."},
            ],
            user_message="Second turn from user.",
        )

    prompt = captured["prompt"]
    assert "First turn from assistant." in prompt
    assert "First turn from user." in prompt
    assert "Second turn from user." in prompt


def test_respond_to_flag_prompt_warns_about_stale_indices(sample_photo):
    """Prior list-mutating patches shift indices — prompt must warn Claude.

    Regression test for a bug where Castle on a Cloud's field_path
    (originally pieces[22]) was obediently patched after Sol Lee's
    piece split had shifted the real target to pieces[25], corrupting
    an unrelated piece.
    """
    captured = {}

    def fake_run_json(prompt, timeout=300, allowed_dirs=None, allowed_tools=None, image_paths=None, **kwargs):
        captured["prompt"] = prompt
        return {"assistant_reply": "ok", "patch": None, "resolved": False}

    with patch(
        "postroll.ai.review_flag.run_json_prompt", side_effect=fake_run_json
    ):
        review_flag.respond_to_flag(
            flag={
                "id": "x",
                "field_path": ["pieces", 22, "composer"],
                "current_value": "Andrew Lloyd Webber",
                "concern": "Wrong composer",
                "program_context": "",
            },
            ocr_data={"pieces": []},
            image_paths=[sample_photo],
            conversation=[],
            user_message="the correct composer is Schönberg",
        )

    prompt = captured["prompt"]
    # The prompt must tell the model that indices can shift
    assert "STALE FIELD PATHS" in prompt or "stale" in prompt.lower()
    # And must tell it to verify by content before patching
    assert "verify" in prompt.lower() or "re-locate" in prompt.lower() or "search" in prompt.lower()


# === apply_patch ===


def test_apply_patch_replace_scalar():
    data = {"other": "old value"}
    patch = [{"op": "replace", "path": ["other"], "value": "new value"}]
    result = apply_patch(data, patch)
    assert result["other"] == "new value"
    # Input should not be mutated
    assert data["other"] == "old value"


def test_apply_patch_replace_nested():
    data = {"pieces": [{"composer": "Bad"}, {"composer": "Good"}]}
    patch = [
        {"op": "replace", "path": ["pieces", 0, "composer"], "value": "Corrected"}
    ]
    result = apply_patch(data, patch)
    assert result["pieces"][0]["composer"] == "Corrected"
    assert result["pieces"][1]["composer"] == "Good"


def test_apply_patch_replace_whole_list_item():
    data = {"pieces": [{"composer": "X", "title": "A"}]}
    patch = [
        {
            "op": "replace",
            "path": ["pieces", 0],
            "value": {"composer": None, "title": "Best Friends", "movements": [], "notes": None},
        }
    ]
    result = apply_patch(data, patch)
    assert result["pieces"][0]["title"] == "Best Friends"
    assert result["pieces"][0]["composer"] is None


def test_apply_patch_remove_list_item():
    data = {"pieces": [{"title": "A"}, {"title": "B"}, {"title": "C"}]}
    patch = [{"op": "remove", "path": ["pieces", 1]}]
    result = apply_patch(data, patch)
    assert [p["title"] for p in result["pieces"]] == ["A", "C"]


def test_apply_patch_remove_dict_key():
    data = {"a": 1, "b": 2}
    patch = [{"op": "remove", "path": ["b"]}]
    result = apply_patch(data, patch)
    assert result == {"a": 1}


def test_apply_patch_add_to_list_append():
    data = {"pieces": [{"title": "A"}]}
    patch = [
        {"op": "add", "path": ["pieces"], "value": {"title": "B"}}
    ]
    result = apply_patch(data, patch)
    assert [p["title"] for p in result["pieces"]] == ["A", "B"]


def test_apply_patch_add_to_list_at_index():
    data = {"pieces": [{"title": "A"}, {"title": "C"}]}
    patch = [
        {"op": "add", "path": ["pieces"], "value": {"title": "B"}, "index": 1}
    ]
    result = apply_patch(data, patch)
    assert [p["title"] for p in result["pieces"]] == ["A", "B", "C"]


def test_apply_patch_multiple_operations_in_order():
    """A single patch can contain multiple ops (e.g. the Sol Lee case)."""
    data = {
        "pieces": [
            {
                "composer": "Petale Minuet",
                "title": "Best Friends | My Invention | The Dance Band",
                "movements": ["Best Friends", "My Invention", "The Dance Band"],
                "notes": "Performed by Sol Lee (Piano)",
            }
        ]
    }
    patch = [
        # Replace the first entry with a clean Best Friends entry
        {
            "op": "replace",
            "path": ["pieces", 0],
            "value": {
                "composer": None,
                "title": "Best Friends",
                "movements": [],
                "notes": "Performed by Sol Lee (Piano)",
            },
        },
        # Append the other three as separate entries
        {
            "op": "add",
            "path": ["pieces"],
            "value": {
                "composer": None,
                "title": "My Invention",
                "movements": [],
                "notes": "Performed by Sol Lee (Piano)",
            },
        },
        {
            "op": "add",
            "path": ["pieces"],
            "value": {
                "composer": None,
                "title": "The Dance Band",
                "movements": [],
                "notes": "Performed by Sol Lee (Piano)",
            },
        },
        {
            "op": "add",
            "path": ["pieces"],
            "value": {
                "composer": None,
                "title": "Petite Minuet",
                "movements": [],
                "notes": "Performed by Sol Lee (Piano)",
            },
        },
    ]
    result = apply_patch(data, patch)
    titles = [p["title"] for p in result["pieces"]]
    assert titles == ["Best Friends", "My Invention", "The Dance Band", "Petite Minuet"]
    assert all(p["composer"] is None for p in result["pieces"])


def test_apply_patch_rejects_empty_path_for_replace():
    with pytest.raises(ValueError, match="empty path"):
        apply_patch({"a": 1}, [{"op": "replace", "path": [], "value": 2}])


def test_apply_patch_rejects_unknown_op():
    with pytest.raises(ValueError, match="Unknown patch op"):
        apply_patch({"a": 1}, [{"op": "frobnicate", "path": ["a"]}])
