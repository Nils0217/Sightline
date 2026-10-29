<!-- labels: important, testing, reference -->
# Test log: issues, root causes, solutions

One entry per device test (or simulator finding) with the issue, the root cause we found (or the hypothesis, marked as such), what we changed, and how we checked the change. Newest last. Times are Pacific (PDT). Recordings live in `logs/` on Nils's Mac. That folder is gitignored because it holds photos of his room, so the numbers that matter are copied here.

How to add an entry: copy the template at the bottom, then fill it in after each device test, before changing any code.

**Status values**
- **open**: not fixed yet.
- **fixed (code)**: changed and checked on the Mac (unit test, simulator or replay), but not yet confirmed on the iPhone.
- **verified**: confirmed on the iPhone.

---

## T1: G1 hand 3D accuracy (2026-10-27, evening)
Build `46cea94`…`9ec7538`. Details in `docs/SPIKE.md` (G1 results) and `docs/G1_PLAN.md`.

| # | Issue | Root cause | Solution | Status |
|---|---|---|---|---|
| 1.1 | The red dot sat to the lower right, and `depth_invalid` was the most common failure | Only high-confidence LiDAR was accepted in a 3×3 window, but fingertip edges are rarely high confidence | `DepthSampler` fallback: 5×5 window, medium confidence (`d9eb56c`). Also log the `relaxed` flag | verified (G1 passed) |

## T2: Find v1 (2026-10-28, morning)
Build `c0eb050` / `c9fed38`. Details in `docs/SPIKE.md` (Core section).

| # | Issue | Root cause | Solution | Status |
|---|---|---|---|---|
| 2.1 | Far too talkative: centimetre updates while the hand moved | Guidance re-spoke on every frame change | `StepGuide` stop-and-go: one instruction, silence while the hand moves, "Stop." when it arrives (`186787a`) | verified (v3) |
| 2.2 | "Hold your hand out" repeated while the hand was visible | Only the index fingertip was tracked; the palm hid it | Whole-hand fallback point (v2), then the six-point hand (v3, `e2d6f78`) | verified (v3) |
| 2.3 | "phone" locked onto a power bank when no phone was in view | SAM returns its best guess even at low confidence | Spark yes/no check on a crop when SAM confidence is below 0.75 (`186787a`) | verified |
| 2.4 | A completed grab was never detected | No pick-up logic existed | `PickupDetector` (the target pixel depth jumps farther away), plus tap = done | superseded by T5 |
| 2.5 | Xcode: "ARSession delegate is retaining 11 ARFrames" | Per-frame work queued up on the delegate queue | `FrameGate` drops frames while busy (`50f4cd4`) | verified |

## T3: Find v2 (2026-10-28, ~12:45)
Reported by Nils; no log was kept.

| # | Issue | Root cause | Solution | Status |
|---|---|---|---|---|
| 3.1 | The hand point and the object point both sat to the left | Unknown at the time | Added a recording mode (`DiagnosticRecorder`) and the Mac simulator to diagnose it offline (`d9051a4`, `e2d6f78`) | fixed: v3 showed no bias |
| 3.2 | One hand point is not enough to judge a grab (Nils) | Design | Six keypoints: 5 fingertips + palm centre (`HandModel`) | verified (v3) |

## T4: Find v3 (2026-10-28 13:18, `logs/20261028_131855`)
Build `d9051a4` + `ebc3e94`.

| # | Issue | Root cause | Solution | Status |
|---|---|---|---|---|
| 4.1 | Left bias | None left: target and hand points reproject exactly onto the photo (`target_outside_mask` never fired) | none needed | verified |
| 4.2 | The phone and the ruler were never detected as picked up | Flat objects: the "depth jumps behind" rule needs a tall object. The glossy phone also read 1.9–2.6 cm high | `ObjectModel`: objects under 3.5 cm sit on the table plane. `GraspAssessment` from fingertips. Leaving after "Grab it" triggers a Spark check (`6d5e355`, `9d77d1e`) | verified (v4) |
| 4.3 | The bottle could not be reached: the palm stalled 7–8 cm off | The goal was the centre of a tall object | Goal = nearest surface point for solid objects | verified (v4) |
| 4.4 | "Down, about 40 centimetres" was said four times | Each repeat re-measured from a palm that had not moved yet | "Keep going down." on a repeat in the same direction | verified (v4) |
| 4.5 | "Not found" ended the search | No scan mode | `ScanPlanner`: keep scanning while the user turns, one SAM call per new steady view, at most 8 | verified (v4), extended in T6 |

## T5: Find v4 (2026-10-28 19:45, `logs/9d77d1e/20261028_194507`)
Build `9d77d1e`. One app launch with many searches (book, phone, dog, keys). A second tester ran it blindfolded. Reported 2026-10-28 20:05. Analysed and fixed 2026-10-29 00:00–01:30.

