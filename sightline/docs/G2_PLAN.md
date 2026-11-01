<!-- labels: important, testing, needs-review -->

> Update 2026-10-31: this document keeps the original experiment and reference record. Current find-and-grab behaviour, call counts and acceptance are in [PRD](PRD.md), [TEST_LOG](TEST_LOG.md) (T10) and [FIND_TEST](FIND_TEST.md). Earlier passes do not mean the current version has been tested on the device or with blind users.
# G2 — SAM mask → 3D target

**Question:** if SAM finds an object in one photo, can we turn its mask into a world-space point that stays on the object while the user moves around?

**Gate:** with the phone moving around the object for ≥ 30 s, every re-measure lands within **3 cm** of the first lock (median and max reported), and the green dot visibly stays on the object.

## Pipeline (one SAM call)
1. `session.currentFrame` → `FrameSnapshot`: upright 384×512 JPEG (raw image rotated 90° CW, same as G1's Vision orientation) + LiDAR depth/confidence + intrinsics + camera pose of that same frame. The ARFrame is released right away.
2. `MetaAPI.segment` → SAM 3.1, streamed, `include_confidence`. Logged to `Documents/api_calls.csv`.
3. `SAMParser` + `SAMMaskDecoder` (Swift port of `meta-sam-parser`, checked bit-for-bit against the Python parser on the 7 spike masks). Pick the **highest-confidence** instance (SAM returns all instances, unsorted).
4. `MaskTarget.locate`: walk the 256×192 depth map, map each depth pixel to the uploaded image, keep pixels at least 3 source px inside the mask (erosion, keeps the object edge out), confidence ≥ medium, unproject, take the per-axis median → camera-space point. Also logs `depth_spread` (P90 − P10 of depth) to show whether the mask mixed surfaces.
5. Camera → world with that frame's camera transform. The first success is the lock (green dot); later ones are re-measures (blue dot) compared with the lock.

## What the number means
`dist_to_first_cm` mixes two things: ARKit world drift and the fact that the visible part of a 3D object changes with viewpoint. To keep the second one small, use a **flat object lying on the table** (a book, a closed laptop, a phone face down). Its visible surface is the top, so the median point barely moves between views. The re-measure from the **original spot** (last one) is the cleanest drift number.

## Budget
Max **5 SAM calls per app launch** (AGENTS.md). One run = 1 lock + 4 re-measures = $0.0125. Relaunch the app for another run.

## Files
| File | Role |
|---|---|
| `Packages/SightlineCore/Sources/SightlineCore/SAMOutput.swift` | SAM text parser + mask decoder |
| `Packages/SightlineCore/Sources/SightlineCore/MaskTarget.swift` | Mask + depth → 3D point |
| `Packages/SightlineCore/Tests/SightlineCoreTests/SAMOutputTests.swift`, `MaskTargetTests.swift`, `Fixtures/sam_fixtures.json` | Tests; fixtures from `tools/make_sam_fixtures.py` |
| `Sightline/Sightline/API/MetaAPI.swift`, `APIKey.swift` | API client, call log, key reader |
| `Sightline/Sightline/AR/FrameSnapshot.swift` | Frame → JPEG + depth + pose |
| `Sightline/Sightline/Spike/G2Model.swift`, `G2MeasureView.swift` | Test screen |
| `tools/ios_secrets.sh` | Copies the key into the gitignored `Sightline/Sightline/Secrets.plist` |

## Output files (on the phone, app Documents)
- `g2_targets_<time>.csv` — **one file per app launch**. It is rewritten after every measurement and always holds **all** rows of that launch (cumulative), so export it **once, at the end**. A new launch starts a new file.
- `api_calls.csv` — **one file for all launches**, appended forever. Same columns as `logs/api_calls.csv`; copy its new rows into the repo log.
- `g2/<time>_<n>.jpg` + `.sam.txt` — the uploaded image and raw SAM text for every call, for checking masks on the Mac.

CSV columns: `timestamp, measure_index, elapsed_s, noun, sam_latency_ms, sam_records, chosen_id, confidence, mask_pixels, depth_samples, depth_spread_cm, cam_to_target_m, target_x/y/z, dist_to_first_cm, camera_x/y/z, tracking_state, fail_reason`.

## How to run
1. On the Mac, in Terminal, from the `sightline` folder:
   ```
   export META_MODEL_API_KEY=<your key>
   tools/ios_secrets.sh
   ```
   It prints `Wrote Sightline/Sightline/Secrets.plist (key length N)`. The key is never printed and the file is gitignored. Do this once (again only if the key changes).
2. Xcode → Run on the iPhone. The app opens on **G2 target** (switch at the top). If it says "No API key", step 1 did not happen before the build.
3. Put a book flat on a table with some texture around it. Type `book` in the field.
4. Stand so the phone is ~50 cm from the book, looking down at it at an angle. Move the phone slowly for ~5 s until `tracking normal`.
5. Tap **Lock**. Wait for the beep (~1–2 s). A green dot should appear on the book.
6. Walk slowly to the **left side** (~45° around the book). Watch the green dot: it should stay on the book. Tap **Re-measure**.
7. Walk to the **right side**. Re-measure.
8. Step back to ~1 m. Re-measure.
9. Go back to the **starting spot**. Make sure at least 30 s have passed since Lock (`elapsed` on the last line). Re-measure. That is the 5th and last call.
10. Tap **CSV** and save it (AirDrop or Files). Also note anything you saw: did the green dot slide off the book at any point, and where?
11. Optional: Finder → your iPhone → **Files** → Sightline shows `api_calls.csv` and the `g2` folder. Copy them into `sightline/logs/`.

A failed call still uses one of the 5. If a call fails with `too_few_depth_samples`, move closer (LiDAR is best under ~2 m) and retry.
