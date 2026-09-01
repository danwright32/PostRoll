"""The Meta developer app PostRoll reads Instagram account figures through.

One place for the two facts the app's setup and its code both depend on: which
permissions a token has to carry, and which Graph API version PostRoll speaks.
`docs/META-APP.md` explains the app, mints the token and says what each
permission is for; `tests/test_meta_app_doc.py` holds that document to what is
here, so the prose somebody follows in a Meta console cannot drift away from
what the code actually sends.

Nothing calls this yet. #1002 is the fetch module, and it imports the version
from here rather than pinning a second copy of it.
"""

from __future__ import annotations

#: The Graph API version every request pins.
#:
#: Meta routes an unversioned request to whatever is current, so the answer's
#: SHAPE changes under a caller that never changed. Pinned to a version Meta
#: has published an end date for, so the pin carries an expiry that can be
#: diarised rather than a promise that cannot: v26.0 was current when this was
#: written and has no published end date.
GRAPH_API_VERSION = "v25.0"

#: The date Meta stops answering `GRAPH_API_VERSION`.
#:
#: The whole argument for pinning the older version is that this date exists,
#: so it is recorded beside it rather than left in the changelog (L316).
GRAPH_API_VERSION_AVAILABLE_UNTIL = "2028-07-29"

#: The host every Graph API request goes to.
#:
#: `business_discovery` lives on the Facebook Login flavour of the Instagram
#: API, which is `graph.facebook.com`. The Instagram Login flavour is
#: `graph.instagram.com` and has no such edge at all, which is the setup fork
#: `docs/META-APP.md` warns about, and it fails as a missing edge rather than
#: as a refusal naming the host.
GRAPH_API_HOST = "https://graph.facebook.com"

#: Every permission the token has to carry.
#:
#: The first three are what the `business_discovery` reference requires.
#: `pages_show_list` is how the Instagram account is reached at all, through
#: its Page. `ads_read` is required only because the token's Page role comes
#: through a business portfolio, which is exactly what a system user token is,
#: so the set that worked for the hand made Explorer token during the 2026-08-29
#: probe is one short of the set that ships.
REQUIRED_PERMISSIONS = (
    "instagram_basic",
    "instagram_manage_insights",
    "pages_show_list",
    "pages_read_engagement",
    "ads_read",
)

#: The environment variable the system user token arrives in.
#:
#: The measurement phase reads it from the login shell. When the feature ships
#: the app puts it here from the Keychain, the way it already does with the
#: Anthropic key, so the name is fixed now and the source changes under it.
TOKEN_ENV_VAR = "META_SYSTEM_USER_TOKEN"
