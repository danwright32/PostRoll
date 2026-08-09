# Backing up and restoring PostRoll's data

Everything PostRoll knows lives in one folder. If you have a copy of that
folder, you can put the app back exactly as it was on any Mac.

## Where your data is

```
~/Library/Application Support/PostRoll
```

To open it: in Finder, choose **Go > Go to Folder** from the menu bar, paste
that path, and press Return.

Inside it:

| Item | What it holds | Replaceable? |
| --- | --- | --- |
| `events.json` | Every event, caption, blog post, OCR result, tag and crop edit | No. This is the important one. |
| `events.json.<date>.bak` | Recent verified-good copies of the above | Copies |
| `analytics.json` | Imported Instagram history and reports | Only by re-exporting from Meta |
| `analytics.json.<date>.bak` | Recent verified-good copies of the above | Copies |
| `photos/` | Every photo you imported | No, unless you still have the originals |
| `programs/` | Program scans and the searchable program PDFs | No. The sites they came from block re-download. |
| `preview/`, `output/` | Generated collages, reels and exports | Yes, regenerated on demand |
| `logs/` | Diagnostic logs | Yes |

The project folder in `~/Documents/PostRoll` is **code only**. It holds no data
and does not need backing up.

## Backing it all up (one action)

1. Open Finder and go to `~/Library/Application Support` (Go > Go to Folder).
2. Right-click the **PostRoll** folder and choose **Compress "PostRoll"**.
3. Drag the resulting `PostRoll.zip` to your backup drive or cloud folder.

Quit PostRoll first if it is open, so nothing is mid-write while it copies.

That zip is a complete backup. Nothing else is needed.

## Restoring everything

1. Quit PostRoll.
2. Unzip your backup.
3. Go to `~/Library/Application Support`.
4. Rename the existing `PostRoll` folder to `PostRoll-old` (do not delete it
   until the restore is confirmed working).
5. Drag the restored `PostRoll` folder in.
6. Open PostRoll and check your events are there.
7. Once you are happy, bin `PostRoll-old`.

## Restoring just the events, from an automatic backup

PostRoll keeps the last few good copies of `events.json` automatically. Each is
stamped with the date and time it was taken, in UTC:

```
events.json.20260808-211500.bak
```

Only a copy that PostRoll could read is ever kept, so a backup is never a
corrupt file. If the app ever starts with an empty or wrong list of events:

1. Quit PostRoll.
2. Go to `~/Library/Application Support/PostRoll`.
3. Rename the current `events.json` to `events.json-bad` (keep it; do not
   delete it).
4. Pick the `.bak` file with the most recent stamp and rename it to
   `events.json` exactly.
5. Open PostRoll.

If that copy is also wrong, repeat with the next most recent stamp. This is why
several are kept rather than one.

The same procedure works for `analytics.json` and its `.bak` files.

## What PostRoll does automatically, and what it does not

**It does:**

- Keep the last 5 verified-good copies of `events.json` and `analytics.json`,
  taken before each save, pruning older ones.
- Refuse to capture a copy it cannot read, so a corrupt file can never displace
  a good backup.
- Write the live file atomically, so a crash mid-save cannot leave a half
  written file in place.
- Move an unreadable file aside instead of overwriting it, and tell you on
  screen when that happens.

**It does not:**

- Back up your photos or programs anywhere. Those are only in that one folder
  until you copy it somewhere else.
- Copy anything off this Mac. A drive failure loses everything unless you have
  made a zip as above, or the folder is covered by Time Machine or a cloud
  backup.

Making that zip somewhere safe, or confirming Time Machine covers your Library
folder, is the one thing worth doing that the app cannot do for you.
