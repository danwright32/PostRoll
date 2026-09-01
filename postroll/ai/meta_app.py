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
#: Four, MEASURED on 2026-09-01 rather than read off the reference. A system
#: user token carrying exactly these answered `business_discovery` for two
#: separate target accounts, returning follower count, media count, per post
#: like and comment counts and `media_product_type`.
#:
#: `instagram_basic`, `instagram_manage_insights` and `pages_read_engagement`
#: are what the `business_discovery` reference requires. `pages_show_list` is
#: how the Instagram account is reached at all, through its Page.
#:
#: The reference ALSO says a token whose Page role was granted through Business
#: Manager needs `ads_management` or `ads_read`, and a system user token is
#: exactly that, so `ads_read` was documented here first. It is wrong twice
#: over: the permission is not offered in the token picker at all unless the app
#: carries the Marketing API product, and the edge answers without it. Recorded
#: rather than quietly dropped, because the reference still says otherwise and
#: the next person to read it will reach for the same fifth permission.
REQUIRED_PERMISSIONS = (
    "instagram_basic",
    "instagram_manage_insights",
    "pages_show_list",
    "pages_read_engagement",
)

#: Permissions the reference names that this token does NOT carry.
#:
#: Named here rather than left as prose, so `docs/META-APP.md` may explain why
#: they are absent without the document guard reading them as a fifth and sixth
#: thing to grant. A permission moved into REQUIRED_PERMISSIONS must leave this
#: tuple, and the guard asserts the two never overlap: a permission listed as
#: both required and deliberately absent is a contradiction the document would
#: then faithfully reproduce.
NOT_REQUIRED_DESPITE_THE_REFERENCE = (
    "ads_management",
    "ads_read",
)

#: The Instagram Professional account every query is made AS.
#:
#: `business_discovery` is not a lookup, it is a field on YOUR OWN account, so
#: every request needs this id as well as the token. It is the Dan Wright
#: Photography account, read from `/me/accounts` on 2026-09-01 and recorded so
#: the fetch does not spend a call rediscovering it on every run.
#:
#: Re-derivable rather than magic: it is `instagram_business_account.id` on the
#: Page that `/me/accounts?fields=name,instagram_business_account` returns.
QUERYING_ACCOUNT_ID = "17841403653163673"

#: The environment variable the system user token arrives in.
#:
#: The measurement phase reads it from the login shell. When the feature ships
#: the app puts it here from the Keychain, the way it already does with the
#: Anthropic key, so the name is fixed now and the source changes under it.
TOKEN_ENV_VAR = "META_SYSTEM_USER_TOKEN"
