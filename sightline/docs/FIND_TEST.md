<!-- labels: important, testing, needs-review -->
# Find and grab: v5 device test

v5 fixes the 2026-10-28 v4 test (`logs/9d77d1e`). Every issue, its root cause and its fix are in **`docs/TEST_LOG.md` T5**. What changed for the tester:

- **Controls without sight.** Each tap gets a click you feel and a sound or words right away.
  - **Tap** = act: speak a command, stop, or check what you hold.
  - **Double tap** = "where are we": the status and what to do next.
  - **Hold 1 s** = reset to the start.
  - Sounds: rising two notes = the microphone is on; bright three notes = found / got it; falling two notes = not found / stopped / not that object; two low notes = reset.
  - With VoiceOver: double tap = act, two-finger double tap = act, swipe up/down for "Status" and "Reset".
  - A single tap now takes about 0.3 s to register, because the app waits to make sure it is not a double tap.
- **Speech should no longer drop out.** Every spoken line is logged (`speech_start` / `speech_finish` / `speech_cancel`). A line that is stuck gets re-said (`speech_stuck`). Audio problems are logged as `audio_route` / `audio_interruption` / `audio_reset`.
- **Small things (keys, rings, earbuds, pens, cards, remote, glasses …)** are searched in four tiles of a sharper photo. Each view costs 4 SAM calls instead of 1.
- **Stricter "do I have it?"** For flat objects, "Grab it" only comes when your palm is over the object. The Spark check compares your hand with a photo of the object taken when it was found, and asks whether you are gripping it (touching is not enough). If your hand moved away and the object is still where it was, the answer is no.
- **Scan says where to turn**: "Turn right slowly. I haven't looked there yet." → later "Point the phone lower, toward the floor, and turn slowly." When it gives up, it also says where the object was last seen, then "A guess: …" from Spark.
- **If it finds the object at the edge of the view**: "Turn a little to your left, to face it." comes before the hand prompt.
- **Room map.** Say **"scan the room"** and turn slowly in a full circle; tap when done. It says "Room saved. I remember 9 things, including …". Afterwards, searches start with "Your keys were last seen to your right, about 1 metre away." when the object is not in view. This works after relaunching the app if ARKit recognises the room within 8 s.
- The log no longer says `api_error` when SAM simply finds nothing. That is now `sam_empty`.

Simulator: run `swift run --package-path Packages/SightlineCore SightlineSim`. All 12 scenarios scored 20/20 on 2026-10-29. `... SightlineSim replay logs/9d77d1e/20261028_194507` replays the recorded book, phone and keys searches with the new rules.

## What gets saved (read this first)
Everything is in the app's Documents folder. Nothing is deleted.

| File | How it grows |
|---|---|
| `find_log_<time>.csv` | **One file per app launch**, rewritten after every event. It always holds every search of that launch (cumulative). v5 adds many speech rows: about 3 per spoken line. |
| `diagnostics/<launch time>/` | **One folder per app launch.** Each event adds new files `NN_<kind>_…`, about 0.3 MB per event. New kind: `room` (one per room-scan view, up to 12). Tiled searches record the full photo once, with the four SAM outputs in `sam.txt` separated by `#tile`. |
| `api_calls.csv` | One file for all launches, appended forever. Included in Export. |
| `room_map/world.arworldmap` + `room_map/inventory.json` | **Overwritten** by each "scan the room". `inventory.json` is also rewritten after every successful find while the map is active. Export includes `inventory.json`; the world map stays on the phone (a few MB). |

New log events in v5:
- Controls: `tap`, `status`, `reset`.
- Speech and audio: `speech_start`, `speech_finish`, `speech_cancel`, `speech_stuck`, `audio_route`, `audio_interruption`, `audio_reset`.
- Search: `sam_empty`, `api_error` (real errors only, with the message), `agent_scan`, `spark_suggest`.
- Hold check: `hold_check_override`; the `hold_check_result` detail now includes `still_there`.
- Room map: `room_hint`, `room_map_load`, `room_map_relocalized`, `room_map_fallback`, `map_start`, `map_view`, `map_view_fail`, `map_finish`, `map_saved`, `map_save_fail`.

## How to run
1. Xcode → Run. The app opens on **Find**.
2. Set up a table with a phone, a book with something right next to it (a USB hub, a box), keys, and a bottle, 40–60 cm in front of you. Hold the iPhone against your chest with your **left hand**, camera facing the table.
3. Move the iPhone slowly for 2–3 s so tracking is normal. This is for testing only; in real use, tracking is normally ready by the time the command is spoken.
4. Run these searches with eyes open, all in **one launch** (like last time, so speech stability is tested):
   1. "find the book". First grab the thing **next to** the book on purpose and lift it. Expected: "I don't think you have the book yet." Then grab the book.
   2. "find my keys" from about 60 cm. Listen for the tiled search (a slightly longer pause).
   3. "find the phone". Grip it and lift it.
   4. **Scan test:** turn about 90° away from the table, then say "find the phone". Follow "Turn left/right slowly". If it finds the phone at the edge of the view, follow "Turn a little … to face it."
   5. An object that is **not** in the room: listen for the direction prompts, the give-up line, and "A guess: …".
   6. Double tap during guidance (status), then hold 1 s (reset).
5. **Room map:** say "scan the room" and turn slowly in a full circle, then tap. Then:
   - hide the keys out of view and say "find my keys" → it should hint where they were;
   - quit the app (swipe it away), relaunch, wait 8 s, and ask for something that is not in view.
6. **Blindfolded tester:** the same steps 4.1–4.3 and 4.6 without help. Note every moment they did not know what to do.
7. Tap **Export** (top right) → AirDrop to the Mac. If the diagnostics folder does not come through: **Files** app → On My iPhone → Sightline → `diagnostics` → long-press the newest folder → Compress → AirDrop the zip.
8. Put everything in `logs/<commit>/` (not in git) and tell me what it said that was wrong or confusing. I will add the results to `docs/TEST_LOG.md` as T6.
