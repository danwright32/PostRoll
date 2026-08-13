# Guard mutation registry

One recorded perturbation per named guard (#416). `venv/bin/python tools/check_guards.py` (or `make check-guards`) applies each entry's find/replace to the file the guard protects, runs only that test, requires it to FAIL, and restores the file. Run it whenever a guard is added or changed. Perturbations must keep the code compiling: a build error fails every test trivially and proves nothing, so the checker reports it as an error rather than a kill. `tests/test_guard_mutation_registry.py` holds every anchor and test name to the code on every suite run.

## One file per entry

Every entry is one `<name>.json` in this directory, and the file's name is the
entry's `name`. `tools/check_guards.py` reads them by globbing `*.json`, so two
branches adding different guards never touch the same file (#506).

It was a single `guard_mutations.json` until 2026-08-13, when ten commits
across five branches all appended to it and every rebase between them
conflicted in the same place. Each conflict was resolved by hand, and each
resolution was a chance to silently drop an entry, which would remove a guard
proof with no test noticing.

An entry looks like this:

```json
{
  "name": "note-ink",
  "file": "PostRollApp/Sources/Views/NoteView.swift",
  "find": "Color.warmMid",
  "replace": "Color.cream",
  "test": "PostRollTests/NoteTests/testInk",
  "breaks": "the note draws in its own background colour (#123)"
}
```

`name` must match the filename, `test` is either a `PostRollTests/<Class>/<method>`
spec or a `tests/<file>.py::<test>` node id, and `breaks` says in plain words
what goes wrong if the guard stops working, so a SURVIVED verdict reads as a
real consequence rather than a failed assertion.

Nothing else belongs in this directory. `load_registry` refuses a file that is
not `<name>.json` (this README aside) rather than globbing past it, because an
entry skipped in silence is a guard nobody checks while the sweep still reports
a clean run.

## Guards deliberately not registered

Guards deliberately NOT registered, because no compile-safe one line perturbation expresses the defect they catch: UploadPageCropRemovalTests (adding a real crop control is not one line; prose would trip it but proves nothing), the absence guards test_blog_draft_text.py::test_no_module_builds_the_heading_by_hand / test_layout_sidecar.py::test_no_generator_builds_the_name_by_hand / test_blog_meta.py::test_neither_string_can_reach_the_ai_round_trip (their only one line trip is planting the banned text artificially), test_suite_hygiene.py and test_guard_mutation_registry.py (they protect the test suite and this registry themselves), test_bridge_payload_contract.py / test_manifest_contract.py (the one line rename anchor is ambiguous in PythonBridge.swift), test_brand_text.py (removing the route in one line breaks the module's own names), test_event_slug_parity.py (slug internals are not safely one line perturbable), and the measured pixel thresholds in test_golden_frames.py / test_frame_legibility.py / test_screen_reel_logo_contrast.py's contrast checks (failing them takes a rendering change, not a text edit).
