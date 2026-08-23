# The hand check

Six questions this repo cannot answer any other way. Everything else about
PostRoll is covered by the suites; these are here because XCUITest cannot read
into a PostRoll window at all, which #860 records in full, so nothing that runs
on its own can see what the window is showing.

Run it after `make install`, and only when something in this list has been
touched: the window's lifecycle, the New Event sheet's keyboard handling, the
alerts, or the queue behind them. It takes about ten minutes.

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

Run each `hand-check.sh` command from the repo root. Each one quits any running
PostRoll first, so you never have two copies answering.

When you are finished:

```
./PostRollApp/hand-check.sh end
```

---

## 1. Closing the window leaves the app running (#847)

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

Still in the same state. Press **Cmd+W** again, then **Cmd+N**.

**Expect:** a window opens with the New Event form on it.
**Wrong if:** the menu item is greyed out, or nothing happens. A command that is
dead while the window is closed is the half of #847 nothing guards.

Press **Escape** to close the form.

## 3. Return commits a form you opened yourself (#848)

```
./PostRollApp/hand-check.sh healthy
```

Press **Cmd+N**, type `Return test` into the name field, press **Return**.

**Expect:** the sheet closes and an event called `Return test` is in the list.
**Wrong if:** nothing happens. Then Create is not the default action for a hand
opened form, and this is Dan's everyday flow.

## 4. Return does NOT commit a form a link opened (#848, #844)

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

## 5. Each alert says its own words, with its own buttons (#855)

Three separate launches, because each is a different launch condition.

```
./PostRollApp/hand-check.sh no-code-folder
```

**Expect:** one alert titled **PostRoll cannot generate anything**, whose
message names the folder `not-a-checkout` under `~/Library/Caches/
PostRollHandCheck`, with a single **OK** button.
**Wrong if:** the title and the buttons disagree, for example this title over
Try Again and Quit PostRoll. Two halves of one screen can each read as correct
while contradicting each other, which is the whole of #855.

Press **OK**. Expect it to go away and stay away.

```
./PostRollApp/hand-check.sh corrupt-store
```

**Expect:** one alert titled **Saved events could not be read**, saying the
unreadable file was set aside, with an **OK** button. If a backup exists in the
scratch world there will also be a **Restore Latest Backup** button; on a fresh
scratch world there will not be, and that is correct.

```
./PostRollApp/hand-check.sh unreadable-store
```

**Expect:** one alert titled **PostRoll cannot open your events**, with exactly
two buttons, **Try Again** and **Quit PostRoll**.

Press **Escape**, and click outside the alert.

**Expect:** it stays. It is the one alert that refuses to be dismissed, because
the events are still on disk and letting Dan past would show him an empty
library that quietly discards his edits.
**Wrong if:** it closes. Everything he types after that is lost.

## 6. Recovering from the refusal shows what was waiting behind it (#855)

This is the step the whole of #855 turned out to be about, and the one most
worth running after any change to the alerts.

```
./PostRollApp/hand-check.sh both-broken
```

**Expect:** the alert on screen is **PostRoll cannot open your events**, not the
code folder one. Both launch checks fired, and the refusal wins the screen
whichever finished first.

Now repair the store, leaving the alert up:

```
./PostRollApp/hand-check.sh repair-store
```

Press **Try Again**.

**Expect:** the refusal clears AND the alert titled **PostRoll cannot generate
anything** appears in its place, because the code folder is still broken.
**Wrong if:** no alert appears at all. That was the defect: one button press
made two changes, and SwiftUI's report of the alert it tore down landed on the
warning that had just been promoted, dismissing an alert nobody had seen. Worse,
it was recorded as dismissed, so it never came back.

Press **OK** on the code folder alert, then switch to another app and back to
PostRoll.

**Expect:** the warning does not come back. It has now genuinely been waved
away, and re-raising it on every activation is how a warning becomes something
to dismiss on reflex.

---

## When something here is wrong

Write down what you saw before changing anything. The value of these steps is
that they are the only observations of this app anybody has, and a symptom
described from memory a day later is usually the wrong symptom: the first
write-up of #855 named a cause that turned out to be wrong, and only the
reproduction survived.
