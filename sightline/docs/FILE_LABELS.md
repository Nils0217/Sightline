<!-- labels: important, reference -->
# File labels

Every file carries a label line at the top so its status is clear at a glance:

- Markdown: `<!-- labels: a, b -->`
- Python / shell / gitignore / env: `# labels: a, b`
- Swift: `// labels: a, b`

Search a label across the repo: `grep -rn "labels:.*needs-review" .`

## Label set

| Label | Meaning |
|---|---|
| `important` | Source of truth or must-read before working (rules, scope, tasks) |
| `production` | Ships in the iOS app |
| `spike` | Experiment to de-risk a question; not shipped |
| `testing` | Tests, test fixtures, test instructions |
| `needs-review` | Written by an agent, not yet run or reviewed by Nils |
| `verified` | Run and confirmed working by Nils (note date in the registry) |
| `sensitive` | Contains or handles secrets / personal data; never commit real values or share |
| `config` | Build, tooling or repo configuration |
| `reference` | Notes and docs for lookup, not instructions |
| `generated` | Machine output; do not edit by hand |
| `muse-code` | Written by Muse Code (track for hackathon disclosure) |
| `obsolete` | No longer used; kept until Nils deletes it. Agents never delete files |

A file can carry several labels. When a label changes (e.g. `needs-review` → `verified`), update the file header and this table in the same commit.

## Registry

