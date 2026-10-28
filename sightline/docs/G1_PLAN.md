<!-- labels: important, testing, needs-review -->
# G1 — Hand 3D accuracy: plan (v2)

Status: **awaiting Nils's approval**. v2 folds in an external review (2026-10-27).

## Question
Can we place the index fingertip in ARKit world space accurately enough to guide a hand to an object?

Three separate claims, tested separately:
1. **Algorithm correctness:** the 2D → 3D math is right (unit tests on Mac).
2. **On-device accuracy:** fingertip vs. reference position on the iPhone 15 Pro (this gate).
3. **Product usability:** blindfold grab ≥ 8/10 (PRD metric, later; not part of G1).

The 3 cm threshold is a **provisional engineering gate**, not a safety validation.

## Reference position
- Print a 10 cm × 10 cm reference image; measure the printed width with a ruler and use that value as `ARReferenceImage.physicalWidth`.
- The ARKit image-anchor centre is the **reference position**. It is independent of the LiDAR depth samples but not of ARKit tracking; it is not absolute ground truth.
- Before each scenario: hold still 5 s and log the anchor-centre jitter (max deviation). Abort the scenario if jitter > 5 mm.
- Visual check: project the reference centre back into the camera image and draw a dot; it must sit on the printed centre.

## Fingertip pipeline
1. Vision `VNDetectHumanHandPoseRequest` on `capturedImage`, orientation `.right`; take `.indexTip`, require confidence ≥ 0.5.
2. Convert the Vision point (normalized, origin bottom-left) to `capturedImage` pixels (1920 × 1440) and then to `sceneDepth` pixels (256 × 192).
3. Depth: use `sceneDepth` (not `smoothedSceneDepth`, which lags a moving hand). Sample 3 × 3 around the tip, keep only pixels with `confidenceMap == .high`, take the median of the nearest cluster (within 2 cm of the minimum). Fewer than 3 valid samples → **fail, no estimate**. **Fallback (added 2026-10-27 after the first device test, where strict sampling gave mostly `depth_invalid`):** if the strict 3 × 3 high-confidence pass fails, retry 5 × 5 with medium confidence; flagged as `depth_relaxed=1` in the CSV so both can be compared.
4. Unproject with the camera intrinsics scaled to depth resolution → camera space → world space via `camera.transform`.

## Capture
The phone is chest-mounted, so nobody can press a button mid-touch. Auto-capture: fingertip within 10 cm of the reference and still (< 5 mm movement for 0.5 s) → log one row, play a beep, then require the hand to leave 10 cm before the next capture.

## Scenarios (static touch = gate; moving hand = G1b, not gating)
| | 30 cm | 50 cm | 70 cm |
|---|---|---|---|
| Camera ~straight down | 10 touches | 10 | 10 |
| Camera ~45° | 10 | 10 | 10 |

Distance = phone to reference. 60 touches, about 20 minutes of device time.

## Metrics
Per scenario and overall: median, mean, P90 of 3D error; error split into normal-to-table and in-plane components (the finger's thickness should show as ~1 cm normal bias); **valid localisation rate** = frames with a valid 3D fingertip / frames where Vision saw a hand (≥ 0.5 confidence), while a scenario runs. Per-frame because auto-capture only fires on valid estimates, so failed touches would otherwise never be counted.

**Pass:** overall median ≤ 3 cm **and** valid rate ≥ 80%. Report P90 regardless.
**Fail →** PRD fallback: guide to within 10 cm, then spoken touch exploration.

## CSV (`logs/g1_touches.csv`, exported from the app)
`timestamp, scenario, distance_cm, angle_deg, ref_x, ref_y, ref_z, ref_jitter_mm, tip_x, tip_y, tip_z, err_3d_cm, err_normal_cm, err_plane_cm, hand_conf, depth_valid_samples, depth_relaxed, vision_x, vision_y, depth_m, tracking_state, fail_reason`

`fail_reason`: empty | `no_hand` | `low_hand_conf` | `depth_invalid` | `tracking_limited` | `no_anchor`.

## Files
| File | Job |
|---|---|
| `Sightline/Sightline.xcodeproj` | Xcode project (iOS 17+, portrait, camera permission, links SightlineCore) |
| `Packages/SightlineCore/` | Pure logic, `swift test` on the Mac: `DepthProjector`, `DepthSampler`, `DwellDetector`, `TouchError`, `Stats` |
| `Sightline/Sightline/AR/FrameProcessor.swift` | Per-frame pipeline on a background queue |
| `Sightline/Sightline/AR/DepthImageReader.swift` | Copies LiDAR depth + confidence buffers |
| `Sightline/Sightline/Hand/HandPoseDetector.swift` | Vision index-tip + confidence |
| `Sightline/Sightline/Spike/G1Model.swift` | Scenarios, jitter check, touch log, CSV |
| `Sightline/Sightline/Spike/G1MeasureView.swift` | Camera view, green dot = reference, red dot = fingertip, live numbers, CSV share |
| `tools/make_g1_marker.py` | Generates `g1_marker.png` (app) and `docs/assets/g1_marker_print.pdf` (print) |

## How to run on the iPhone
1. Print `docs/assets/g1_marker_print.pdf` at **100% / Actual size**. Measure the black square with a ruler (target 100 mm). Tape it flat on a table.
2. Open `Sightline/Sightline.xcodeproj`, pick the iPhone, ⌘R. Allow camera access.
3. In the app set **Measured marker width** to your ruler value.
4. Visual check first: the **green dot** must sit on the crosshair centre, and the **red dot** must follow your index fingertip. If the red dot is offset or mirrored, stop and report (orientation bug).
5. Pick distance + angle → **Start** → hold still 5 s (jitter check) → touch the crosshair and hold ~0.5 s until the tick → lift → repeat. 10 touches per scenario, then a chime.
6. Repeat for all 6 scenarios. Tap **CSV** → AirDrop to the Mac → put it in `logs/` and tell Claude.

## Unit tests (Mac, before any device time)
- Round trip project → unproject at centre, 4 corners, and edges, at 0.3 / 0.5 / 1.0 m.
- Vision bottom-left origin and `.right` orientation mapping on known points.
- Intrinsics scaling 1920 × 1440 → 256 × 192.
- Camera → world with a rotated + translated `camera.transform`.
- Depth sampling: all invalid → nil; < 3 high-confidence → nil; mixed finger/table depths → nearest cluster.
