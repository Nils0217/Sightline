<!-- labels: important, testing -->
# Spike & validation checklist

Goal: prove the riskiest paths work before building the full app. Record every number in the table at the bottom.

## Tonight (10/26) — Spike 0

### S0.1 Device and toolchain
- [ ] iPhone 15 Pro: Settings → General → About → note iOS version
- [ ] Xcode supports that iOS version (Xcode → Settings → Platforms)
- [ ] Connect iPhone by USB-C, trust the Mac, enable Settings → Privacy & Security → Developer Mode (restart)
- [ ] Build and run Apple's sample **"Visualizing and Interacting with a Reconstructed Scene"** on the iPhone — steps in `docs/ARKIT_SAMPLE.md`
- **Pass:** coloured classified mesh (floor / table / wall) appears on screen

### S0.2 Model API round trip
- [ ] Model API key created at dev.meta.ai, stored in `.env` (gitignored)
- [x] Billing shows the $150 credit (card required by Meta); set Spend Limit ≤ $150; alerts at $50 / $100 / $140
- [ ] Muse Code signed in with the API key (`/login`), not a paid plan
- [ ] `spike/model_api_spike.py`: one image → Muse Spark names the main object (`reasoning_effort: medium`) → SAM 3.1 segments it by that noun → save mask overlay
- [ ] Run on 5 photos in `spike/images/` (include one table with several similar items)
- **Pass:** mask lands on the right object in ≥ 4/5; record latency and Billing delta

### S0.3 Rules
- [x] Read the Participant Guide (2026-10-27): native iOS app is acceptable (public repo + 3-min video + code). Rubric and deadline recorded in `docs/PRD.md`.

## 10/27–28 — Gate

### G1 Hand 3D accuracy
Full plan (v2, reviewed): `docs/G1_PLAN.md`. Gate = median ≤ 3 cm **and** valid rate ≥ 80% over 60 static touches.
- [x] Minimal app: ARKit `sceneDepth` + Vision `VNDetectHumanHandPoseRequest`; project index fingertip to world space using the depth map
- [x] Place a marker object at a measured position; touch it 10 times; log error
- **Pass:** median error ≤ 3 cm. **Fail →** guide to within 10 cm, then spoken touch-exploration

### G2 Mask → 3D target
Full plan and run steps: `docs/G2_PLAN.md`.
- [x] Swift SAM parser + mask decoder (matches `meta-sam-parser` bit-for-bit on 7 real masks)
- [x] Mask + LiDAR → 3D point (eroded mask, per-axis median), unit-tested
- [x] G2 test screen: Lock + up to 4 re-measures, CSV, ≤ 5 SAM calls per launch
- [x] Device run (Nils, 2026-10-28): book, 5 measures over 88 s → **Pass**
- **Pass:** drift ≤ 3 cm over 30 s

### G3 Relocalization
Full plan and run steps: `docs/G3_PLAN.md`.
- [x] G3 test screen: scan, place marker, save map, relaunch, load, time relocalization
- [ ] Device run (Nils)
- **Pass:** relocalizes in ≤ 10 s. **Fail →** same-session scan for the demo

### G4 Latency
- **Pass:** voice command → first spoken guidance ≤ 3 s
- Decision (Nils, 2026-10-28): option C = both. (1) Measure Spark at `low` and `minimal` on the 5 spike images (`spike/model_api_spike.py --effort low --spark-only`), compare latency and noun quality with `medium`. (2) Whatever the effort, the app speaks an instant local cue ("Looking for the cup") before any cloud call.
- [x] Spike script: `--effort`, `--spark-only`
- [x] Run low + minimal (Nils, 2026-10-28) → see "G4 Spark effort results"

## Open questions

- **Spark latency vs. G4 (2026-10-27):** at `reasoning.effort: medium` one image call takes 4.1–11.5 s (median 6.1 s), over the 3 s budget. Options once S0.2 passes: measure `low` / `minimal` on the same 5 images, or speak an instant local "looking" cue while waiting. AGENTS.md currently mandates `medium`; changing it is Nils's call.

