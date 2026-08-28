"""Permission to notify is asked for once the app is up, not from init (#893).

`NotificationService.requestPermission()` was called from `PostRollApp.init()`,
which runs before the app has finished launching. Measured on the development
machine on 2026-08-24: PostRoll had no entry in macOS Notification settings and
no delivered notification on record, which is what a request that never
completed looks like from outside.

If that was the cause then no banner this app has ever sent could arrive,
including every completion Dan has been relying on with the window closed.

The move itself is asserted in Swift, by
`NotificationReachabilityTests.testTheAppAsksOnceItHasFinishedLaunching`, which
drives the delegate. This is the other half: that it is not ALSO still being
asked from `init`, which is the line that has to stay gone. A behaviour test
cannot see a second caller, because the first one satisfies it.

Comments are stripped before the file is read, so a doc comment quoting the old
call cannot satisfy this and, worse, a comment explaining that the call was
removed cannot either (L103).
"""

from __future__ import annotations

from pathlib import Path

from source_text import swift_without_comments

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "PostRollApp" / "Sources" / "PostRollApp.swift"
DELEGATE = ROOT / "PostRollApp" / "Sources" / "Services" / "DeepLinkInbox.swift"


def _code(path: Path = APP) -> str:
    return swift_without_comments(path.read_text())


def test_the_app_file_still_exists_and_declares_the_scene():
    """The positive control. A path that stopped resolving would read as a file
    with no `requestPermission` in it, which is exactly the pass below (L98)."""
    assert "var body: some Scene" in _code(), (
        f"{APP} is not the file that declares the app any more, so the check "
        "below is reading something else and would pass whatever it found")


def test_permission_is_not_asked_from_the_app_initialiser():
    code = _code()

    assert "requestPermission" not in code, (
        "PostRollApp asks for notification permission before the app has "
        "finished launching. That is the leading suspect for a request that "
        "never completed, and it is the one thing standing between every "
        "banner this app sends and the person waiting for one."
    )


def test_the_seam_defaults_to_the_real_request():
    """A seam left unwired is a permission nobody ever asks for, which is the
    same silence one level down (L98).

    Asserted on the source rather than by calling it, because the default has
    to reach `UNUserNotificationCenter`, which raises rather than failing when
    there is no real app around it (#707). The Swift test drives the seam with
    a stand-in and so can never see what the default is.
    """
    code = _code(DELEGATE)

    assert "askForNotificationPermission" in code, (
        f"{DELEGATE} no longer declares the seam, so the Swift test that "
        "drives it is exercising something else")
    assert "NotificationService.shared.requestPermission()" in code, (
        "the delegate's default no longer asks for permission, so the app "
        "asks nobody and every banner it sends is delivered to nobody")
