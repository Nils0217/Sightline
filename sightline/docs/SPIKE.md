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
- [ ] Billing shows the $150 credit; alerts at $50 / $100 / $140; no card or spend limit < $150
- [ ] Muse Code signed in with the API key (`/login`), not a paid plan
- [ ] `spike/model_api_spike.py`: one image → Muse Spark names the main object (`reasoning_effort: medium`) → SAM 3.1 segments it by that noun → save mask overlay
- [ ] Run on 5 photos in `spike/images/` (include one table with several similar items)
- **Pass:** mask lands on the right object in ≥ 4/5; record latency and Billing delta

### S0.3 Rules
- [ ] Read the hackathon Official Rules: is a native iOS app with video + repo (no live link) acceptable? Exact judging criteria?

## 10/27–28 — Gate

### G1 Hand 3D accuracy
- [ ] Minimal app: ARKit `sceneDepth` + Vision `VNDetectHumanHandPoseRequest`; project index fingertip to world space using the depth map
- [ ] Place a marker object at a measured position; touch it 10 times; log error
- **Pass:** median error ≤ 3 cm. **Fail →** guide to within 10 cm, then spoken touch-exploration

### G2 Mask → 3D target
- [ ] SAM mask centroid + depth → world-space anchor; walk around, check anchor stays on the object
- **Pass:** drift ≤ 3 cm over 30 s

### G3 Relocalization
- [ ] Save `ARWorldMap` after a scan, relaunch, relocalize
- **Pass:** relocalizes in ≤ 10 s. **Fail →** same-session scan for the demo

### G4 Latency
- **Pass:** voice command → first spoken guidance ≤ 3 s

## Open questions

- **Spark latency vs. G4 (2026-10-27):** at `reasoning.effort: medium` one image call takes 4.6–7.5 s, over the 3 s budget. Options once S0.2 passes: measure `low` / `minimal` on the same 5 images, or speak an instant local "looking" cue while waiting. AGENTS.md currently mandates `medium`; changing it is Nils's call.

## Results

| Test | Date | Result | Latency | Cost | Notes |
|---|---|---|---|---|---|
| S0.1 | | | | | |
| S0.2 | | | | | |
| G1 | | | | | |
| G2 | | | | | |
| G3 | | | | | |
| G4 | | | | | |
