# The hand check

Four questions this repo cannot answer any other way. Everything else about
PostRoll is covered by the suites, and that now includes the alerts, the New
Event form and the window's whole lifecycle, which used to be six of the steps
here.

This document used to open by saying that XCUITest cannot read into a PostRoll
window at all, which #860 recorded in full. That was measured again on
2026-08-23 and 24 and is false in every direction it was believed in. The
harness reads an alert's title, message and buttons; reads a form's fields and
the values a link filled them with, types into them and presses Return; closes
the window with its own close button, watches the app survive it, and reopens
it. `LaunchAlertUITests`, `NewEventFormUITests` and `WindowLifecycleUITests`
hold what that retired, and carry the evidence.

Re-testing it was worth more than the automation. Step 2 used to ask whether
the New Event command still works with no window, and nobody had ever run it:
it did not. The command recorded a request and opened nothing, so the form
turned up later on whatever window opened next (#884).

What is left here is what nothing automated can reach: which copy of PostRoll
macOS hands a real link to, an alert macOS puts up during termination, the Dock
icon, Notification Center, and what your own saved handles actually say.

Run it after `make install`, and only when something in this list has been
touched: deep links, what happens when the app is asked to quit, or what the
Dock says while work is running. Nothing prompts you: a step on the merge to
main does, naming the steps whose files the merge touched (#878).

It takes about ten minutes of attention, and steps 2 and 3 spend part of that
waiting on a real generation.

Each step says what should happen precisely enough to be wrong. If a step's
result is "it looked fine", the step is not written well enough and is worth
fixing rather than passing.

## Before you start

```
make install
```

Every step below points the app at a scratch library and a scratch code folder,
so nothing here can touch the real events.json. That is done by the setup
script rather than by hand, because several steps deliberately break the store.

Steps 2 and 3 need work in flight, which means a real generation, which means an
event with photographs on it. Those two ask for a folder to copy a handful out
of; the copies live in the scratch world and the folder itself is only ever
read. Between them they cost about one and a half runs against the API.

Run each `hand-check.sh` command from the repo root. Each one quits any running
PostRoll first, so you never have two copies answering.

When you are finished:

```
./PostRollApp/hand-check.sh end
```

---

## 1. A real link reaches the copy you think it does (#844, #840)

Covers: `PostRollApp/Sources/Services/DeepLink.swift`,
`PostRollApp/Sources/Services/DeepLinkInbox.swift`

What the form DOES with a link is asserted now, in `NewEventFormUITests`:
that Return commits a form opened by hand and does not commit one a link
raised, and that Create Event still works. What no test can ask is which copy
of PostRoll macOS hands a real link to, because that depends on what this
machine has registered over time, and fourteen PostRoll bundles have been
registered on it. The UI test deliberately names the bundle to take that choice
away, which is right for a test and is the exact question left over here.

Start it in a scratch world with a window open:

```
./PostRollApp/hand-check.sh healthy
```

Then fire the link. It acts on the world that is already there rather than
building its own, because what it is asking about is which running copy
answers.

```
./PostRollApp/hand-check.sh link
```

**Expect:** the form opens on the copy the script just launched, already filled
in with `Hand check`, `Test Company`, `Test Hall`, `Main Stage` and 1 September
2026, and the script reports the same set of running copies before and after.
**Wrong if:** the script prints a warning that the set of running copies
changed, or the window that came forward is not the one pointed at the scratch
world. That means macOS handed the link to a different PostRoll, which is
pointed at the real library, and everything it writes goes there. PostRoll says
so itself when a link reaches a copy that is not the installed one; that notice
is the other half of this step.

Press **Escape** to close the form.

## 2. Quitting while something is running asks first (#862)

Covers: `PostRollApp/Sources/Services/DeepLinkInbox.swift`,
`PostRollApp/Sources/Models/BackgroundWork.swift`,
`PostRollApp/Sources/Services/JobTracker.swift`

The dialog is an alert macOS puts up during termination, so nothing automated
can read it either.

Something has to be running, so this uses the seeded event step 3 explains,
for the same reason: a generation cannot be started from an empty store.

```
./PostRollApp/hand-check.sh seeded ~/Pictures/some-shoot
```

Open **Hand check run** and press **Generate All**. While it is running, press
**Cmd+Q**.

**Expect:** a dialog titled **PostRoll is still working**, whose message names
what is running (for example "a week is still generating"), with **Keep
Working** and **Quit Anyway**.
**Wrong if:** the app just quits. That is the defect: every route out except the
update sheet used to terminate with no check at all.
**Also wrong if:** the message says something is running that is not, or fails
to name something that is. The list is derived from the nine owners of
background work, so a wrong name means the derivation is reading the wrong
thing.

Press **Keep Working**.

**Expect:** the app stays, and the run carries on from where it was rather than
restarting.

Now press **Cmd+Q** again and press **Quit Anyway**.

**Expect:** PostRoll quits.
**Wrong if:** it stays. Quit Anyway has to be a real way out, or a logout turns
into a machine that will not log out.

Finally, with nothing running, press **Cmd+Q**.

**Expect:** it quits immediately with no dialog. A confirmation that appears
every time is one that gets clicked through on reflex, taking the real one with
it.

Quit Anyway takes the run with it, so this step costs part of a real
generation. Step 3 needs a whole one, and the two cannot share: that one has to
be allowed to finish.

## 3. Work with no window says so (#863, #879)

Covers: `PostRollApp/Sources/Views/WorkingDockTile.swift`,
`PostRollApp/Sources/Services/NotificationService.swift`,
`PostRollApp/Sources/Models/WorkActivity.swift`,
`PostRollApp/Sources/Services/JobTracker.swift`

Neither half of this is reachable to anything automated: one is drawn on the
Dock icon and the other is a banner from Notification Center.

**Some of it is, now (#950).** Re-measured 2026-09-04 rather than taken from the
recorded reason, which had already been wrong once. What a person still has to
do here is narrower than it was:

* The band being DRAWN, the icon being behind it, the field not being the band's
  own colour, the clock's digits being on the band, and the clock CHANGING with
  the time it is given are all measured in `WorkingDockTileTests`. The last two
  are new: "watch it for five seconds" was asking a person to check that a
  number moves, and a tile rendered at 0:05 and at 1:05 answers that without
  anybody watching.
* That the band stays out of the top right corner, where macOS draws the Dock
  badge, is measured too. That is the half of the badge question that is ours.

What is still genuinely out of reach, and why:

* That macOS actually composites our tile onto the Dock. We can draw it; only
  the system can show it.
* That the BADGE is legible beside the band. macOS draws the badge, not this
  process, so nothing here can measure it.
* The Notification Center banner. It is another process's surface.

This step needs an event a generation can actually be started from, which none
of the states above provide: they all build an empty store, and Generate All
stays disabled until a day has a photo on it. So this one seeds an event of its
own out of a folder of photographs you point it at. Up to eight are copied into
the scratch world, dealt across Monday and Wednesday so the run is long enough
to watch, and it says how many it took of how many it found.

```
./PostRollApp/hand-check.sh seeded ~/Pictures/some-shoot
```

Open **Hand check run**, press **Generate All**, then press **Cmd+W** to close
the window. This is a real run against the API on photographs nobody wants
captions for, which is what it costs to see the mark that only appears while
work is happening.

**Expect:** a black band across the foot of the PostRoll Dock icon, with an
elapsed clock on it, over the ordinary PostRoll icon.
**Wrong if:** there is no band. Then work with no window is invisible again,
which is the whole of #863.
**Also wrong if:** the band is sitting on an empty tile with no icon behind it.
`WorkingDockTile` draws the app icon optionally, so an icon that came back nil
would fail exactly this way and say nothing (#879).
**Also wrong if:** the clock is frozen. A mark that does not move cannot tell a
run that is progressing from one that is wedged or dead, and telling those apart
is the only reason the number is there. Watch it for five seconds rather than
glancing: it moves once a second.

Wait for the run to finish. It takes about six minutes.

**Expect:** the band goes, and a banner titled **Hand check run: Captions
Ready**. The Dock badge then shows a count of finished work waiting to be looked
at, which is a different mark in a different place from the band.
**Wrong if:** the badge and the band are ever drawn on top of each other, or one
hides the other. They are set independently, by
`NotificationService.incrementBadge` and by the custom view installed beside it,
and whether both are legible at once has never been looked at (#879).

Now make one fail. Same event, with the app pointed at a folder that is not a
checkout, so the run starts and then dies where the pipeline would have been:

```
./PostRollApp/hand-check.sh seeded ~/Pictures/some-shoot --no-code-folder
```

Press **OK** on the code folder alert, open the event, press **Generate All**,
then **Cmd+W**. It fails within a few seconds and costs nothing: the pipeline is
never reached.

**Expect:** a banner titled **Hand check run: generating stopped**, whose body
gives the reason.
**Wrong if:** nothing arrives. Every notification this app sent used to be a
completion, so a run that died with the window closed produced exactly the same
evidence as one still going, which is none.

**Before deciding nothing arrived is the app's fault**, ask whether a banner
could have arrived at all. Two things were measured on the development machine
on 2026-08-24 and neither is proof on its own: PostRoll has no entry in macOS
Notification settings, read through the preferences daemon, and it has no
delivered notification on record. The second is weaker than it sounds, because
that database only keeps about four days. Together they are enough to check
before blaming the app, and the app answers it directly now, once per launch:

```
log show --predicate 'process == "PostRoll"' --last 30m --info | grep NotificationService
```

Nothing from that line means permission was granted and the silence is the
app's. A complaint there names the cause and the remedy, and the remedy for a
refusal is System Settings > Notifications (#879, #890).
**Also wrong if:** the banner names an event you have never heard of, or says
"an event" without naming one. The name is looked up from the event the run
belongs to, and a placeholder in its place means the lookup failed (#879).

Finally, repeat that last part with the PostRoll window open and in front.

**Expect:** no banner. The screen is already showing the failure, and a banner
on top of it is the noise that teaches you to wave banners away. A banner
appearing here is as much a defect as one failing to appear above.

---

## 4. Settings says what the app has learned, and what it cannot announce (#903, #894, #918)

Covers: `PostRollApp/Sources/Views/SettingsView.swift`,
`PostRollApp/Sources/Views/SavedHandlesSection.swift`,
`PostRollApp/Sources/Models/NotificationNotice.swift`

Since #918 both of these are on the review sheet, so how they LOOK is reviewable
by looking at `make review-sheet` and does not need you. Two things are left
that a render cannot answer, and they are the two the panes exist for.

This step costs nothing: no generation, no API call, and about two minutes.

It runs against your REAL library rather than a scratch one, deliberately, and
it is the only step here that does. The handle book lives in the app's own
preferences and there is no scratch copy of it, so a setup that planted one
would be writing into the book you have built up across every event you have
shot. Reading yours is also the more useful check: an invented book can only
tell you the list renders, and what this pane was opened for (#903) is finding
out that a real entry is wrong.

So do not run a `hand-check.sh` state first. If you have just finished step 3,
run `./PostRollApp/hand-check.sh end` before this one, so the app is pointed
back at your own data.

Open **PostRoll > Settings**.

**The saved handles.** Three panes: Performers, Organisations, Venues. Read
every row. Each says a name the app has learned and the value it will fill in
from now on. What you are looking for is a value that is wrong, because a wrong
one is filled into every future event at that name and there was no other way to
see it before #903:

- a handle for the wrong account, most likely on a common performer name, since
  the book matches on the name alone and the next Sarah Chen gets the last one's
- an organisation whose value is a sentence rather than an account, which is
  allowed and is why that pane says so in its footer, but is worth seeing
- anything you do not recognise at all

Correct or delete what is wrong. That is the pane working, not a defect.

Two things to judge while you are there. Every row has to be readable, including
the name on the left, which is drawn quieter than the value. And the names read
back lowercased, because that is the key the book is stored under rather than
the name as you typed it: that is expected, and worth saying out loud so it is
not reported as a bug.

If a pane says "Nothing learned yet", that is the honest empty state and not a
failure. It means no event has been advanced past Review since the book was last
cleared.

**The notifications banner.** This one is on the main window, not in Settings,
which is worth knowing because the issue that asked for this step said otherwise.

Look at the top of the main window. What should be there depends on the answer
macOS has given PostRoll, so check that first, in **System Settings >
Notifications > PostRoll**:

- **allowed**: there must be NO bell banner. A banner here is a false alarm, and
  a false alarm on a warning about silence is the one that teaches you to ignore
  the real one.
- **turned off**: a warning banner with a struck-through bell, saying every
  completion and every failed run is announced to nobody, and naming System
  Settings > Notifications as where to turn it back on.

If it is allowed and you want to see the other state, turn PostRoll off in System
Settings, relaunch PostRoll, and turn it back on afterwards. Relaunch is needed:
the app asks once, at launch, so a permission changed underneath a running copy
is not noticed until the next one.

The sentence has to name what will not arrive rather than only the state.
"Notifications are not permitted" tells you nothing about the captions you will
never be told are ready, which is the whole reason this banner has the wording it
has.

---

## When something here is wrong

Write down what you saw before changing anything. The value of these steps is
that they are the only observations of this app anybody has, and a symptom
described from memory a day later is usually the wrong symptom: the first
write-up of #855 named a cause that turned out to be wrong, and only the
reproduction survived.
