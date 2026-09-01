# The Meta developer app PostRoll depends on

A Meta developer app named **PostRoll** was created on 2026-08-29 so the
collaborator ranking could read follower, like and comment figures for the
accounts an event tags, instead of Dan typing them in by hand.

This document exists because nothing else records that the app is there. If the
automatic account numbers feature ships, the app is a live dependency with a
credential that has to be minted and kept. If the feature is abandoned, the app
is an orphan holding standing read access to a live Instagram account, and the
last section says how to remove it.

## What it can read, measured

Measured on 2026-08-29 against 114 real handles drawn from the events in the
live store:

| Population | Answered by the API |
| --- | --- |
| All real handles | 78 of 114 (68%) |
| Venues | 90% |
| Performers | 64% |

The 36 the API will not answer for are personal accounts rather than
Professional (Business or Creator) ones. `business_discovery` cannot answer for
a personal account at all, so no permission, token or app setting recovers
them. Reading a follower count off the logged out profile page is the separate,
deliberately last route in #1006.

Re-measure this rather than trusting the table: see "Re-measuring the
population" below. These figures are the premise the collaborator ranking's
liveliness floor and assumed rate were fitted to (#1114), and a population that
has moved changes both.

## The permissions, and what each one is for

The token needs five permissions. Four were enough for the hand made Explorer
token used to run the probe. The fifth is required only for the kind of token
that actually ships, which is the trap described in the next section.

| Permission | Why it is needed |
| --- | --- |
| `instagram_basic` | Reads the Instagram Professional account attached to the Page. Every Instagram Graph call needs it. |
| `instagram_manage_insights` | Required by the `business_discovery` edge itself. Without it the edge returns nothing, whatever else is granted. |
| `pages_show_list` | Lets the token see the Facebook Page list. The Instagram account is reached through its Page, so without this there is nothing to reach it by. |
| `pages_read_engagement` | Reads the Page the Instagram account is attached to. Also named as required by the `business_discovery` reference. |
| `ads_read` | Required when the token's Page role was granted through a business portfolio, which is exactly what a system user token is. A personal Explorer token does not need it, so it is easy to leave out and then find the edge refusing a token that looks correctly scoped. |

Source: the `business_discovery` reference at
<https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/business_discovery>,
which lists `instagram_basic`, `instagram_manage_insights` and
`pages_read_engagement`, and adds that a token whose Page role came through
Business Manager also needs `ads_management` or `ads_read`. `ads_read` is the
narrower of the two, so it is the one used.

## The two forks that are easy to get wrong

Both of these cost the better part of an hour on 2026-08-29, and neither
announces itself. They fail as an empty result or an invisible Page rather than
as an error naming the cause.

**1. Facebook Login, not Instagram Login.** Instagram's platform offers two
login flavours. `business_discovery` exists only on the Instagram API with
Facebook Login. Setting the app up with Instagram Login produces an app that
authenticates fine and has no `business_discovery` edge at all.

**2. The app must be connected to the business portfolio.** If the app is not
attached to the portfolio that owns the Page, the Page is simply invisible to
it. `/me/accounts` comes back empty, which reads as an account with no Pages
rather than as a missing connection.

## Minting the token

The app already exists, so this is only the token. It is a **system user**
token, which does not expire, rather than the Explorer token used for the
probe, which lasted about two hours.

1. Open <https://business.facebook.com/settings> and pick the Dan Wright
   Photography business portfolio.
2. In the left menu, open **Users**, then **System users**.
3. **Add**, name it `PostRoll`, role **Admin**, **Create system user**.
4. Select it, **Assign assets**, choose **Apps**, tick the **PostRoll** app,
   turn on **Manage app**, save.
5. **Assign assets** again, choose **Pages**, tick the Dan Wright Photography
   Page, turn on **Manage Page**, save.
6. **Generate new token**, choose the **PostRoll** app, and tick all five
   permissions from the table above.
7. Copy the token immediately. Meta shows it once and never again.

A correct token is about 300 characters and starts `EAA`.

### Finding the Instagram account id

`business_discovery` is a query made **as** an Instagram Professional account,
so it needs Dan's own Instagram user id as well as the token. It is not the
handle and not the numeric id shown anywhere in the Instagram app.

Once the token exists, find the id in the Graph API Explorer at
<https://developers.facebook.com/tools/explorer>: select the PostRoll app,
paste the token, and request
`me/accounts?fields=name,instagram_business_account`. The id is the
`instagram_business_account.id` on the Dan Wright Photography Page. An empty
`data` array here is fork 2 above, not an account with no Pages.

The fetch module (#1002) is what will turn this into a command rather than a
console visit. It does not exist yet.

## Where the token lives

**Today:** nowhere. Nothing in the app or the pipeline reads it yet.

**During the measurement phase:** `META_SYSTEM_USER_TOKEN` in `~/.zshrc`,
alongside the other values the README's Configuration section lists, because
the app runs Python through `zsh -l`.

**When the feature ships:** the login Keychain, entered in Settings the way the
Anthropic API key is, and handed to the Python subprocess through its
environment. That is #1002, and it is not built yet. This paragraph describes
an intention, not a mechanism: check the Settings screen before believing it.

## How it is refreshed

A system user token does not expire, so there is no refresh schedule. It stops
working for three reasons, and all three are somebody doing something
deliberate:

* the system user is deleted or loses the app or the Page,
* a permission is revoked,
* the token is invalidated by hand from the same system user screen.

The failing outcome is `token_rejected` (#1002), and it is not retried, because
retrying cannot fix any of the three. The remedy is to mint a new token by
repeating the steps above.

## The pinned API version

The Graph API version is pinned in one named constant,
`postroll/ai/meta_app.py`, and this document is held to it by
`tests/test_meta_app_doc.py`, so the two cannot drift apart.

Pinned version: **v25.0**, released 2026-02-18, available until **2028-07-29**.

v26.0 was current when this was written (released 2026-07-29). v25.0 is pinned
instead because Meta publishes a date it stops working and has not yet
published one for v26.0, so this pin carries an expiry that can be diarised
rather than a promise that cannot.

## Re-measuring the population

The coverage table above, and every number the collaborator ranking is fitted
to, come from one session against the live API. #1114 commits the population
itself, anonymised, together with the script that recomputes the liveliness
floor and the assumed rate from it, so those numbers become a command anyone
can re-run rather than a paragraph with a date on it.

Until that lands, the table here is a dated sentence. Treat it as one.

## Deleting the app, if this is abandoned

The app holds standing read access to a live Instagram account, so leaving it
in place is not free.

1. Open <https://business.facebook.com/settings>, **Users**, **System users**,
   select `PostRoll`, and delete the system user. This invalidates its token
   immediately.
2. Open <https://developers.facebook.com/apps>, select **PostRoll**, then
   **App settings**, **Advanced**, and delete the app.
3. Remove `META_SYSTEM_USER_TOKEN` from `~/.zshrc`.
4. Delete this document and `postroll/ai/meta_app.py`, so nothing left in the
   repository describes a dependency that no longer exists.