| File | Labels | Notes |
|---|---|---|
| `AGENTS.md` | important | Shared agent rules; wins over PRD on conflicts |
| `CLAUDE.md` | important, config | Imports `AGENTS.md` for Claude Code |
| `README.md` | important | Public project summary for judges |
| `.gitignore` | config, important | Keeps secrets and build output out of git |
| `.env.example` | config | Template; copy to `.env` and add the key |
| `.env` (not in git) | sensitive | Real API key; gitignored |
| `docs/PRD.md` | important | Scope, milestones, metrics |
| `docs/SPIKE.md` | important, testing | Current task list and results table |
| `docs/CLAUDE_CODE_PROMPT.md` | reference | Kickoff prompt used to start Spike 0 |
| `docs/FILE_LABELS.md` | important, reference | This file |
| `docs/api-notes.md` | reference, important | Verified Meta Model API request shapes and prices |
| `docs/G1_PLAN.md` | important, testing, verified | G1 hand-accuracy plan v2; gate passed 2026-10-27 |
| `docs/G2_PLAN.md` | important, testing, verified | G2 mask → 3D target plan; gate passed 2026-10-28 |
| `docs/G3_PLAN.md` | important, testing, needs-review | G3 world-map relocalization plan and run steps |
| `docs/FIND_TEST.md` | important, testing, needs-review | Find-and-grab v5 changes, saved files and device test steps |
| `docs/TEST_LOG.md` | important, testing, reference | Every device test: issue → root cause → solution → status, timestamped |
| `docs/ARKIT_SAMPLE.md` | testing, reference | How to run Apple's ARKit sample on the iPhone (S0.1) |
| `docs/assets/g1_marker_print.pdf` | testing, generated | Printable 10 cm G1 marker |
| `tools/make_g1_marker.py` | testing, needs-review | Generates the G1 marker PNG + PDF |
| `tools/make_sam_fixtures.py` | testing, needs-review | Builds SAM decoder fixtures with Meta's Python parser (needs `.venv`) |
| `tools/ios_secrets.sh` | config, sensitive | Writes the API key into the gitignored `Secrets.plist`; never prints it |
| `Packages/SightlineCore/Tests/SightlineCoreTests/Fixtures/` | testing, generated | Real SAM outputs + expected decodes from the Python parser |
| `Packages/SightlineCore/` | production, needs-review, important | Pure geometry / sampling / stats; unit-tested on Mac |
| `Packages/SightlineCore/Tests/` | testing, needs-review | Swift Testing suites (`swift test`) |
| `Packages/SightlineCore/Sources/SightlineCore/GuidanceSession.swift` | production, needs-review, important | Local find-and-grab state machine (opening lines, hand prompt, stop-and-go, pick-up); shared by app and simulator |
| `Packages/SightlineCore/Sources/SightlineCore/HandModel.swift` | production, needs-review, important | Six hand keypoints (5 fingertips + palm centre) from Vision's 21 joints |
| `Packages/SightlineCore/Sources/SightlineCore/ObjectModel.swift` | production, needs-review, important | Target as a 3D shape + support plane; fingertip grasp check; obstacle map |
| `Packages/SightlineCore/Sources/SightlineCore/ScanPlanner.swift` | production, needs-review, important | Keep-scanning: when a new view deserves a SAM call; scan phrases; which way to turn next |
| `Packages/SightlineCore/Sources/SightlineCore/RoomInventory.swift` | production, needs-review, important | Room map inventory (names + world positions, hints), Spark object-list parsing, LiDAR placement, small-object tiles |
| `Packages/SightlineCore/Sources/SightlineSim/Replay.swift` | testing, needs-review | `SightlineSim replay <folder>`: object model + grasp check on a device recording (read-only) |
| `Packages/SightlineCore/Sources/SightlineSim/` | testing, needs-review, important | Mac simulator of the guidance loop: `swift run SightlineSim` (stdout only, writes no files) |
| `Sightline/Sightline.xcodeproj` | production, config | Xcode project |
| `Sightline/Sightline/SightlineApp.swift` | production | App entry |
| `Sightline/Sightline/ContentView.swift` | production, needs-review | Root screen; Find + G1/G2/G3 tabs |
| `Sightline/Sightline/Find/` | production, needs-review, important | Find-and-grab session: command → SAM lock → hand guidance |
| `Sightline/Sightline/Audio/` | production, needs-review | On-device speech input, spoken output, proximity tones |
| `Sightline/Sightline-Info.plist` | config, production | Extra Info.plist keys (file sharing) merged into the generated plist |
| `Sightline/Sightline/API/` | production, needs-review, sensitive | Meta Model API client, call log, key reader |
| `Sightline/Sightline/Secrets.plist` (not in git) | sensitive | API key for the app; written by `tools/ios_secrets.sh` |
| `Sightline/Sightline/AR/` | production, needs-review, important | ARKit frame pipeline |
| `Sightline/Sightline/Hand/` | production, needs-review | Vision hand pose |
| `Sightline/Sightline/AR/HandKeypointLocator.swift` | production, needs-review, important | Six-point hand in world space (Vision joints + LiDAR) for Find |
| `Sightline/Sightline/Find/RoomMapStore.swift` | production, needs-review, important | Saves and loads `Documents/room_map/` (ARWorldMap + inventory.json, overwritten per room scan) |
| `Sightline/Sightline/Audio/AudioSessionKeeper.swift` | production, needs-review | Shared audio session: loudspeaker, re-apply after listen, interruptions and route changes, logged |
| `Sightline/Sightline/Audio/Haptics.swift` | production, needs-review | Haptic cues for taps, reset, success, warning |
| `Packages/SightlineCore/Tests/SightlineCoreTests/RoomInventoryTests.swift` | testing, needs-review | Room inventory, placement, tiles, scan directions |
| `Sightline/Sightline/Find/DiagnosticRecorder.swift` | testing, needs-review, important | Recording mode: photo, SAM, overlay, screen, depth per event into `Documents/diagnostics/<launch>/` |
| `logs/device/` (not in git) | generated, sensitive | Exported device logs and recordings (photos of Nils's room) |
| `Sightline/Sightline/Spike/` | production, needs-review | G1, G2 and G3 test screens and models (remove from the release build later) |
| `Sightline/Sightline/g1_marker.png` | testing, generated | G1 reference image bundled in the app |
| `spike/model_api_spike.py` | spike, needs-review, sensitive | Muse Spark + SAM 3.1 round trip; reads the API key |
| `spike/agent_spike.py` | spike, needs-review, sensitive | Mac smoke test of the Spark tool-calling loop; reads the API key |
| `spike/requirements.txt` | spike, config | Python deps for the spike |
| `spike/images/README.md` | spike, testing | Where to put the 5 test photos |
| `spike/out/` (not in git) | generated | Mask overlay PNGs |
| `logs/api_calls.csv` (not in git) | generated | Latency and cost log of every API call |