- **SAM returns every instance that matches the noun (2026-10-27):** "white bottle" matched a water bottle (c=0.69), a hair dryer (0.52) and a toothbrush (~0.5). Records are not sorted by confidence. The app must rank by `c` and disambiguate (Muse or ask the user) before locking a target.

## Results

| Test | Date | Result | Latency | Cost | Notes |
|---|---|---|---|---|---|
| S0.1 | | | | | |
| S0.2 | 2026-10-27 | **Pass** 5/5 masks on the named object (IMG_5770 also returned 2 lower-confidence false matches) | Spark 4.1–11.5 s (median 6.1 s); SAM 0.5–1.5 s | $0.043 for 5 images (~$0.009 each; Spark ~70%) | Ranked-list prompt; single-main-object prompt gave UNSURE 5/5 on cluttered rooms. Billing: $149.90 left after 21 calls (logged estimate $0.094) |
| G1 | 2026-10-27 | **Pass.** 60 touches over 6 scenarios: median 1.43 cm, mean 1.24, P90 1.96, max 7.08; valid rate 91–100% per scenario | – | – | See "G1 per-scenario results" below. Distance in the scenario name is the phone *height*, not the camera→tip range. |
| G2 | 2026-10-28 | **Pass.** Book on a table; 4 re-measures over 88 s from 4 viewpoints (range 0.69–1.23 m, camera moved up to ~1.5 m): distance to first lock 1.01, 1.08, 0.99, 0.78 cm (max 1.08 cm, gate 3 cm). Return-to-start drift 0.78 cm | SAM 0.7–2.6 s (median 1.6 s) | 5 × $0.0025 | See "G2 results" below |
| G3 | | | | | |
| G4 | 2026-10-28 | **Spark part measured; end-to-end not yet.** Spark median 6.1 s (medium) → 4.0 s (low) → **2.0 s (minimal)** on the same 5 images | see below | per call: medium ~$0.0068, low ~$0.0034, minimal ~$0.0014 | Effort for the app = Nils's call |

### G1 per-scenario results (2026-10-27)

Source: `logs/g1_touches_1793156688_70_0.csv` (a0 runs) and `logs/g1_touches_1793159488_30_45.csv` (a45 runs). Each later export contains the earlier rows of the same app session; the other CSVs are partial snapshots.

| Scenario | Camera→tip | Median | Mean | P90 | Max | Normal err (mean) | Valid rate | Anchor jitter |
|---|---|---|---|---|---|---|---|---|
| d30_a0 | 0.35 m | 0.25 cm | 0.30 | 0.49 | 0.77 | −0.04 | 93% | 1.4–2.5 mm |
| d50_a0 | 0.57 m | 0.39 | 0.45 | 0.79 | 0.85 | −0.24 | 91% | 2.2–6.8 |
| d70_a0 | 0.70 m | 0.59 | 1.38 | 2.45 | 7.08 | −0.35 | 94% | 3.8–5.8 |
| d30_a45 | 0.52 m | 1.71 | 1.74 | 1.87 | 1.99 | −1.30 | 100% | 1.1–1.9 |
| d50_a45 | 0.76 m | 1.86 | 1.88 | 1.98 | 2.09 | −1.39 | 97% | 0.6–5.4 |
| d70_a45 | 1.05 m | 1.60 | 1.67 | 2.07 | 2.18 | −1.40 | 98% | 8.1–17.2 |