| # | Issue | Root cause | Solution (2026-10-29) | Checked by | Status |
|---|---|---|---|---|---|
| 5.1 | **Speech disappeared** more and more during a long session; one gap of 17 s in the key search | Hypotheses (not yet proven):<br>(a) `isSpeaking` read from `AVSpeechSynthesizer`, which can stay true after an interrupt, so guidance waited forever;<br>(b) `TonePlayer` paused and restarted its engine next to the synthesizer;<br>(c) the microphone engine changed the audio route;<br>(d) audio interruptions were not handled | `Speaker`: the delegate tracks the queue itself; a watchdog rebuilds the synthesizer if an utterance does not start within 3 s or runs past its length + 4 s; interrupts only when something is playing; logs `speech_start/finish/cancel/stuck`.<br>`AudioSessionKeeper`: re-applies the loudspeaker after every listen and after interruptions or route changes; logs `audio_*`.<br>`TonePlayer` never pauses | build only | open: needs a device run. The new log events show which hypothesis was right |
| 5.2 | `api_error` in the log for searches that simply found nothing | `MetaAPI.segment` threw `emptyOutput` when SAM streamed no text, which means no instance was found | Empty output now returns `""`, logged as `sam_empty`. `api_error` is now logged only for real HTTP or network errors, with the message | build | fixed (code) |
| 5.3 | **Keys** were hard to find | SAM did find them in `10_scan` (box 13×17 px, c 0.61), but mask erosion 3 removed every depth sample. Other factors: small size at 512 px, clutter, low light, the ambiguous word "key" | `MaskTarget.locateAdaptive` (erosion 3, then 1, then 0). Small nouns (`SmallObjects`) use a 930 px photo cut into 2×2 tiles of ~512 px, one SAM call per tile, with duplicates merged | replay: fixed locate fails, adaptive succeeds with 18 samples | fixed (code) |
| 5.4 | Agent called `find_object` five times on the same view | Spark retried the same tool when it got an error | `find_object` failure now starts the scan and ends the agent | build | fixed (code) |
| 5.5 | **Book**: Nils grabbed the USB hub to the left of the book; "Grab it" fired and Spark said yes | The goal was the nearest edge and the touch radius 7 cm, so a hand beside the corner counted. The Spark prompt asked "holding **or touching**", and the hand crop included the book | Flat objects: the goal is the centre, and the palm must be over the object (`palmOver`, ≤ 3 cm outside). Spark gets a reference photo of the object from lock plus the hand crop, and is asked whether the hand is gripping that same object. If the hand moved away and SAM still sees the object where it was, the answer becomes no | replay `03_grab`: palm→centre 15.9 cm, `touching` false (was true) | fixed (code) |
| 5.6 | Dog: a false "Got it" | The depth pick-up rule fired when the dog moved | Not fixed. The target can move; the strict hold check (5.5) covers part of it | – | open |
| 5.7 | Anchors drifted more the longer the session ran | Hypotheses: low light, textureless bed, long session, the target stored once | Not fixed directly. A re-lock already runs after tracking recovers; the room map relocalizes against saved features | – | open |
| 5.8 | "I can't find it, tap and try again" felt irresponsible (Nils) | The scan only said "keep turning" with no direction, and gave up with nothing to offer | The scan says which way to turn (the nearest unsearched side, or the room-map hint, then "lower"). On give-up it adds the room-map hint or earlier sighting, then a Spark guess from a wide photo ("A guess: …") | unit tests (`ScanDirectionTests`) | fixed (code) |
| 5.9 | Nils's idea: scan the room once and build a 3D map | – | "Scan the room": up to 12 views. Spark (medium) lists objects with photo x,y, and LiDAR places them. Saves `ARWorldMap` + `inventory.json` in `Documents/room_map/`. At launch the app relocalizes (8 s timeout, then a fresh session). Searches get "Your keys were last seen to your right, about 1 metre away.", and the scan turns that way first. Every find updates the inventory | unit tests (`RoomInventoryTests`, `RoomPlacementTests`) | fixed (code) |
| 5.10 | Blindfolded tester: "I don't know what the screen wants me to do" | No feedback on tap, and no way to ask for the state | Every tap gives a haptic, then an earcon or words. Double tap speaks the status, long press resets. Earcons for listening, found, not found and reset. VoiceOver actions: magic tap, "Status", "Reset" | build | fixed (code) |

### Simulator finding during the T5 fixes (2026-10-29 ~01:00)
| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
| S1 | `not_in_view` dropped from 20/20 to 15/20 after the centre goal for flat objects (5.5) | Found at the edge of the view after a scan, the hand left the camera picture on its way to the far centre: "I lost your hand" looped | `GuidanceSession.faceLine`: if the goal is more than 20° off the camera's forward direction, add "Turn a little to your left/right, to face it." to the opening and to lost-hand prompts. The simulated user now turns when asked | simulator: all 12 scenarios 20/20; 97 unit tests | fixed (code) |

### Improvements to watch on the next device run (v5)
- Speech: count `speech_stuck` events. 0 is the target. Any `audio_route` / `audio_interruption` events next to a gap explain it.
- Keys: lock from about 60 cm. Check the log for `sam_lock` with tiles. Expected cost: 4 SAM calls per small-object view.
- Book next to other things: grabbing the neighbour must give "I don't think you have the book yet."
- Room map: "scan the room", then relaunch the app. Look for `room_map_relocalized` within 8 s, and for the hint on a search.
- Blindfolded tester: can they start, stop, ask for the status and reset without help?

---

## Template
```
## Tn: <what> (<date> <time>, <log folder>)
Build `<commit>`. <who tested, how long, what was searched>.

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
```
