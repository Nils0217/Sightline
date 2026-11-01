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
| `docs/PRD.md` | important, needs-review | Scope, milestones, risks; "Current find-and-grab behaviour" (v9.1, 2026-10-31) is the current requirement |
| `docs/HUMAN_FACTORS.md` | obsolete, reference, needs-review | v8 (ChatGPT) human-factors revision, translated; superseded by v9, kept as a record |
| `docs/SPIKE.md` | important, testing | Current task list and results table |
| `docs/CLAUDE_CODE_PROMPT.md` | reference | Kickoff prompt used to start Spike 0 |
| `docs/FILE_LABELS.md` | important, reference | This file |
| `docs/api-notes.md` | reference, important | Verified Meta Model API request shapes and prices |
| `docs/G1_PLAN.md` | important, testing, verified | G1 hand-accuracy plan v2; gate passed 2026-10-27 |
| `docs/G2_PLAN.md` | important, testing, verified | G2 mask → 3D target plan; gate passed 2026-10-28 |
| `docs/G3_PLAN.md` | important, testing, needs-review | G3 world-map relocalization plan and run steps |
| `docs/FIND_TEST.md` | important, testing, needs-review | v9.1 device test: data files (incl. bursts), gestures, steps, what to note |
| `docs/TEST_LOG.md` | important, testing, reference | Every device test: issue → root cause → solution → status, timestamped |
| `docs/ARKIT_SAMPLE.md` | testing, reference | How to run Apple's ARKit sample on the iPhone (S0.1) |
| `docs/assets/g1_marker_print.pdf` | testing, generated | Printable 10 cm G1 marker |
| `tools/make_g1_marker.py` | testing, needs-review | Generates the G1 marker PNG + PDF |
| `tools/make_sam_fixtures.py` | testing, needs-review | Builds SAM decoder fixtures with Meta's Python parser (needs `.venv`) |
| `tools/ios_secrets.sh` | config, sensitive | Writes the API key into the gitignored `Secrets.plist`; never prints it |
| `Packages/SightlineCore/Tests/SightlineCoreTests/Fixtures/` | testing, generated | Real SAM outputs + expected decodes from the Python parser |
| `Packages/SightlineCore/` | production, needs-review, important | Pure geometry / sampling / stats; unit-tested on Mac |
| `Packages/SightlineCore/Tests/` | testing, needs-review | Swift Testing suites (`swift test`) |
| `Packages/SightlineCore/Sources/SightlineCore/HoldVerification.swift` | obsolete, needs-review | v8 multi-observation hold check with a 4 cm movement; unused since v9, kept compiling for its tests |
| `Packages/SightlineCore/Sources/SightlineCore/HoldCheck.swift` | production, needs-review, important | v9 one-photo hold check helpers: HoldContact (fingertips near the surface), HoldGeometry (held / at spot); v9.1 SpotEvidence (record-only depth at the old spot) |
| `Packages/SightlineCore/Tests/SightlineCoreTests/HoldVerificationTests.swift` | testing, obsolete, needs-review | Dropouts, missing thumb, wrong identity, independent motion, bounds and no automatic restart |
| `Packages/SightlineCore/Sources/SightlineCore/ReachSafety.swift` | production, needs-review, important | Reach calibration and profile, staged approach, hand envelope, scene coverage |
| `Packages/SightlineCore/Tests/SightlineCoreTests/ReachSafetyTests.swift` | testing, needs-review | v9: reach gate, tracking hold/resume, body re-base, obstacle stop/resume/end, turn-then-guide, hold geometry |
| `Packages/SightlineCore/Tests/SightlineCoreTests/PickupTriggerTests.swift` | testing, needs-review | v9.1: object-centred pick-up trigger (no check without contact; leave, rise, lost; stall hint), BodyScale, SpotEvidence |
| `Packages/SightlineCore/Sources/SightlineCore/GuidanceSession.swift` | production, needs-review, important | Local find-and-grab state machine (opening lines, hand prompt, stop-and-go, pick-up); shared by app and simulator |
| `Packages/SightlineCore/Sources/SightlineCore/HandModel.swift` | production, needs-review, important | Six hand keypoints; reach guidance selects one physical fingertip and retains it through brief occlusion |
| `Packages/SightlineCore/Sources/SightlineCore/ObjectModel.swift` | production, needs-review, important | Visible target shape/support, provisional grip geometry, capsule obstacle screen and conservative hold decision |
| `Packages/SightlineCore/Sources/SightlineCore/ScanPlanner.swift` | production, needs-review, important | Keep-scanning: when a new view deserves a SAM call; scan phrases; which way to turn next |
| `Packages/SightlineCore/Sources/SightlineCore/RoomInventory.swift` | production, needs-review, important | Room map inventory (names + world positions, hints), Spark object-list parsing, LiDAR placement, small-object tiles |
| `Packages/SightlineCore/Sources/SightlineSim/Replay.swift` | testing, needs-review | `SightlineSim replay <folder>`: object model + grasp check on a device recording (read-only) |
| `Packages/SightlineCore/Sources/SightlineSim/` | testing, needs-review, important | Mac simulator of the guidance loop: `swift run SightlineSim` (stdout only, writes no files) |
| `Sightline/Sightline.xcodeproj` | production, config | Xcode project |
| `Sightline/Sightline/SightlineApp.swift` | production | App entry |
| `Sightline/Sightline/ContentView.swift` | production, needs-review | Root screen; Find + G1/G2/G3 tabs |
| `Sightline/Sightline/Find/` | production, needs-review, important | Find-and-grab session: command → SAM lock → hand guidance |
| `Sightline/Sightline/Find/BurstRecorder.swift` | testing, needs-review, important | v9.1 burst recording around each hold check (2 s before + 2 s after, 10 Hz; ≤ 5 per search, ≤ 30 per launch) for tuning thresholds |
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
| `Sightline/Sightline/Audio/MuseStream.swift` | production, needs-review, sensitive | Muse Voice Transcribe realtime stream and stop rule (branch muse-voice); reads the API key |
| `Packages/SightlineCore/Tests/SightlineCoreTests/RoomInventoryTests.swift` | testing, needs-review | Room inventory, placement, tiles, scan directions |
| `Packages/SightlineCore/Tests/SightlineCoreTests/ReviewFixTests.swift` | testing, needs-review | Muse review 2026-10-30: hold decision matrix, check re-arm/cap/timeout, agent text, room naming, turn sizes |
| `Sightline/Sightline/Find/DiagnosticRecorder.swift` | testing, needs-review, important | Recording mode: photo, SAM, overlay, screen, depth per event into `Documents/diagnostics/<launch>/` |
| `logs/device/` (not in git) | generated, sensitive | Exported device logs and recordings (photos of Nils's room) |
| `Sightline/Sightline/Spike/` | production, needs-review | G1, G2 and G3 test screens and models (remove from the release build later) |
| `Sightline/Sightline/g1_marker.png` | testing, generated | G1 reference image bundled in the app |
| `spike/model_api_spike.py` | spike, needs-review, sensitive | Muse Spark + SAM 3.1 round trip; reads the API key |
| `spike/agent_spike.py` | spike, needs-review, sensitive | Mac smoke test of the Spark tool-calling loop; reads the API key |
| `spike/requirements.txt` | spike, config | Python deps for the spike |
| `spike/images/README.md` | spike, testing | Where to put the 5 test photos |
| `spike/out/` (not in git) | generated | Mask overlay PNGs |
| `spike/stt/make_corpus.py` | spike, needs-review | STT corpus: past test lines x 4 voices x clean / noise / pause / quiet |
| `spike/stt/make_tts_corpus.py` | spike, needs-review | Round trip of the app's own spoken lines |
| `spike/stt/stt_bench.swift` | spike, needs-review, sensitive | Apple on-device vs Muse Voice Transcribe (realtime, file); reads the API key |
| `spike/stt/Info.plist` | spike, config | Speech permission text for the bench binary |
| `spike/stt/analyze.py` | spike, needs-review | Scores the bench output with the app's stop rules |
| `spike/stt/corpus.csv`, `tts.csv` | spike, generated | Clip list with reference text |
| `spike/stt/results/` | spike, generated | Bench output, `summary.md`, `scored.csv` |
| `spike/stt/corpus/`, `tts/` (not in git) | generated | WAV clips |
| `docs/STT_EXPERIMENT.md` | reference, needs-review | Apple vs Muse Voice Transcribe results and recommendation |
| `logs/api_calls.csv` (not in git) | generated | Latency and cost log of every API call |