Findings:
- **45° has a systematic bias of ~1.8 cm along the viewing ray (away from the camera).** The error vector is almost constant across touches (per-axis SD ≤ 0.2 cm): ~1.3 cm down and ~1.1 cm horizontal, i.e. the 45° ray direction. Likely cause: at an oblique view the pixels just past the fingertip see paper that is farther along the ray, and the smoothed LiDAR map blends finger and paper. Candidate fix (not done): sample depth a few pixels back from the tip toward the DIP joint, or take the near edge of the nearest cluster. Within the gate, so deferred.
- **d70_a0 has one outlier (7.08 cm, in-plane)** and one at 1.94 cm; the other 8 are ≤ 1.3 cm. Most likely a touch off the crosshair or a Vision mislabel; Nils flagged this run as possibly mis-measured.
- **Failure mix:** `depth_invalid` dominates at 0° (finger edge over flat paper); `low_hand_conf` dominates at 45° and at range. No touch needed the relaxed depth pass.
- **Marker detection needs the camera close first (Nils, on device).** The image anchor was only found after bringing the phone close so the marker was large and in focus; then it kept tracking when moved back. Product impact: no printed marker in the real app, but Spark/SAM/Vision still need a sharp frame. Plan: keep ARKit autofocus on (default) and gate uploads on a simple sharpness check; tell the user to hold still for a moment before capture.

### G2 results (2026-10-28)

Source: `logs/g2_targets_1793197873.csv`. All 5 calls succeeded, SAM confidence 0.94–0.97, tracking normal throughout.

| # | Elapsed | Camera→target | Mask px | Depth samples | Depth spread | Δ first lock |
|---|---|---|---|---|---|---|
| 0 | 0 s | 0.69 m | 7523 | 1586 | 12.9 cm | — |
| 1 | 48 s | 0.71 | 7417 | 1602 | 6.3 | 1.01 cm |
| 2 | 61 s | 0.81 | 5562 | 1172 | 9.9 | 1.08 |
| 3 | 78 s | 1.23 | 2068 | 390 | 14.8 | 0.99 |
| 4 | 88 s | 0.75 | 6393 | 1390 | 11.3 | 0.78 |

Findings:
- World-space target from one SAM call stays within ~1 cm across viewpoints and 88 s. The core "lock once, guide locally" architecture holds; no need to re-call SAM just for drift.
- `depth_spread` (P90 − P10 of depth) is 6–15 cm even on a flat book. That is expected for an oblique view of a ~25 cm object (depth varies across its surface), so it is **not** a mixing indicator as designed. Replace with a plane-fit residual or distance spread around the median point if we need a quality signal.
- Measure #1 returned 2 instances; the highest-confidence one (0.965) was correct.
- Phone-side `api_calls.csv` was not copied into `logs/` this time; costs above are from the call count.

### G4 Spark effort results (2026-10-28)

Same 5 images, ranked-list naming prompt, `--spark-only`. Medium numbers are from the 2026-10-27 run.

| Effort | Latency min–max | Median | Output tokens | Cost / call | First noun per image (5770 / 71 / 72 / 73 / 74) |
|---|---|---|---|---|---|
| medium | 4.1–11.5 s | 6.1 s | 849–1970 | ~$0.0068 | white bottle / red container / white blanket / blanket / black notebook |
| low | 2.5–5.6 s | 4.0 s | 488–1081 | ~$0.0034 | water bottle / clear pitcher / white blanket / clear jar / black notebook |
| minimal | 1.4–2.2 s | 2.0 s | 178–300 | ~$0.0014 | white water bottle / red container / white blanket / glass jar / toilet paper roll |

Findings:
- Only `minimal` fits a 3 s budget, and only just (no room left for SAM + speech).
- Naming quality at `minimal` is as good as `medium` on these photos: every listed item is plausible, and the first items are real graspable objects. `minimal` even avoided medium's vague "blanket".
- Latency is dominated by reasoning tokens; tokens and latency fall together.
- **Decision (Nils, 2026-10-28):** `minimal` for fast-path calls, `medium` for reasoning; AGENTS.md updated.
- **Architecture implication:** in the main use case the user *says* the object ("find my cup"), so the noun comes from on-device speech recognition and SAM can be called directly (0.5–1.5 s). Spark does not need to be on the critical path to first guidance; it can disambiguate (several SAM instances) or handle open questions in parallel. The instant local spoken cue covers the gap either way.
