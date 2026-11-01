<!-- labels: important, testing, needs-review -->
# Find test (v9.2, 2026-10-31)

Device test for the v9 find-and-grab redo with the v9.1 object-centred trigger and body-scaled thresholds. Results go in [TEST_LOG](TEST_LOG.md) as T11. The v8 steps (ChatGPT, in Chinese) are in the `chatgpt-reach` branch; they no longer apply.

## Data and log files (read first)

- **find_log_<launch>.csv**: one file per app launch, rewritten after every event, so it grows through the run. Export once at the end.
- **Diagnostics folder**: one photo + depth + hand record per SAM call, hold check and "Stop. The … is at your fingers." moment. It grows by a few hundred KB per search.
- **Burst folders** (v9.1, `NN_burst_<reason>/` inside the diagnostics folder): one per hold check, 2 s before + 2 s after at 10 Hz (depth, confidence, poses, hand joints, small photos), about 2 MB each. At most 5 per search and 30 per launch, so at most ~60 MB per launch. These set the real thresholds; please bring them back.
- **api_calls.csv**: every Meta Model API call (latency, estimated cost). It accumulates across launches.
- **inventory.json**: the room map from "scan the room"; it is overwritten by the next room scan.
- The saved reach and hand length (two numbers) live in the app's settings and survive relaunches; long press replaces both.
- Everything contains home photos: copy it to `logs/v9/` (gitignored) and never commit it.

## Setup

iPhone 15 Pro secured on the chest, indoors, good light, a table within reach. Use safe everyday objects (book, phone, cup, key). Someone watching is useful.

## Controls

| Gesture | Idle | During a task |
|---|---|---|
| Tap | Listen ("find my book", "scan the room") | Stop (room scan: finish and save) |
| Double tap | Listen | "I have it", always: a check; if the check is unsure, your word is taken ("Okay. You have the X.") |
| Long press | Measure reach | Measure reach (ends the task) |

VoiceOver on: double tap = "I have it", two-finger double tap = start / stop; swipe up or down for Stop, Status, I have it, Measure reach.

## Steps

1. **First launch.** Expect one sentence: "Welcome. Hold your hand out comfortably, then press and hold the screen." Hold your index finger out without stretching, long press. Expect "Hold your hand out comfortably. Hold still." then "Reach N centimetres. Tap and say what to find." Quit and relaunch: expect "Ready. Tap and say what to find." (no new measurement).
2. **Book ahead.** Tap, "find my book". Expect "Looking for the book.", "Found the book. Ahead, …, N centimetres.", "Hold your hand out.", "I see your hand.", then short directions ("Right, 20 centimetres.", "A little down.", "Stop."), then "Stop. The book is at your fingers."
3. **Pick it up.** Lift the book. Expect "Checking." within about a second, then "Got it. You have the book."
4. **Lift something else.** Search the book again, but lift a different object near it. Expect "The book is still there." and directions again.
5. **Is this it? (2026-11-01).** Pick up the book and double tap: expect "Checking." then "Yes. That's the book." Pick up something else and double tap: "No. The book is still there." If you are sure you have it, just close the app (no confirmation needed).
5a. **Hand without touching (v9.1).** Search the book; when guided, put your hand on the table about 15 cm from the book, then lift it away, twice. Expect no "Checking." Then touch the book and lift your empty hand away: one "Checking." is allowed (contact candidate), and it must end in "The book is still there."
5b. **Tall object straight up (v9.1).** Search a bottle, grip it, lift it straight up without moving sideways. Expect "Checking." within about a second (log reason `near_then_rose`).
5c. **Holding still (v9.2).** Grip the object and do not move while directions repeat. After the same direction 4 times, expect one "Checking." (reason `stalled`); no repeated checks after that.
6. **Off to the side.** Object about 40° to one side: expect "Turn a little to your right, to face it.", turn, then "Good. Hold your hand out." and directions. Nothing should say "start a new search".
7. **Body moves.** During directions, shift or turn your body a little. Directions continue (from your new facing); no stop.
8. **No false obstacle (v9.1, device failure).** Nothing between hand and object, your other hand and sleeve in view: expect no "Something's in the way" at all.
8a. **Obstacle (v9.2).** A bottle between your hand and the object, placed before you search: expect one line naming it and the side to pass it ("A bottle is ahead. Go around it on your right." or "Careful. A bottle is on your left."), then directions straight on. Touching it is fine; there is no stop and no planned detour. Log `obstacle_names` shows what Spark called each thing.
8a2. **Danger (v9.2).** A knife (or scissors) lying flat between your hand and the object: expect "Stop. A knife is in the way." and directions that go around it, never into it. Log `look_around ... hazards: knife at ...`.
8a3. **Two of a kind (v9.2).** Two books (or cups) near each other: expect a short question telling them apart, answer it; guidance goes to the one you chose (log `which_one`). Say nothing: it keeps the first.
8a4. **No table height (v9.2).** Repeat the T11 mug search on the cluttered dresser: log `object ... support none obstacles N` with N > 0 now.
8b. **Put down later (rolling scan).** Start a search, then put a cup between your hand and the object: within about 2 s it should be in the map (log `rolling_scan obstacles A -> B`) and named as "Something" (it was not in the naming photo).
8c. **Holding it already.** Pick the object up yourself before guidance reaches it and keep your hand still: after a few repeats of the same direction, expect "Checking." and "Got it." (check reason `stalled`). For a tall object (bottle, box), just lifting it off its spot should start a check by itself (reason `spot_empty`).
8d. **Hand gone.** Put your hand down out of view for 15 s: "I can't see your hand.", then "I need to see your hand to guide you." and a listening tone. Say something ("where should my hand be?"): expect a short spoken answer. Silence ends the talk; guidance continues when the hand is back.
8e. **Hand on it, not picking up.** Rest your hand on top of the object without lifting for 12 s: expect "It's right below your hand." (every 6 s).
8f. **Can't tell (2026-11-01).** When you hear "I can't tell. Hold it up to the camera.", hold it in front of the phone: about 3 s later a second check (log `hold_check held_up`), then "Yes. That's the X." or "I still can't tell. It may be the X." Never asked twice in a search.
9. **Far object.** Object about 1 m away: directions still come (no "out of reach"); lean or step as you need.
10. **Stop.** Tap in each phase (listening, looking, guiding, checking): "Stopped." each time, nothing continues afterwards.
11. **Room scan.** "scan the room", turn slowly, tap when done: "Saving the room." then "Room saved. …"
12. Export (top right) and copy to `logs/v9/`.

## Log events to look at (v9.1)

`hold_check` carries the reason (`near_then_left`, `left_object`, `near_then_rose`, `near_then_lost`, `double_tap`, v9.2: `stalled`, `spot_empty`); v9.2 adds `obstacle_names`, `rolling_scan`, `hand_help_heard`, `hand_help_answer`; `spot_evidence` gives vacated / occupied / occluded / invalid counts at the object's old spot (record only); `recorded_burst` names each burst folder; `user_confirmed` marks a double tap the check could not settle. `reach_measure` logs the measured reach and hand length (also in each burst's `frames.json` as `reach_m`, `hand_m`).

## What to note per search

Object, distance, lighting, time to the first direction, time to "Got it", lines that were too long or cut off, any wrong "Got it", stops that should not have happened, and anything you had to ask a helper for. Blindfold runs find flow problems only; they do not stand in for blind users.
