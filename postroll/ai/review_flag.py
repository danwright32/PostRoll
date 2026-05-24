"""
PostRoll — OCR Flag Review (Conversational Correction)

Stateless per-message handler for the OCR flag review loop. Given a
flag, the conversation so far, and the user's latest message, returns
either an answer (if the user asked a question) or a patch (if the
user submitted a correction).

The backend is stateless: the SwiftUI GUI maintains per-flag conversation
history and passes it in on each call.

Patch shape:
    [
      {"op": "replace", "path": ["pieces", 5], "value": {...new entry}},
      {"op": "remove",  "path": ["pieces", 5]},
      {"op": "add",     "path": ["pieces"], "value": {...}, "index": 6},
      {"op": "replace", "path": ["other"], "value": "..."},
    ]

    - "replace" sets the value at the path (overwriting).
    - "remove" deletes the value at the path.
    - "add" inserts into a list at `index`, or sets a key if path points
      to a dict. For list appends, omit `index`.

Usage:
    python -m postroll.ai.review_flag \\
        --program output/program.json \\
        --flag output/flag.json \\
        --image path/to/page1.heic \\
        --message "the special guest is actually Nutley School of Music"
"""

from __future__ import annotations

import argparse
import copy
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .claude_client import run_json_prompt, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


PROMPT_TEMPLATE = """\
You are helping a photographer review and correct structured data that
was extracted by OCR from a classical music event program. ONE specific
item was flagged as potentially wrong. The photographer and you are
having a short back-and-forth about that flag. Your job is to respond
to the photographer's latest message.

The flag being discussed:
- field_path: {field_path}  (NOTE: this was the path WHEN THE FLAG WAS CREATED — see warning below)
- current_value: {current_value}
- concern: {concern}
- program_context: {program_context}

Full current OCR data (so you have context for how this item fits in):
```json
{ocr_json}
```

**CRITICAL — STALE FIELD PATHS:**
Prior corrections in this session may have mutated lists (inserted,
removed, or replaced items). List indices in the flag's `field_path`
may now point to a DIFFERENT item than the one described in the flag.

Before writing a patch, ALWAYS:
1. Look up the item at the flag's `field_path` in the current OCR data.
2. Check if it still matches `current_value` / `program_context` /
   `concern`. If yes, safe to use that path.
3. If NO — the indices shifted — search the current OCR data to find
   the item the flag actually describes (by title, name, or other
   identifying content) and use THAT index in your patch.
4. Never patch a field just because the path matches. Always verify
   the target is the item the flag is about.

Example: flag says `["pieces", 22, "composer"]` with current_value
"Andrew Lloyd Webber" and the flag is about "Castle on a Cloud". If
pieces[22] in current OCR data is now "The Fork Factory" instead,
scan the `pieces` list for the entry with title "Castle on a Cloud"
and use its current index (e.g. 25) in your patch.

Original program images (read them if the photographer asks you to
double-check something or provide more context about where text
appeared):
{image_list}

Conversation so far (you are the assistant):
{history}

Photographer's latest message:
"{user_message}"

Decide what the photographer's message is:

1. **A question or request for more context** — they want you to look
   again, explain where the text appeared, describe surrounding content,
   etc. In that case:
   - Look at the image(s) as needed.
   - Answer concisely (1-4 sentences).
   - Set patch = null.
   - Set resolved = false.

2. **A correction** — they're telling you what the value should be, or
   how to restructure the data. In that case:
   - Parse their natural-language correction carefully.
   - Build a minimal patch (list of operations) that applies the fix.
   - The patch can include MULTIPLE operations if needed (e.g. "the
     composer isn't listed, she played 4 pieces and Petite Minuet was
     one of them" → remove the bogus composer, restructure one piece
     entry into four).
   - Write a short confirmation message (1-2 sentences) describing
     exactly what you changed.
   - Set resolved = true.

3. **Something ambiguous** — if you can't tell whether it's a question
   or correction, ask one clarifying question. Set patch = null,
   resolved = false.

Patch operation shapes (all paths are lists of string keys / integer
indices like ["pieces", 5, "composer"]):

- Replace a value:
  {{"op": "replace", "path": [...], "value": <new value>}}
- Remove a value (deletes the key from a dict, or the item from a list):
  {{"op": "remove", "path": [...]}}
- Add to a list (omit "index" to append, include "index" to insert):
  {{"op": "add", "path": [...parent list path...], "value": <new item>, "index": 6}}
- Add a new key to a dict:
  {{"op": "add", "path": [...parent dict path...], "key": "new_key", "value": <new value>}}

Return JSON ONLY in this exact shape (no markdown fences):

{{
  "assistant_reply": "what to show the photographer",
  "patch": [<operations>] or null,
  "resolved": true or false
}}

Rules:
- If the user is answering a question you asked, treat it like a new
  correction message.
- Don't second-guess the user — if they say a value is wrong, trust
  them and apply the fix. You're not re-doing OCR, you're helping them
  correct it.
- Don't touch unrelated fields. Only patch things the user is actively
  correcting.
- Use real integer indices in field_path lists, not strings.
- Return ONLY the JSON object. No explanation before or after.
"""


