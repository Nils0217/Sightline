<!-- labels: important -->
# AGENTS.md — shared rules for Claude Code, Muse Code and Claude

All agents read this file first. `docs/PRD.md` is the source of truth for scope; `docs/SPIKE.md` is the current task list. If code and PRD disagree, flag it instead of silently picking one.

## Project
Native iOS app, Swift + SwiftUI + ARKit. Target device: iPhone 15 Pro (LiDAR, A17 Pro, Action Button), borrowed, available ~2–3 h/day. Developer Mac: Nils's. Indoor only.

## Division of labour
| Who | Owns |
|---|---|
| **Claude Code / Claude** | Main Swift codebase: ARKit, Vision hand pose, guidance controller, Model API client, architecture, code review, docs |
| **Muse Code** | Scoped tasks only: one function, one bug, one test, one script. Keeps the repo honest that Meta's coding agent was used |
| **Nils** | Runs builds on the iPhone, tests, reports logs and numbers, decides scope |

Muse Code works on a branch per task (`muse/<task>`); Claude reviews before merge.

## Architecture rules
- **Cloud = understand and decide.** Muse Spark and SAM 3.1 via Meta Model API (`https://api.meta.ai/v1`, OpenAI-compatible). Never call them per frame.
- **Device = measure and guide.** ARKit (LiDAR depth, world tracking, RoomPlan), Vision hand pose, local guidance controller. The 30–60 Hz loop must never wait on a network call.
- Muse reads live state only through tool calls (e.g. `get_state()` returning target/hand/obstacle coordinates in ARKit world space, metres).
- SAM masks are projected to 3D with the aligned LiDAR depth map; store the target as a world-space anchor.
- Coordinates: ARKit world space (x right, y up, z toward user, metres). No GPS.

## Cost rules (zero out-of-pocket)
- All usage bills the $150 hackathon Model API credit. **Never subscribe to a paid Muse Code plan.** Muse Code signs in with the Model API key, not browser sign-in.
- Meta requires a card on file to use the credit, so set the Billing **Spend Limit** to $150 or less. Alerts at $50 / $100 / $140.
- **SAM is event-triggered, not 1 Hz:** call it on target lock, when tracking confidence drops, and once before "now grab". Target ≤ 5 calls per guidance session.
- **Downscale images to ~512 px** on the long edge before any upload.
- **Muse Spark effort by job** (Nils, 2026-10-28, from G4): `minimal` for fast-path calls (naming objects, short yes/no checks, spoken replies); `medium` for real reasoning (choosing between several SAM instances, planning). Keep `max_output_tokens` generous — reasoning tokens count toward it. Spark is never on the critical path to the first spoken guidance.
- Log latency and estimated cost of every API call to `logs/api_calls.csv`. Reuse fixed test images in `spike/images/`.
- Coding agents: if Muse Code spend exceeds ~$15 in a day, move work back to Claude.

## Conventions
- Swift 5.9+, SwiftUI, async/await. No third-party dependencies without asking.
- API key from a gitignored `Secrets.xcconfig` / `.env`. Never commit keys.
- Small commits, message format: `area: what changed` (e.g. `guidance: add distance tones`).
- Every user-facing string is spoken: short, plain, danger first, say "not sure" instead of guessing.
- Label every file on its first line (`<!-- labels: ... -->`, `# labels: ...`, `// labels: ...`) and keep `docs/FILE_LABELS.md` in sync. New agent-written code starts as `needs-review`.
- Never delete files unless Nils says so; mark them `obsolete` instead.
- Don't guess Meta API request shapes: check https://dev.meta.ai/docs and record the working request in `docs/api-notes.md`.

## Out of scope (do not build)
Walking navigation, outdoor use, external sensors, accounts, multi-language, offline mode, medical advice.
