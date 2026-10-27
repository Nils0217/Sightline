# AGENTS.md — shared rules for Muse Code and Claude

Both agents read this file first. `docs/PRD.md` is the source of truth for scope; if code and PRD disagree, flag it instead of silently picking one.

## Project
Native iOS app, Swift + SwiftUI + ARKit. Target device: iPhone 15 Pro (LiDAR, A17 Pro, Action Button). Indoor only.

## Architecture rules
- **Cloud = understand and decide.** Muse Spark and SAM 3.1 via Meta Model API (`https://api.meta.ai/v1`, OpenAI-compatible). Never call them per frame.
- **Device = measure and guide.** ARKit (LiDAR depth, world tracking, RoomPlan), Vision hand pose, local guidance controller. The 30–60 Hz loop must never wait on a network call.
- Muse reads live state only through tool calls (e.g. `get_state()` returning target/hand/obstacle coordinates in ARKit world space, metres).
- SAM masks are projected to 3D with the aligned LiDAR depth map; store the target as a world-space anchor.
- Coordinates: ARKit world space (x right, y up, z toward user, metres). No GPS.

## Conventions
- Swift 5.9+, SwiftUI, async/await. No third-party dependencies without asking.
- API key read from a gitignored `Secrets.xcconfig`. Never commit keys.
- Small commits, message format: `area: what changed` (e.g. `guidance: add distance tones`).
- Every user-facing string is spoken, so keep it short and plain; danger first; say "not sure" instead of guessing.

## Out of scope (do not build)
Walking navigation, outdoor use, external sensors, accounts, multi-language, offline mode, medical advice.

## Budget
$150 Meta Model API credit total. Log latency and cost per call during testing; reuse fixed test images.