def respond_to_flag(
    *,
    flag: dict[str, Any],
    ocr_data: dict[str, Any],
    image_paths: list[str | Path],
    conversation: list[dict[str, str]],
    user_message: str,
) -> dict[str, Any]:
    """Process one user message in a flag-review conversation.

    Args:
        flag: The flag dict produced by flag_issues.
        ocr_data: Current OCR data (may already include prior patches).
        image_paths: Original program images for re-examination.
        conversation: Prior turns as list of {"role": "assistant"|"user", "text": "..."}.
        user_message: The photographer's latest message.

    Returns:
        {"assistant_reply": str, "patch": list | None, "resolved": bool}
    """
    with tempfile.TemporaryDirectory(prefix="postroll-review-") as tmp:
        tmp_path = Path(tmp)
        staged: list[str] = []
        for i, p in enumerate(image_paths):
            src = Path(p).expanduser().resolve()
            if not src.exists():
                raise FileNotFoundError(f"Program image not found: {src}")
            if src.suffix.lower() in HEIC_SUFFIXES:
                dest = _convert_heic_to_jpeg(src, tmp_path)
            else:
                dest = tmp_path / f"{i:03d}_{src.name}"
                shutil.copy2(src, dest)
            staged.append(str(dest))

        image_list = "\n".join(f"- {p}" for p in staged)
        history_text = _format_history(conversation)

        prompt = PROMPT_TEMPLATE.format(
            field_path=json.dumps(flag.get("field_path", [])),
            current_value=json.dumps(flag.get("current_value", "")),
            concern=flag.get("concern", ""),
            program_context=flag.get("program_context", ""),
            ocr_json=json.dumps(ocr_data, indent=2, ensure_ascii=False),
            image_list=image_list,
            history=history_text,
            user_message=user_message.replace('"', '\\"'),
        )

        data = run_json_prompt(
            prompt,
            timeout=300,
            image_paths=staged,
        )

    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    return {
        "assistant_reply": data.get("assistant_reply", "").strip(),
        "patch": data.get("patch"),  # may be None or a list
        "resolved": bool(data.get("resolved", False)),
    }


def _format_history(conversation: list[dict[str, str]]) -> str:
    if not conversation:
        return "(no prior messages in this conversation)"
    lines = []
    for turn in conversation:
        role = turn.get("role", "?")
        text = turn.get("text", "")
        lines.append(f"[{role}] {text}")
    return "\n".join(lines)


# === Patch application ===


def apply_patch(
    data: dict[str, Any], operations: list[dict[str, Any]]
) -> dict[str, Any]:
    """Apply a list of patch operations to OCR data. Returns a new dict.

    Does not mutate the input.
    """
    result = copy.deepcopy(data)
    for op in operations:
        _apply_op(result, op)
    return result


def _apply_op(data: Any, op: dict[str, Any]) -> None:
    op_type = op.get("op")
    path: list[Any] = list(op.get("path", []))

    if op_type == "replace":
        _set_at_path(data, path, op.get("value"))
    elif op_type == "remove":
        _remove_at_path(data, path)
    elif op_type == "add":
        value = op.get("value")
        if "key" in op:
            # Adding a new key to a dict
            parent = _resolve_path(data, path)
            if not isinstance(parent, dict):
                raise ValueError(f"Cannot add key to non-dict at {path}")
            parent[op["key"]] = value
        else:
            # Adding to a list (append or insert at index)
            parent = _resolve_path(data, path)
            if not isinstance(parent, list):
                raise ValueError(f"Cannot add item to non-list at {path}")
            index = op.get("index")
            if index is None:
                parent.append(value)
            else:
                parent.insert(int(index), value)
    else:
        raise ValueError(f"Unknown patch op: {op_type}")


def _resolve_path(data: Any, path: list[Any]) -> Any:
    """Walk the path and return the node at that location."""
    node = data
    for key in path:
        if isinstance(node, list):
            node = node[int(key)]
        else:
            node = node[key]
    return node


def _set_at_path(data: Any, path: list[Any], value: Any) -> None:
    if not path:
        raise ValueError("Cannot replace root with empty path")
    parent = _resolve_path(data, path[:-1])
    last = path[-1]
    if isinstance(parent, list):
        parent[int(last)] = value
    else:
        parent[last] = value


def _remove_at_path(data: Any, path: list[Any]) -> None:
    if not path:
        raise ValueError("Cannot remove root with empty path")
    parent = _resolve_path(data, path[:-1])
    last = path[-1]
    if isinstance(parent, list):
        del parent[int(last)]
    else:
        del parent[last]


# === CLI (for testing) ===


def main() -> int:
    parser = argparse.ArgumentParser(description="Respond to one flag-review message")
    parser.add_argument(
        "--program", type=Path, required=True, help="Current OCR program JSON"
    )
    parser.add_argument(
        "--flag", type=Path, required=True, help="Flag JSON (single flag object)"
    )
    parser.add_argument(
        "--image",
        action="append",
        required=True,
        help="Path to a program photo (repeat for multi-page)",
    )
    parser.add_argument(
        "--message", required=True, help="The photographer's latest message"
    )
    parser.add_argument(
        "--history",
        type=Path,
        help="Optional prior conversation history JSON (list of {role, text})",
    )
    parser.add_argument(
        "--apply-to",
        type=Path,
        help="If set and the response includes a patch, write the patched OCR data to this path",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Write the response JSON ({assistant_reply, patch, resolved}) to this path. Without it, the response is printed to stdout.",
    )
    args = parser.parse_args()

    ocr_data = json.loads(args.program.read_text(encoding="utf-8"))
    flag = json.loads(args.flag.read_text(encoding="utf-8"))
    conversation: list[dict[str, str]] = []
    if args.history:
        conversation = json.loads(args.history.read_text(encoding="utf-8"))

    try:
        result = respond_to_flag(
            flag=flag,
            ocr_data=ocr_data,
            image_paths=args.image,
            conversation=conversation,
            user_message=args.message,
        )
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    response_text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(response_text + "\n", encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(response_text)

    if args.apply_to and result.get("patch"):
        patched = apply_patch(ocr_data, result["patch"])
        args.apply_to.parent.mkdir(parents=True, exist_ok=True)
        args.apply_to.write_text(
            json.dumps(patched, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"\nwrote patched OCR data to {args.apply_to}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
