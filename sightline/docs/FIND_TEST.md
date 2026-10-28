<!-- labels: important, testing, needs-review -->
# Find and grab — v4 device test

v4 builds on the 2026-10-28 v3 recording (`logs/20261028_131855`): no left bias any more (target and hand points land back exactly on the photo), but flat things (phone, ruler) were never detected as picked up, the bottle could not be reached (palm stuck 7–8 cm off), "Down, about 40 centimetres" was repeated four times, and "not found" ended the search. Changes:
- **The object is a 3D shape, not a point** (`ObjectModel`): SAM mask + LiDAR at lock, plus the table it stands on. Flat objects (phone, ruler, < 3.5 cm) sit on the table plane, which fixes the glossy-phone depth. Guidance steers the palm to the **nearest point of the object's surface**, so a bottle can be gripped from the side.
- **Grasp from fingertips** (`GraspAssessment`): ≥ 2 fingertips within 3 cm of the surface (or one + palm within 7 cm), held 0.3 s → "Grab it". Thumb on the opposite side of the fingers, then the hand moves away → "Got it." Any other hand leaving after "Grab it" → automatic Spark photo check. Tall objects still also use the LiDAR "table visible again" check.
- **Keep scanning** when the object is not in view: "I don't see the phone here. Turn slowly to your left and right. I'll keep looking." A soft **tick** = one new view being checked (SAM). At most 8 scan calls ($0.02), only for views ≥ 25° from those already checked and only when the camera is steady. "Still looking. Keep turning slowly." every 8 s of silence. Gives up with "I looked around and couldn't find the phone. Tap to try again." and, if it saw the object earlier in this launch, "Earlier, it was to your right, about 60 centimetres."
- **Obstacle warning**: things standing within 60 cm of the target (from the lock depth) that lie on the straight path from the hand → "Careful, something is in the way, to the left of your hand." At most every 10 s.
- **Shorter guidance**: first prompt "Reach your hand forward and down, toward it." (not "chest height"); a repeat in the same direction is "Keep going down." instead of a new number.
- No extra SAM re-lock at the start of a search (bug in v3). `api_calls.csv` is now in **Export**.

Simulator (Mac, free): `swift run --package-path Packages/SightlineCore SightlineSim` → 12 scenarios × 20 runs, all 20/20 on 2026-10-28. `... SightlineSim replay logs/20261028_131855` re-runs the object model and grasp check on the real recording.

## Flow
1. Tap anywhere, say "find the phone". It says "Looking for the phone." at once.
2. SAM → object shape (green dot = its centre). Unsure (< 0.75) → "Checking." + Spark yes/no first. Several similar → Spark picks or asks you.
3. **Not found → scanning** (see above). Tap = stop.
4. "Found the phone. It's to your right, about 60 centimetres." → "Reach your hand forward and down, toward it."
5. "I see your hand." → one instruction while the hand is still, silence while it moves, "Stop." when there.
6. Fingertips on it → "Stop. It's at your hand. Grab it."
7. Grip and lift → "Got it. Well done." If the grip is unclear, lifting away says "Checking." and Spark looks at your hand: yes → "Got it. Well done."; no → "I don't think you have the phone yet. I'll guide you again."; unclear → "I'm not sure you have it. Tap the screen if you do."
8. **Tap to check** still works any time you think you have it (grabbing, palm within 25 cm, or 15 s after "Got it").

## What gets saved (read this first)
All in the app's Documents folder. Nothing is overwritten or deleted.

| File | How it grows |
|---|---|
| `find_log_<time>.csv` | **One file per app launch**, rewritten after every event, always holds every search of that launch (cumulative). |
| `diagnostics/<launch time>/` | **One folder per app launch.** Each event adds new files `NN_<kind>_…` (NN counts up). About 0.3 MB per event; a long scan adds up to 8 events. |
| `api_calls.csv` | One file for all launches, appended forever. Now included in Export. |

Recording events (`<kind>`): `sam` (lock and re-lock), `scan` (each scanning SAM call), `hand_seen`, `grab`, `hold_check`. `sam`/`scan` `meta.json` now also holds `object_flat`, `object_support_y`, `object_size_m`, `object_centre`, `obstacle_points`.

Log events (new in v4): `object` (flat/solid, size, support height, obstacle points), `scan_start`, `scan_found`, `scan_nothing`, `scan_give_up`, `hold_check` (detail: `tap` or `hand left the object`). Older: `command`, `say`, `sam_lock`, `sam_lock_fail`, `verify`, `target`, `target_outside_mask`, `sam_relock`, `recorded`, `pickup`, `hold_check_result`, `hold_yes`, `gave_up`, `stop`, `agent_*`.

## How to run
1. Xcode → Run. App opens on **Find**.
2. Table with the phone, a ruler and a bottle, 40–60 cm in front of you. Hold the iPhone against your chest with your **left hand**, camera facing the table.
3. Move the iPhone slowly for 2–3 s so tracking is normal (testing only; see below).
4. Searches, eyes open first:
   1. "find the phone" — follow the voice, grip it with thumb on one side, lift.
   2. "find the ruler" — same; it is flat, so "Got it" must come from the grip, not from depth.
   3. "find the water bottle" — grip it **from the side**.
   4. **Scan test:** turn your body ~90° away from the table, then "find the phone". Turn slowly back when it asks. Listen for the ticks.
   5. One object that is **not** in the room — it should scan, then give up.
   6. Put something tall between your hand and the phone, "find the phone" — listen for "Careful…".
5. Tap **Export** (top right) → AirDrop to the Mac (folder + 2 CSVs). If the folder does not come through: **Files** app → On My iPhone → Sightline → `diagnostics` → long-press the newest folder → Compress → AirDrop the zip.
6. Put everything in `logs/device/` (not in git) and tell me what it said that was wrong or confusing.

Step 3 is for testing only. In real use, tracking is normally ready by the time the command is spoken (the chest moves with breathing and turning); handling a not-ready start automatically is still to do.
