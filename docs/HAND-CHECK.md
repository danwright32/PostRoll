# The hand check

Six questions this repo cannot answer any other way. Everything else about
PostRoll is covered by the suites, and that now includes the alerts, which used
to be steps 5 and 6 here.

This document used to say that XCUITest cannot read into a PostRoll window at
all, which #860 recorded in full. That was measured again on 2026-08-23 and is
false: the harness reads an alert's title, its message and its buttons, presses
them, and sees what happens next. `PostRollApp/UITests/LaunchAlertUITests.swift`
holds what that retired, including the #855 recovery, and carries the evidence.
What is left here is what nothing automated can reach: a window that will not
close under a synthetic Cmd+W, a form whose Return has to come from a real key
press, an alert macOS puts up during termination, the Dock icon, and Notification
Center.

Run it after `make install`, and only when something in this list has been
touched: the window's lifecycle, the New Event sheet's keyboard handling, what
happens when the app is asked to quit, or what the Dock says while work is
running. Nothing prompts you: a step on the merge to main does, naming the steps
whose files the merge touched (#878).

It takes about ten minutes of attention, and steps 5 and 6 spend part of that
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

Steps 5 and 6 need work in flight, which means a real generation, which means an
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

## 1. Closing the window leaves the app running (#847)

Covers: `PostRollApp/Sources/PostRollApp.swift`,
`PostRollApp/Sources/Services/DeepLinkInbox.swift`,
`PostRollApp/Sources/Views/MainWindowView.swift`

```
./PostRollApp/hand-check.sh healthy
```

Press **Cmd+W**.

**Expect:** the window goes. PostRoll stays in the Dock with the running dot
under it, and the menu bar still reads PostRoll.
**Wrong if:** PostRoll disappears from the Dock, or the menu bar changes to
Finder. That is the app quitting, which is what #847 fixed.

Now click the PostRoll icon in the Dock.

**Expect:** the window comes back, with the same (empty) event list.
**Wrong if:** nothing happens, or a second copy launches.

## 2. The New Event command still works with no window (#847)

Covers: `PostRollApp/Sources/PostRollApp.swift`,
`PostRollApp/Sources/Services/DeepLinkInbox.swift`

Still in the same state. Press **Cmd+W** again, then **Cmd+N**.

**Expect:** a window opens with the New Event form on it.
**Wrong if:** the menu item is greyed out, or nothing happens. A command that is
dead while the window is closed is the half of #847 nothing guards.

Press **Escape** to close the form.

## 3. Return commits a form you opened yourself (#848)

Covers: `PostRollApp/Sources/Views/NewEventSheet.swift`,
`PostRollApp/Sources/Views/MainWindowView.swift`,
`PostRollApp/Sources/Models/WindowModals.swift`

```
./PostRollApp/hand-check.sh healthy
```

Press **Cmd+N**, type `Return test` into the name field, press **Return**.

**Expect:** the sheet closes and an event called `Return test` is in the list.
**Wrong if:** nothing happens. Then Create is not the default action for a hand
opened form, and this is Dan's everyday flow.

## 4. Return does NOT commit a form a link opened (#848, #844)

Covers: `PostRollApp/Sources/Views/NewEventSheet.swift`,
`PostRollApp/Sources/Services/DeepLink.swift`,
`PostRollApp/Sources/Services/DeepLinkInbox.swift`,
`PostRollApp/Sources/Models/WindowModals.swift`

With that same window still open:

```
./PostRollApp/hand-check.sh link
```

**Expect:** the New Event form opens, already filled in with `Hand check`,
`Test Company`, `Test Hall`, `Main Stage` and 1 September 2026.
**Wrong if:** the script prints a warning that the set of running copies
changed. That means LaunchServices handed the link to a different PostRoll,
which is pointed at the real library. Quit that copy before going on, and treat
this step as having measured nothing.

Now press **Return**.

**Expect:** nothing happens. The sheet stays open and no event is created.
**Wrong if:** an event called `Hand check` appears. A Return meant for another
app then commits an event Dan has not read, which is what #844 exists to stop.

Click **Create**.

**Expect:** now the event is created.
**Wrong if:** the button does nothing. Both halves matter: a check that only
does one of them passes on a change that does nothing at all.

## 5. Quitting while something is running asks first (#862)

Covers: `PostRollApp/Sources/Services/DeepLinkInbox.swift`,
`PostRollApp/Sources/Models/BackgroundWork.swift`,
`PostRollApp/Sources/Services/JobTracker.swift`

The dialog is an alert macOS puts up during termination, so nothing automated
can read it either.

Something has to be running, so this uses the seeded event step 6 explains,
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
generation. Step 6 needs a whole one, and the two cannot share: that one has to
be allowed to finish.

## 6. Work with no window says so (#863, #879)

Covers: `PostRollApp/Sources/Views/WorkingDockTile.swift`,
`PostRollApp/Sources/Services/NotificationService.swift`,
`PostRollApp/Sources/Models/WorkActivity.swift`,
`PostRollApp/Sources/Services/JobTracker.swift`

Neither half of this is reachable to anything automated: one is drawn on the
Dock icon and the other is a banner from Notification Center.

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
**Also wrong if:** the banner names an event you have never heard of, or says
"an event" without naming one. The name is looked up from the event the run
belongs to, and a placeholder in its place means the lookup failed (#879).

Finally, repeat that last part with the PostRoll window open and in front.

**Expect:** no banner. The screen is already showing the failure, and a banner
on top of it is the noise that teaches you to wave banners away. A banner
appearing here is as much a defect as one failing to appear above.

---

## When something here is wrong

Write down what you saw before changing anything. The value of these steps is
that they are the only observations of this app anybody has, and a symptom
described from memory a day later is usually the wrong symptom: the first
write-up of #855 named a cause that turned out to be wrong, and only the
reproduction survived.
