<!-- labels: important, testing, needs-review -->
# Find and grab — v3 device test (with recording)

v3 = v2 rejected on 2026-10-28 (anchors off to the left, wrong object, no hand instructions, Export untappable). Changes:
- Guidance runs `GuidanceSession` from SightlineCore, the same code as the Mac simulator (`swift run --package-path Packages/SightlineCore SightlineSim`).
- **Six-point hand:** 5 fingertips + palm centre (wrist + 4 knuckles). Guidance steers the **palm centre** (red dot); visible fingertips are small orange dots. The old single index tip is gone from Find (G1 still uses it).
- **Opening is explicit:** "Found the phone. It's ahead, a little to the right, about 50 centimetres." → "Hold your hand out in front of the camera, at chest height." (repeated every 7 s of silence until a hand is seen) → "I see your hand." → first step.
- Hand jitter no longer blocks instructions (found in the simulator: speed is now measured over 0.3 s and the hand point is smoothed).
- **Recording mode** (always on): every SAM call and two hand moments are saved for offline diagnosis of the left bias.
- **Export** is a separate button at the top right, outside the tap area.

## Flow
1. Tap anywhere, say "find the phone". It says "Looking for the phone." at once.
2. SAM → target (green dot). If SAM is unsure (< 0.75) it says "Checking." and asks Spark yes/no first.
3. It says where the object is, then asks for your hand.
4. Hand seen → "I see your hand." Then one instruction at a time while your hand is still ("Right, about 20 centimetres."), silence while you move, "Stop." when you get there.
5. Palm within 7 cm → "Stop. It's at your hand. Grab it." Lift it → "Got it. Well done." Or tap → "Great. Done." After 8 s: "Tap the screen when you have it." After 20 s: "Stopping."

## What gets saved (read this first)
All in the app's Documents folder. Nothing is overwritten or deleted.

| File | How it grows |
|---|---|
| `find_log_<time>.csv` | **One file per app launch**, rewritten after every event, always holds every search of that launch (cumulative). |
| `diagnostics/<launch time>/` | **One folder per app launch.** Each event adds new files `NN_<kind>_…` (NN counts up). About 0.3 MB per event. |
| `api_calls.csv` | One file for all launches, appended forever. |

Recording events (`<kind>`): `sam` (every SAM call), `hand_seen` (at "I see your hand"), `grab` (at "Grab it"). Per event:
- `photo.jpg` — what SAM saw.
- `overlay.jpg` — photo + SAM mask (green = most confident, yellow = others) + **red cross = where our 3D target lands back on the photo** + white dot = mask centre; for hand events **blue dots = Vision's joints, orange rings = our 3D hand points drawn back**.
- `screen.jpg` — the screen as you saw it, with the AR dots.
- `meta.json`, `sam.txt`, `depth.f32`, `conf.u8` — raw data for me.

How to read `overlay.jpg` yourself: if the red cross sits on the object and the orange rings sit on the blue dots, the maths is right and the left shift is in how the AR view draws the dots. If the cross or rings are off to the left, the bug is in our mapping.

Log events: `command`, `say` (every spoken line), `sam_lock`, `sam_lock_fail`, `verify`, `target`, `target_outside_mask`, `sam_relock`, `recorded`, `pickup`, `done_tap`, `gave_up`, `stop`, `agent_*`.

## How to run
1. Xcode → Run. App opens on **Find**.
2. Put the phone (or a cup) on a table 40–60 cm in front of you, with a few other things around. Hold the iPhone against your chest with your **left hand**, camera facing the table.
3. Move the iPhone slowly for 2–3 s so tracking is normal.
4. Tap the screen, say "find the phone". Wait for "Hold your hand out…", then hold your **right hand** in front of the camera.
5. Follow the voice. Eyes open the first time.
6. Do 3 searches: phone, cup, and one object that is **not** on the table (it should say it can't see it).
7. Tap **Export** (top right) → AirDrop to the Mac. If the folder does not come through, open the **Files** app → On My iPhone → Sightline → `diagnostics` → long-press the newest folder → Compress → AirDrop the zip.
8. Tell me: what it said that was wrong or confusing, and put the folder + CSV in `logs/device/` on the Mac (not in git).
