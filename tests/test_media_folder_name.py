"""#1448: generate_media renders into the folder the app names, never one it derives.

The folder used to be rebuilt here from the organisation, venue and name. Those
can now be edited after an event has been rendered, and the app pins the name
it was rendered under. A folder rebuilt here from the edited fields would be a
new one, and the app's orphan sweep deletes every preview folder no event
resolves to, so the week would render into a folder that is then thrown away.
"""

from __future__ import annotations

import pytest


def _manifest(photo, **overrides) -> dict:
    manifest = {
        "event": "Broadway Undressed",
        "org": "",
        "venue": "54 Below",
        "date": "2026-09-17",
        "folder_name": "tom_guthrie_broadway_undressed_2026-09-17",
        "days": {"thursday": {"photos": [str(photo)]}},
    }
    manifest.update(overrides)
    return manifest


def test_the_week_renders_into_the_folder_the_app_named(sample_photo, tmp_output):
    from postroll.ai.generate_media import generate_media

    results = generate_media(_manifest(sample_photo), tmp_output,
                             static_only=True, only_days={"thursday"})

    assert (tmp_output / "tom_guthrie_broadway_undressed_2026-09-17").is_dir()
    assert not (tmp_output / "54_below_broadway_undressed_2026-09-17").exists(), (
        "the edited details must not name a second folder")
    assert "thursday" not in results["errors"], results["errors"]


@pytest.mark.parametrize("missing", [None, ""])
def test_a_manifest_without_a_folder_name_is_refused(sample_photo, tmp_output, missing):
    # Deriving one instead would be right for every event until the first one
    # that was edited, and then silently render its week into a folder the
    # app deletes.
    from postroll.ai.generate_media import generate_media

    manifest = _manifest(sample_photo)
    if missing is None:
        del manifest["folder_name"]
    else:
        manifest["folder_name"] = missing

    before = set(tmp_output.iterdir())
    with pytest.raises(ValueError, match="folder_name"):
        generate_media(manifest, tmp_output, static_only=True)

    assert set(tmp_output.iterdir()) == before, "no folder is made before the refusal"


@pytest.mark.parametrize("hostile", ["../escape", "a/b", "/abs", ".", ".."])
def test_a_folder_name_that_is_not_one_folder_is_refused(sample_photo, tmp_output, hostile):
    # It is joined onto the output directory, so anything but a single plain
    # segment would write somewhere else.
    from postroll.ai.generate_media import generate_media

    with pytest.raises(ValueError, match="folder_name"):
        generate_media(_manifest(sample_photo, folder_name=hostile), tmp_output,
                       static_only=True)
