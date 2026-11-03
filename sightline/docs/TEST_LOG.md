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
| 5.1 | **Speech disappeared** more and more during a long session; one gap of 17 s in the key search | Hypotheses (not yet proven):<br>(a) `isSpeaking` read from `AVSpeechSynthesizer`, which can stay true after an interrupt, so guidance waited forever;<br>(b) `TonePlayer` paused and restarted its engine next to the synthesizer;<br>(c) the microphone engine changed the audio route;<br>(d) audio interruptions were not handled | `Speaker`: the delegate tracks the queue itself; a watchdog rebuilds the synthesizer if an utterance does not start within 3 s or runs past its length + 4 s; interrupts only when something is playing; logs `speech_start/finish/cancel/stuck`.<br>`AudioSessionKeeper`: re-applies the loudspeaker after every listen and after interruptions or route changes; logs `audio_*`.<br>`TonePlayer` never pauses | build only | verified in T6 during use (every line spoken); one stuck line at launch remains, see 6.13 |
| 5.2 | `api_error` in the log for searches that simply found nothing | `MetaAPI.segment` threw `emptyOutput` when SAM streamed no text, which means no instance was found | Empty output now returns `""`, logged as `sam_empty`. `api_error` is now logged only for real HTTP or network errors, with the message | build | verified (T6: `sam_empty` rows, no false `api_error`) |
| 5.3 | **Keys** were hard to find | SAM did find them in `10_scan` (box 13×17 px, c 0.61), but mask erosion 3 removed every depth sample. Other factors: small size at 512 px, clutter, low light, the ambiguous word "key" | `MaskTarget.locateAdaptive` (erosion 3, then 1, then 0). Small nouns (`SmallObjects`) use a 930 px photo cut into 2×2 tiles of ~512 px, one SAM call per tile, with duplicates merged | replay: fixed locate fails, adaptive succeeds with 18 samples | verified (T6: keys in a door lock found). New problems: cost 6.10, wrong key 6.4, vertical support 6.5 |
| 5.4 | Agent called `find_object` five times on the same view | Spark retried the same tool when it got an error | `find_object` failure now starts the scan and ends the agent | build | fixed (code) |
| 5.5 | **Book**: Nils grabbed the USB hub to the left of the book; "Grab it" fired and Spark said yes | The goal was the nearest edge and the touch radius 7 cm, so a hand beside the corner counted. The Spark prompt asked "holding **or touching**", and the hand crop included the book | Flat objects: the goal is the centre, and the palm must be over the object (`palmOver`, ≤ 3 cm outside). Spark gets a reference photo of the object from lock plus the hand crop, and is asked whether the hand is gripping that same object. If the hand moved away and SAM still sees the object where it was, the answer becomes no | replay `03_grab`: palm→centre 15.9 cm, `touching` false (was true) | verified for the wrong object (T6 `04_hold_check`); but too strict for the right one, see 6.1–6.3 |
| 5.6 | Dog: a false "Got it" | The depth pick-up rule fired when the dog moved | Not fixed. The target can move; the strict hold check (5.5) covers part of it | – | open |
| 5.7 | Anchors drifted more the longer the session ran | Hypotheses: low light, textureless bed, long session, the target stored once | Not fixed directly. A re-lock already runs after tracking recovers; the room map relocalizes against saved features | – | open |
| 5.8 | "I can't find it, tap and try again" felt irresponsible (Nils) | The scan only said "keep turning" with no direction, and gave up with nothing to offer | The scan says which way to turn (the nearest unsearched side, or the room-map hint, then "lower"). On give-up it adds the room-map hint or earlier sighting, then a Spark guess from a wide photo ("A guess: …") | unit tests (`ScanDirectionTests`) | fixed (code) |
| 5.9 | Nils's idea: scan the room once and build a 3D map | – | "Scan the room": up to 12 views. Spark (medium) lists objects with photo x,y, and LiDAR places them. Saves `ARWorldMap` + `inventory.json` in `Documents/room_map/`. At launch the app relocalizes (8 s timeout, then a fresh session). Searches get "Your keys were last seen to your right, about 1 metre away.", and the scan turns that way first. Every find updates the inventory | unit tests (`RoomInventoryTests`, `RoomPlacementTests`) | partly: scan and save worked in T6; hints wrong (6.8, 6.9), relaunch not tested |
| 5.10 | Blindfolded tester: "I don't know what the screen wants me to do" | No feedback on tap, and no way to ask for the state | Every tap gives a haptic, then an earcon or words. Double tap speaks the status, long press resets. Earcons for listening, found, not found and reset. VoiceOver actions: magic tap, "Status", "Reset" | build | partly: T6 tester could not tell whether it was listening (6.14); blindfolded run not done |

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

## T6: Find v5 (2026-10-29 09:04–09:36 PDT, `logs/V5/20261029_090407`)
Build `d842912`. Nils ran one app launch with eyes open and 18 commands: phone ×4, key ×7, water bottle ×2, dog, toothbrush, a room scan, and two misheard commands. Not run: relaunching with the room map (5.9 relocalization) and the blindfolded tester. Cost: 219 API calls, 173 of them SAM, **$0.60**.

Timeline:
- ~10:00–11:00: analysed the log, `api_calls.csv` and the photos.
- ~11:00: Nils added notes and corrections (marked "Nils").
- 11:00–13:00: fixed as v6.

**What worked:**
- Speech. Every `say` got a `speech_start`; there was only one `speech_stuck` (6.13).
- The loudspeaker came back within 0.5 s after every listen.
- The tiled small-object search found keys hanging in a door lock (`17_scan`).
- The strict hold check correctly said no when Nils grabbed the USB hub next to the phone (`04_hold_check`).

**Nils's design decisions (2026-10-29, ~11:00):**
- **Judge contact with the fingertips.** Measuring from "the nearest of fingertips and palm" (my first proposal) would never change the judgment.
- **The palm (red dot) only gives direction:** left/right and up/down. Forward/back comes from the leading fingertip.
- **The agent should not be limited.** Understanding the user comes first. For a need ("I'm thirsty"), it first asks what they want, offering only options that were actually found, then the user confirms, then it guides.
- **Raise the cost limits.** About $1 has been used so far; get the whole thing working end to end first.
- **Nils heard "behind you" all the time,** whether or not it was true. I re-computed every hint from the recorded camera poses (`*_meta.json` + `inventory.json`). Left, right and behind matched the stored positions each time. The stored positions were wrong, though: the keys' entry was the spot they had been lifted from (6.8), and the toothbrush's room-scan entry was about 50 cm off. The hint also gave no amount of turn (6.9).

| # | Issue | Root cause | Solution (v6, 2026-10-29) | Checked by | Status |
|---|---|---|---|---|---|
| 6.1 | **Spark said "no" twice while the phone was in Nils's hand** (session 2, `09_hold_check`); then the depth rule said "Got it" | (a) Spark gave a false negative on the crop.<br>(b) The second layer only worked one way. `still_there == false` (SAM no longer sees the object at its spot, so it was taken) was logged but never used; only `true` could override.<br>(c) On a tap check, the SAM layer only ran when the palm was more than 12 cm from the target, so it said "not checked" | Every hold check runs SAM on the same photo as Spark (`FindModel.holdEvidence`):<br>- **held** → **yes**. Held means seen away from its spot **and** either the thumb tip plus at least one other fingertip on it (within 4 cm of its surface), or it rests on the palm (centre within 6 cm sideways and 0–10 cm above the palm centre) (`GraspAssessment.holds`; Nils, ~13:00: "next to the hand" alone is not enough);<br>- still at its spot and not covered by the hand → **no**;<br>- gone from its spot but not seen held → **yes** only if Spark says yes, otherwise "not sure, hold it up";<br>- otherwise Spark decides.<br>The log line now gives the reason (`held`, `still_at_spot`, `gone_from_spot`, `spark_only`) | unit tests `HoldsTests` (thumb + finger = held, next to the hand = not, one finger = not, on the palm = held). Simulator: the check now runs the same `HoldDecision` (SAM miss 15 %, Spark wrong 10 %), plus two new scenarios `spark_wrong` (Spark wrong 50 %) and `sam_blind` (SAM misses 60 %). 14/14 scenarios at 20/20; in `normal`, 16 of 20 checks decided by `held` and 4 by `gone_from_spot`. Not simulated: grabbing the wrong object (the simulated user always grips the target) | fixed (code) |
| 6.2 | **The green dot stays where the object was first found** (Nils): after pick-up the system measures the hand against an empty spot | The target is a fixed world anchor set at lock, never updated | When the hold check sees the object held (6.1), `target` (the green dot) moves there | build | fixed (code) |
| 6.3 | **The palm centre (red dot) is a poor anchor** (Nils): the longest finger is about 11 cm long, so the palm can be 11 cm from an object the fingers already hold | `HandKeypoints.reference` was the palm centre for everything: the step guide, the 7 cm grab radius, `palmOver`, and the leave distance | `GuidanceSession.guidePoint`: palm centre for left/right and up/down, leading fingertip for forward/back.<br>`GraspAssessment.touching` = a fingertip within 3 cm of the surface (no palm term).<br>"The hand left the object" = nearest fingertip 10 cm or more from the object | unit tests `guidePointTakesForwardFromTheFingertip`, `fingertipNotPalmDecidesTouch`; simulator 12/12 scenarios 20/20 | fixed (code) |
| 6.4 | **Only very simple language works** (Nils):<br>- "the green key" got no reaction;<br>- "a key which has orange colour on it" became `find_object "key"` and found the wrong key (`20_sam`);<br>- "Two toothbrushes … left or middle?", then "the white one" took 50 s | Our prompt more than the model: the agent instructions said "not colours", the `say` tool said "no visual references", `find_object` asked for 1–3 words, and effort was `minimal`.<br>"The green key" was never transcribed: the 16:17:45 listen ran its full 6 s and returned nothing ("I didn't hear anything") | New agent instructions:<br>- understand indirect or misheard speech;<br>- keep the user's details in `find_object` (up to 8 words; SAM takes "green key");<br>- for a need, `find_object` each likely kind, then `ask_user` offering only what was found;<br>- answer "the white one" with a new `find_object`.<br>The agent runs at effort `medium` and gets the current photo. Listening: 8 s window, 1.5 s silence; the transcript (or the recogniser error) is logged as `heard` | unit tests (`AgentTests`) | fixed (code) |
| 6.5 | Key in a door lock: "Keep going down" for 30 s, and "something is in the way, to the left" three times | `ObjectModel` treated the key as flat on a table (support -0.23); the "support" and the obstacles were the door | `ObjectModel.isVertical`: if the LiDAR ring around the mask spreads up and down as much as sideways, there is no support. The object is solid, the goal is its nearest surface, and there is no obstacle map | replay: `17_scan` and `20_sam` are now "not flat, support none" (were flat); the table phone `01_sam` stays flat; unit test `doorRingIsVerticalTableRingIsNot` | fixed (code) |
| 6.6 | The agent said "on your **right**", then the guidance said "a little to the **left**" (session 3) | Spark wrote its own direction in `select_target.say` | A `say` containing a direction word is dropped (`withoutDirections`); the tool description says so | build | fixed (code) |
| 6.7 | "I'm thirsty": SAM found the water bottle (`35_sam`, c 0.59), but the agent dropped it and searched for "cup" | The old prompt said "pick a target only if it clearly matches", and `find_object` failing on "cup" ended the agent | Candidates from every `find_object` stay selectable (ids `k-n`). A miss returns `not_found` instead of ending the agent. The prompt says that 0.5 or more is usually right; offer the options found | build | fixed (code) |
| 6.8 | **Room map hints pointed to the wrong place** (Nils: it doesn't infer, doesn't record, gives no correct direction) | `finish()` stored the object's old spot on pick-up. For things the map had never seen, there was no inference at all | On a confirmed pick-up, `RoomInventory.carried` removes the item (and nearby room-scan entries of that name). When the map does not know the noun, one Spark call (`guessNear`, effort medium) picks the mapped item it is most likely near: "It might be near the bag, a quarter turn to your left. I'll look there first." The scan turns there first. The agent also gets `room_items` | unit test `carriedObjectIsForgotten` | fixed (code) |
| 6.9 | Direction to a hint: "Turn left, toward where I last saw it" ×3 | No amount of turn | Hints and prompts say how far: "a quarter turn to your left", "behind you, half a turn to your right", "Turn left, about a quarter turn, toward where I last saw it" | unit tests (`RoomInventoryTests`, `ScanDirectionTests`) | fixed (code) |
| 6.10 | **SAM cost**: 36 SAM calls per small-object search (sessions 6, 16, 17) | `ScanPlanner.budget = 8` counts views, and each view costs 4 tiles | Nils: raise the limits for now (AGENTS.md "Correctness first"). Unchanged in code | – | accepted |
| 6.11 | **"Got it" from depth alone**, with no check (sessions 2, 10, 14, 18). In session 14 the hand was 28.9 cm away | `PickupDetector` and the thumb-opposed rule ended the session on their own | Both now only start the hold check (6.1). `GuidanceSession` reaches `.done` only through `resolveCheck(true)` | unit test `gripThenLiftAsksForACheck` | fixed (code) |
| 6.12 | Room scan problems:<br>- 45 items with near-duplicates;<br>- search lines during the scan;<br>- the summary was read alphabetically | Each view listed separately; the mapping reused the search prompts | `ScanPlanner.mappingPrompt` always turns one way ("Keep turning right, slowly.", then "That's a full circle. Tap when you are done."). The summary leads with things people ask for (`summaryNames`). Merging near-duplicates is not done yet | build | partly fixed |
| 6.13 | The first line at launch never finished; the watchdog fired after 4 min 36 s instead of ~9 s. Nils: the screen stayed on | Unknown. `audio_interruption began` at launch with no `ended`, and tracking stayed `limited_initializing` the whole time. Both point to the app not being in the foreground (the timer and the camera stop there) | The app logs `app_active`, `app_inactive` and `app_background`. The speaker is rebuilt when an interruption ends with speech pending | build | open: next log decides |
| 6.14 | Nils (b): after the key search he could not tell whether it was listening | The only cue was the start earcon; an empty result said "I didn't hear anything" after 6 s | `heard` earcon (two falling notes) when listening ends; "I didn't catch that. Tap and say it again."; the transcript is logged | build | fixed (code) |
| 6.15 | "scan the room" was heard as "Scanner room"; the agent said "That's not an object I can find." | Exact phrase match only; the agent had no room-scan tool | The parser treats "scan" + "room" as a room scan; new agent tool `map_room` | unit tests | fixed (code) |
| 6.16 | Every listen flips the route to the receiver for ~0.5 s | The recogniser's `playAndRecord` setup; the keeper fixes it afterwards | Not changed (Nils did not notice it) | – | open, low |
| 6.17 | "Keep going down" ×5 with no progress at 18–26 cm (sessions 1, 8) | Not known; a replay is needed | 6.3 changes the hand point; check again on the next run | – | open |

### Next device run (v6): what to watch
- **Hold check:** pick the object up and hold it. Look for `hold_check_result yes (held)`, or `(gone_from_spot)` with Spark yes, and for the green dot jumping to your hand. Grab a neighbour: expect `no (still_at_spot)`.
- **Fingertips:** "Grab it" should come when a fingertip touches, not before or long after.
- **Language:** say "the green key", "I'm thirsty" and "the one with the orange tag". The agent should offer only things that are really here.
- **Room map:** scan the room, pick something up and ask for it again. There should be no hint to its old spot. Ask for something that was never mapped and listen for "It might be near …".
- **Launch:** look at `app_*` events around any `speech_stuck`.

## T7: Find v6, first run (2026-10-30 ~10:00 PDT, `logs/find_log_1793379542.csv`)
Build: uncommitted v6 working tree. Nils stopped the test at step 4.1: "完全不行，光4.1就0分，什麼都沒達成." The only exported log has 6 lines (launch, room map load, relocalization fallback after 8 s) and no tap or search. Nils's account: "綠點沒跟著手機，停在原地。手已經抓著手機，SAM 沒有啟動開始判定。系統一直叫我手往下，即使手指都已經貼著桌子。沒有即時引導，畫面可以看到手機在手的右前方." Rows 7.3–7.6 come from that account; the new sim scenario `grab_unasked` reproduced 7.4/7.5 (12/20 before the fixes).

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
| 7.1 | Step 4.1 (find the phone, pick it up) achieved nothing | See 7.2–7.6; no search events in the exported log to confirm | Need the full Export (all `find_log_*.csv` of that launch plus `diagnostics/`) | – | open |
| 7.2 | Nils: guiding up/down with the palm (red dot) is not a good approach | The palm sits ~11 cm behind and above the fingertips that actually reach the object | `GuidanceSession.guidePoint`: the leading fingertip gives up/down and forward/back; the palm only gives left/right | unit test `guidePointTakesHeightAndForwardFromTheFingertip`; sim 14/14 at 20/20 | fixed (code) |
| 7.3 | "Keep going down" while the fingers were on the table | Vertical came from the palm (7.2), which cannot get lower than ~8 cm above the table | Besides 7.2: no "down" once the guide point is within 2 cm of the support height | unit test `noDownWhenFingersAreOnTheTable` | fixed (code) |
| 7.4 | No useful direction: the phone was ahead-right of the hand, but it kept saying "down" | `StepGuide.dominantAxis` picked the larger of left/right and up/down first, so a large (unreachable) "down" blocked "right" | Order is now left/right, then forward/back, then up/down | unit test `axisOrderIsSidewaysThenForwardThenDown`; sim 15/15 at 20/20 (about 2 more lines, 3 s longer) | fixed (code) |
| 7.5 | Holding the phone, but no check started and the green dot stayed | Checks started only in the grabbing phase (after "Grab it") or from LiDAR depth, which barely changes for an 8 mm phone. A hand that grabbed on its own, or that Vision lost while gripping, was guided back "down" to the old spot forever | While guiding: a fingertip that came within 4 cm and then left 10 cm asks for a check; going back to guiding after "Grab it" keeps that; 3 "Keep going …" in a row ask for a check | unit test `nearThenLeftWhileGuidingAsksForACheck`; sim `grab_unasked` 12/20 → 20/20 | fixed (code) |
| 7.6 | (sim `grab_unasked`) A hand that is seen only in some frames never counted as steady, so it stayed at "Reach your hand …" | The steady clock reset on every missed frame | Gaps up to 0.5 s keep the clock | sim `grab_unasked` | fixed (code) |
| 7.7 | (Muse review) A hold check that timed out left the session in `.checking`: every later cue went silent | The 25 s timeout reset the app phase only | Timeout calls `GuidanceSession.checkTimedOut` (= not sure) | unit test `timeoutLeavesChecking` | fixed (code) |
| 7.8 | (Muse review) A "not sure" verdict could loop into another check every frame, each 1 SAM + 1 Spark | After `resolveCheck(nil)` the leave check fired again while the hand stayed away | The leave check needs the hand to come within 4 cm again; at most 6 automatic checks per search, then "Tap the screen when you have it"; hold-check SAM calls counted and capped at 12 (`hold_sam_budget`, then Spark only) | unit tests `notSureNeedsTheHandBackBeforeTheNextCheck`, `automaticChecksAreCapped` | fixed (code) |
| 7.9 | (Muse review) Smaller issues | "Keep going" counted by wording; agent sentences with any direction dropped silently ("the right cup"); duplicate agent candidates for one object; `guessNear` read only leading digits; "scan the room for my keys" mapped the room; summary ranked "garbage" as a "bag"; turn sizes defined twice; lifecycle observers not kept | `GuidanceCue.repeated` (reset on "Stop."); `AgentText.withoutDirections` cuts only the directional clause and logs `agent_say_trimmed`; candidates within 5 cm merged; `AgentText.firstInteger`; "scan … room for X" = find X; whole-word ranking (`RoomInventory.summaryNames`); shared `TurnSize`; observer tokens stored. Not a bug: double speech on a session check (the session path returns before the second line); `carried("keys")` already forgets "key" | `ReviewFixTests` (119 tests); sim 15/15 at 20/20 | fixed (code) |

## T8: Find v6, second run (2026-10-30 10:37–10:44 PDT, `logs/V6/20261030_103702`, `find_log_1793381822.csv`)
Build: uncommitted working tree with T7 fixes 7.2–7.9. Nils: "很多鬼打牆". Searches: "I want my phone" (agent → phone, done after 2 min, by tap), "I'm thirsty" (agent asked; turn limit), "the green liquid" (cup, stopped by Nils), "Where is my key" (scan, agent asked, done after 3 min).

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
| 8.1 | Phone: "Checking." four times while guiding, each "no (still_at_spot)", cutting off the guidance | Near-then-left (7.5) fired on single frames: at the check photo the fingertips hovered ~7 cm over the phone; fingertip depth jumps of ~6 cm crossed 4 cm and 10 cm | Near = median of the last 0.4 s ≤ 4 cm; away = every sample of ≥ 0.3 s ≥ 10 cm (also for the leave check after "Grab it") | unit test `fingertipDepthJumpsDoNotStartChecks`; sim 15/15 | fixed (code) |
| 8.2 | A check ended 0.2 s after it began with "timeout" (62.7 s, 96.5 s, 167.6 s) | The 25 s timer of the previous check only compared the search id and phase | Each check has its own id; a timer or result of an older check is ignored | build | fixed (code) |
| 8.3 | "A little right." / "Stop." five times at 24 cm (90–108 s) | Instruction and "reached" used the same 3 cm threshold: noise crossed it every second | New instructions need ≥ 5 cm on that axis; "Stop." still at 3 cm | sim 15/15 | fixed (code) |
| 8.4 | Key: "Stop. It's at your hand. Grab it." every ~5 s (87, 92, 152, 160, 165, 170 s) | Back to guiding after 5 s when the hand was > 5 cm away, while "at your hand" is ≤ 6 cm: it re-entered at once | Back to guiding only beyond 9 cm (grab radius + 3 cm) | sim 15/15 | fixed (code) |
| 8.5 | "I'm thirsty": after two questions the answer "The green liquid" hit `agent_turn_limit`; Nils had to tap and say it again | 6 turns per agent run | 16 turns (Nils: the agent is not limited) | build | fixed (code) |
| 8.6 | Cup with green liquid: "solid size 8x2x6 cm support none"; guidance went from 9 cm to 28 cm and the hand was lost | Not known: 2 cm tall for a cup and no support suggest the mask hit the liquid surface only | Not changed; replay `17_sam`/`18_sam` next | – | open |
| 8.7 | Key hold checks: "unclear (gone_from_spot) spark no" three times while Nils held the key | A 1 cm key: SAM found it away from its spot, but `holds()` did not see thumb + finger on it, and Spark said no on the crop | Not changed; look at photos 29–34 | – | open |
| 8.8 | "Tight" heard for "right" | Speech recognition | The agent asked again, which worked | – | ok |

What worked: the agent understood "I want my phone" and "I'm thirsty", offered only what it found (water bottle, cup), answered "What's inside the cup", and asked which key by position.

## T9: Find v7 (2026-10-30 10:58–11:02 PDT, `logs/v7/20261030_105802`, `find_log_1793383082.csv`)
Build: T8 fixes. Searches: "I want my key" (done by tap after 94 s), "Can you help me find my book" (scan, stopped by Nils), "Oh my phone" (done by tap after 52 s). Nils: "用戶一抓起任何東西要馬上啟動判定."

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
| 9.1 | Phone: "Grab it" at 33 s, Nils took it, but the check came only at 41.5 s (after "Tap the screen when you have it") | The leave check needs the fingertips seen ≥ 10 cm from the spot for 0.3 s; a hand around a phone is mostly not seen. Hand shape cannot tell a grip either: in the v6/v7 recordings fingertip-to-palm distances (3D and 2D) overlap for open and gripping hands | New `LiftDetector`, for any object: the palm rests within 9 cm above the table (not below it, still within 3 cm) for 0.4 s, then rises 5 cm for 0.15 s (`lift`) or vanishes for 0.8 s (`hand_lost_low`) -> check at once. The log shows the reason in `hold_check` | unit tests `LiftDetectorTests` (4); sim 15/15 at 20/20, median 1 check per search, no early checks | fixed (code) |
| 9.2 | Key: "no (still_at_spot) spark yes" -> "That doesn't look like the key. Put it down" while Nils held it; the next tap said yes | SAM saw another key of the bunch at the spot; "at spot" overrode Spark | SAM at spot + Spark yes = not sure ("hold it up and tap again"), not no | unit test `HoldDecisionTests.matrix` | fixed (code) |
| 9.3 | Book: SAM found it (0.62, the green book under a white tube, `06_sam_overlay.jpg`), but Spark's check said no and the search went on without it | The check sent Spark a crop of the ~512 px photo: ~210×130 px, the book only a thin green strip. Re-run on Mac: old and new crop prompts both "no" | Spark gets the whole photo with SAM's box drawn: "Is the thing inside the green box a book, even if partly covered?" Re-run: book box yes; cup box and tube box asked as "book" no. A find Spark rejects is kept; if the scan finds nothing else, it guides there with "I'm not sure, but this might be the book" and the hold check decides | 3 Spark calls on the v7 photo (`verify_box_*` in api_calls.csv); build | fixed (code) |
| 9.4 | "Still looking. Keep turning slowly." ×5 without an end | The scan calls SAM only for a view ≥ 25° from the ones searched. Nils did not turn (the book was in front), so no call was made, the budget was never used up and it never gave up | After 3 prompts with no new view: give up (or guide to the kept find, 9.3) | unit test `noNewViewGivesUpAfterThreePrompts`; sim 15/15 | fixed (code) |

---

## v8: reach-control revision by a ChatGPT session (2026-10-30, code only; obsolete)

Written in Chinese by ChatGPT; translated here, original in the `chatgpt-reach` branch (commit 93766c8). Not a device or user test.

| Item | v8 change | Status then |
|---|---|---|
| Reach | Comfortable index-finger reach measured; target, waypoint and per-axis end gates; re-measure after background | code only |
| Motion | One real fingertip; flat objects up / across / down; near edge and tactile exploration | code only |
| Obstacles | Current point cloud; active and next axis checked; capsule clearance; shared forearm approximation | code only, not a full avoidance guarantee |
| Failure stops | Tracking, rotation/translation, stalled frames, background, hand loss all latch a stop; a new search is needed | code only |
| Hold check | Two-frame identity + shared motion; one model, a vanished object or a still object never succeeds | code only, no real cloud calls |
| Controls | Fixed Stop / Status / Check / self-confirm / save-scan; cancellation tokens per session and check | code only |
| Wording | Says contact is not confirmed; "move your hand"; names the object on success | code only |

Bounded-confirmation round: at most 3 observations (3 SAM + 3 identity calls, 35 s), 2 identity-positive with ≥ 2 common fingertips moving with the object, one requested 4 cm horizontal movement, then self-confirm / New search / Stop. Its checks: 169 tests in 33 suites passed; iOS source type-check passed (full xcodebuild was blocked by its sandbox). Its simulator (seeds 1–10): normal 4/10, index_hidden 2/10, bottle_centered 4/10 completed; obstacle 10/10 stopped; wrong_object, hand_only, object_only, slide_only 0/10 false successes.

2026-10-31 device note: a screenshot showed the forced setup sheet staying up after a successful measurement; v8 changed it to an overlay that closes itself.

## T10: v9 find-and-grab redo (2026-10-31, code, simulator and build; not yet on the device)

Nils on v8: "having the pre set up is a good idea, but the whole process is a piece of shit user experience, and the voice instruction is crumbled." Decision: keep the safety base, redo the flow and the voice (branch `v9-ux`; v8 snapshot in `chatgpt-reach`, commit 93766c8).

| # | Issue in v8 | Root cause | Fix | Status |
|---|---|---|---|---|
| 10.1 | Spoken lines ran 30–75 words ("Secure the phone on your chest … To exit setup, hold the screen, or use the VoiceOver escape gesture.") | Every line carried instructions for every control plus disclaimers | One action per line, ≤ ~8 words: "Right, 20 centimetres.", "Stop. The book is at your fingers.", "Not sure. Double tap if you have it." | fixed (code) |
| 10.2 | Lines cut each other off | 40 lines interrupted; `stop()` said "Stopped. Keep your hand still. Tap to speak a new command." even when called internally (re-measure, background, new search) | Silent `cancel()` for internal use; only Stop, obstacles and check results interrupt | fixed (code) |
| 10.3 | Voice told a blind user to "Choose Check" / "Tap the main area" | Seven on-screen controls | Tap = start/stop, double tap = "I have it", long press = measure reach; VoiceOver: activate = double tap, magic tap = tap | fixed (code) |
| 10.4 | Guidance died and needed a new search | Stops latched on tracking not normal, a camera change > 15° / 6 cm (breathing, turning), a frame without an obstacle map, and edge-of-view targets | Tracking: "Hold still." and resume; camera change: re-base the frame; no obstacle map: skip the check that frame; edge of view: ask to turn, then guide | fixed (code) |
| 10.5 | Pick-up check (Nils, v7: any pick-up checks at once) limited to 1, then manual Check; 4 cm movement test; up to 3 photos / 35 s | v8 hold-verification contract | Back to v7: any pick-up checks, one photo, SAM + Spark in parallel, `HoldDecision`; ≤ 6 automatic checks | fixed (code) |
| 10.6 | Reach re-measured after every background | v8 rule | Measured once, saved in UserDefaults; long press re-measures | fixed (code) |
| 10.7 | "Not the X. Put it down." when the user had not picked anything up | `false` means SAM still sees it at its spot | "The X is still there." and guide again | fixed (code) |
| 10.8 | "I can't see your hand." repeated 8× in 30 s while gripping | Reset on any single visible frame; also said while grabbing (Vision drops gripping hands) | Only while guiding, after 1 s, once until the hand is back for 1 s | fixed (code) |
| 10.9 | Obstacle ends the search (sim `obstacle` 0/20) | Stop on obstacle is kept (safety base); no detour | Resumes when the path is clear for 1 s; ends after 8 s blocked | open: detour not built |
| 10.10 | Docs in Chinese (README, PRD, TEST_LOG, FIND_TEST, HUMAN_FACTORS, SPIKE, api-notes) and an AGENTS.md contract overriding Nils's decisions | ChatGPT session | Back to English; AGENTS.md v9 contract, v8 marked obsolete; HUMAN_FACTORS.md marked obsolete | fixed |

### Checks

- Unit tests: **170 passed in 33 suites** (`swift test`). Tests for v8 latching rewritten to v9 behaviour (tracking resumes, body turn re-bases, obstacle stop/resume/end, turn-then-guide, still-there); HoldVerificationTests kept and marked obsolete.
- iOS build: `xcodebuild … -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` **BUILD SUCCEEDED**.
- Simulator (20 seeds each, same scenarios as v8 plus the four negatives), v8 → v9 completed runs:

| Scenario | v8 | v9 | v9 median s |
|---|---|---|---|
| normal | 8/20 | 20/20 | 27.9 (v8 49.9) |
| index_hidden | 4/20 | 20/20 | 29.2 |
| shared_bias / target_bias | 13/20, 9/20 | 20/20, 20/20 | 29.3, 29.2 |
| sloppy_user / late_hand | 10/20, 10/20 | 20/20, 20/20 | 35.7, 37.5 |
| flaky_tracking / ruler | 7/20, 6/20 | 20/20, 20/20 | 45.8, 30.7 |
| bottle_side / bottle_centered | 0/20, 9/20 | 20/20, 20/20 | 32.6, 18.5 |
| loose_grip / sam_blind | 8/20, 2/20 | 20/20, 20/20 | 27.9, 27.8 |
| not_in_view | 0/20 | 20/20 | 39.5 |
| spark_wrong (Spark wrong 50%) | 1/20 | 15/20 (5 unsure) | 29.6 |
| grab_unasked | 1/20 | 17/20 (2 unsure) | 38.1 |
| obstacle | 0/20 (stopped) | 0/20 (ended) | – |
| wrong_object / hand_only / object_only / slide_only | 0/20 each | 0/20 each (no false success) | – |

The simulated user double taps at most twice after "Not sure" and each double tap runs a check; in the app the double tap after "Not sure" is the user's own confirmation, so the app would finish the unsure runs as `user_confirmed`. Synthetic results only.

## T10.1: v9.1 object-centred trigger and body scale (2026-10-31, code, simulator and build; not yet on the device)

Nils rejected the v9 lift trigger ("LiftDetector"): a hand put down and lifted without touching anything still counted as a pick-up, and "2 cm below the table" made no physical sense. He then added: "all cm distinguishers must not be absolute, but modified by the user's hand reach measure." After two ChatGPT critiques, the plan was: object-centred trigger, record-only spot evidence, consistent double tap, body-scaled thresholds, burst recording.

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
| 10.1.1 | A hand moving down and up away from the object triggered a check | LiftDetector looked at the hand only | Check only after a contact candidate (≥ 2 tips within a hand-sized 4 cm of the object), then leave / rise / lost; LiftDetector and PickupDetector marked obsolete | PickupTriggerTests `handOnTheTableAwayFromTheObjectDoesNotTrigger`, `handHiddenWithoutContactDoesNotTrigger` | Fixed (unit) |
| 10.1.2 | Fixed centimetre thresholds ignore body size | Constants | `BodyScale`: arm thresholds × reach / 52 cm, hand thresholds × hand length / 18 cm, clamped 0.6–1.5; hand length measured with the reach | BodyScaleTests (5) | Built; numbers unverified on people |
| 10.1.3 | Tall bottles never checked (sim 0/20) once leaving was required | Fingertips stay inside a tall object's outline when it is lifted straight up | `near_then_rose`: a reach-scaled 5 cm rise above the lowest hand point near the object, held 0.2 s | `contactThenRiseChecks`; sim bottle_side / bottle_centered 20/20 | Fixed (sim) |
| 10.1.4 | grab_unasked stuck repeating "Keep going left" (sim 0–2/20) | Grip dropouts broke the "near" history; no way out when the hand stalls | Dropout-tolerant near history (last 3 samples); one "Double tap if you have it." per search when the hand stalls, never an automatic check | `stalledHandGetsOneHintAndNoCheck`; sim 19/20 | Fixed (sim) |
| 10.1.5 | Double tap meant two things | v9: "check" before "Not sure", "confirm" after | Always "I have it": a check; unsure → the claim is accepted (`user_confirmed`) | Build; sim `self` column | Built |
| 10.1.6 | Sim fault scenarios looked like successes (object_only 20/20, slide_only 18/20) after 10.1.5 | The simulated user double tapped in runs where they did not really hold the target, and the self-confirmation counted as ok | Sim user claims only when truly holding the target; fault runs never count self-confirmation as ok | Sim: all four fault scenarios 0/20 | Fixed (sim reporting) |
| 10.1.7 | No real data to set thresholds | Single-frame diagnostics | Record only: `spot_evidence` (vacated / occupied / occluded / invalid at the old spot) and a 2 s + 2 s burst at 10 Hz per check (≤ 5 per search, ≤ 30 per launch, ~2 MB each) | Build only | Waiting for device data |
| 10.1.8 | Device: object found, then "It's out of reach. Move closer, then search again." with no guidance | The gate compared the straight line from the chest camera (including the ~50 cm drop to the table) with a reach measured with the hand held out ahead; the spoken "N centimetres" is horizontal, so the two disagreed. The simulator used the 0.85 m maximum reach and never hit it | Compare the horizontal distance with the reach; allow a drop down to 1.2 × reach and a rise up to 0.5 × reach (guesses). Sim now uses a 0.62 m reach (arm straight out); with 0.50 m every scenario but bottle_centered ended out of reach, since the sim table objects are ~57 cm away horizontally | `tableObjectBelowTheChestIsWithinReach`; sim back to the table above | Fixed (unit, sim); device recheck needed. Open: "comfortably" may measure a bent arm, too short for table objects |
| 10.1.9 | Nils: "I don't care how far the object is, it must guide" | The reach gate ended the search | Distance never ends a search; the reach only scales thresholds and picks staged waypoints. A waypoint beyond reach falls back to the straight path only if the object is within reach (with a 50 cm sim reach the fallback sent hands sideways out of view: normal 11/20) | `objectBeyondReachIsStillGuided`; sim with a 50 cm reach back to the table above | Fixed (unit, sim) |
| 10.1.10 | Sim: 117 s of silence after the hand left the view | "I can't see your hand." was said once and never again while the hand stayed gone | Repeat it every 10 s while gone (first one interrupts, repeats do not) | Sim; tests | Fixed (sim) |
| 10.1.11 | Device: every search said "Stop. Something's in the way." with nothing there, then ended | The app built a new obstacle map from the full depth frame every frame: it held the user's own arm and sleeve (only a 20 cm forearm guess was removed), the other hand, the body, and flying pixels at the hand's edge; one point was enough. The simulator never fed this map (it used a clean bottle-only map), so it could not show the failure | One map from the lock frame (before the hand comes in), built by `ObstacleMap.scene` (shared by app and simulator): 3–50 cm above the table, away from the body (arm-scaled 25 cm) and the target's edge (hand-scaled 4 cm), single cells dropped; the arm removed once when the hand appears; points the hand passes through carved; a block needs 3 points, and only moves that bring a hand part closer count | Tests `strayPointAndOwnArmDoNotStop`, `sceneKeepsRealThingsOnly`, `besideAnObstacleTheHandCanMoveAway`; new sim scenarios clutter, arm_at_lock (0 warnings) | Fixed (unit, sim); device recheck needed |
| 10.1.12 | An obstacle stopped the hand, then nothing useful happened | v9 waited, then ended the search; the first v9.1 build said "Go slowly" and guided straight into it | Go around: another axis of the remaining move, a sideways shift that still lands on the object, back toward the body, or up and over (then stay above it); only if none is clear, "Go slowly. Something is on your left." once and guide on. "Stop." only interrupts a move that is heading into it; a blocked next move is planned at rest | Sim obstacle 20/20 complete; `obstacleAtRestIsGoneAroundNotInto` | Fixed (sim); 7/20 still touch the bottle (see open issues) |
| 10.1.13 | Meaningless situations found by new simulator detectors (silence > 12 s, a line 3+ times in 10 s, hand into an obstacle) | Several | "A little left." / "Stop." x7: small final moves now run to 1 cm. 24 s silence with a flickering hand: the current move is repeated after 8 s of silence. "Left" / "Keep going left" every 3 s for 100 s: after a stall, 8 s quiet. Six rounds of "still there": automatic checks pause after two in a row. "Stop. Something's in the way." / "Go slowly." alternating: told once per obstacle and hand position, "Go slowly." at most every 10 s. A detour planned per frame flipped between two moves: detours are committed until done. 20 s without a pick-up ended the search: now "Let's try again." and guidance | Sim columns `hits`, `silent`, `loop`; `--flagged` prints those runs | Fixed (sim) |
| 10.1.14 | Nils's review of the below-8/10 list (2026-10-31): touching things is normal, time to the object is the KPI; name obstacles and say which side to pass; rolling scan; "It's right below your hand."; talk when the hand is gone; a held object was not noticed and the spot was not looked at again | Design | v9.2: no stop and no planned detour by default (`maxDetours = 0`; sim obstacle 33.7 s median vs 55.6 s with 6 detours, a touch in 17/20 vs 5/20). One Spark look names the lock-map things (numbered marks). Pass side: the side the object is on, else away from it, else fewer things (geometry, not the LLM: it must answer within a frame). Rolling scan every 1 s, a cell joins when seen twice in a row, arm and hand removed. Stall (same direction 4 times) and an empty spot (LiDAR, objects ≥ 3 cm thick, after the spot was seen full) start a check. Hand gone ~11 s: "I need to see your hand to guide you." then up to 3 spoken turns with Spark. 20 s on the object: "It's right below your hand." every 10 s | New sim scenario `late_obstacle`; 198 tests | Fixed (sim), device pending |

### Checks

- `swift test`: 191 tests passed (new: PickupTriggerTests 6, BodyScaleTests 5, SpotEvidenceTests 6, reach 2, obstacle 4 rewritten/added). Sim reach 0.50 m.
- Simulator after 10.1.11–13 (20 seeds; the lock scene now has a noisy table, flying pixels, and, per scenario, a bottle, cups or the user's arm): all positive scenarios 20/20 (grab_unasked 20/20, 5 self-confirmed); obstacle 20/20 complete, 0 searches ended, hand touched the bottle in 7/20; clutter and arm_at_lock 20/20 with 0 warnings; fault scenarios 0/20; silence > 12 s: slide_only 2/20; chatter: grab_unasked 1/20.
- `xcodebuild` generic iOS, no signing: BUILD SUCCEEDED.
- Simulator, 20 seeds each (synthetic only; `self` = how many of ok were the user's own confirmation after an unsure check):

| Scenario | ok | self | Median s |
|---|---|---|---|
| normal / index_hidden | 20/20, 20/20 | 1, 1 | 29.4, 29.2 |
| shared_bias / target_bias | 20/20, 20/20 | 0, 1 | 29.0, 29.3 |
| sloppy_user / late_hand | 20/20, 20/20 | 1, 0 | 34.4, 38.2 |
| flaky_tracking / ruler | 20/20, 20/20 | 0, 0 | 41.6, 30.0 |
| bottle_side / bottle_centered | 20/20, 20/20 | 3, 3 | 34.0, 24.1 |
| loose_grip / sam_blind | 20/20, 20/20 | 1, 1 | 29.4, 27.7 |
| not_in_view | 20/20 | 0 | 38.9 |
| spark_wrong (Spark wrong 50%) | 20/20 | 6 | 32.7 |
| grab_unasked | 19/20 | 6 | 41.1 |
| obstacle | 0/20 (20 ended) | – | – |
| wrong_object / hand_only | 0/20 each (6 checks, no false success) | – | – |
| object_only / slide_only | 0/20 each (16 and 18 unsure) | – | – |

Honest limits: the simulator's hand and object are idealised, so 20/20 says the logic chains together, not that the thresholds fit real hands. The scaling reference values (52 cm reach, 18 cm hand) and the 0.6–1.5 clamp are guesses to be replaced from the bursts. Spot evidence does not affect any result yet. The strict thumb rule (`GraspAssessment.holds()`) is still unused: the trigger is relaxed, success is still decided by the photo check.

### Next device run (v9.1): what to watch

- First launch: one sentence, long press measures, "Reach N centimetres."; relaunch does not ask again.
- Lines are short and do not cut each other; no button names spoken.
- Turning the body or a tracking blip does not end the search.
- Picking anything up → "Checking." within a second; results use the three short lines.
- Double tap after "Not sure" finishes (`user_confirmed` in the log).
- Hand put down and lifted near, but not on, the object: no "Checking." (v9.1).
- Bottle lifted straight up: "Checking." (`near_then_rose`).
- Burst folders appear in diagnostics, at most 5 per search.

## T11: v9.2 on the device (2026-10-31 18:17–18:32 PDT, `logs/V9.1.3/20261031_181659`, `find_log_1793495819.csv`)

**Reference run (Nils): the last mug search is the current success.** The thing found was not a mug: a white utensil holder with a handle (whisk, wooden spoon and spatula in it) on a cluttered dresser; SAM called it "mug" at 0.84, above the 0.75 Spark-verify threshold, so identity was never checked, and the hold check compared against the same wrong reference. Nils counts it as a success of the flow. "Where's my mug": not in view, turn, found at 120 cm (8.1 s), "I see your hand." (16.9 s), one direction "Forward, 85 centimetres.", "Stop. The mug is at your fingers. Feel for the side." (26.7 s), lift, "Checking." (`near_then_rose`), "Got it. You have the mug." (34.4 s). 7 lines, no obstacle line, no repeat. Later versions must not be slower or wordier than this.

| Search | Result | Time | Notes |
|---|---|---|---|
| book | Not sure, no double tap | — | "Something is ahead. Go around it on your left." then "A book is ahead. Go around it on your right.": the second "book" is likely the target's own edge or a second book (Spark named mark 3 "book", 5 cm tall). Rolling scan grew the map 573 -> 909 points in 10 s |
| phone | Not sure, no double tap | — | 45 s to lock (agent). "A roll is ahead." named by Spark |
| sanitizer / hand spray | Got it (`gone_from_spot`) | 59.7 s | "I can't see your hand." 3 times while reaching 10–15 cm away |
| key | Got it after a stall check (`stalled`, v9.2) | 110.7 s (68 s scanning) | "Hold your hand out." 3 times; "Something is ahead." with the key 14 cm away |
| mug | **Got it (`held`)** | **34.4 s** | Reference run |

Also in the mug search: `support none`, so there was no obstacle map at all next to a glass pitcher and bottles; the first direction was one 85 cm move.

Follow-up (2026-11-01): Spark now verifies every single lock (no 0.75 threshold); a rejected lock is remembered so the scan skips it, and after 3 rejections the search ends with "I can't find the X." Rolling-scan growth, replayed offline from `burst_1_1` (36 frames, same filters): 270–375 points per scan, about a quarter within 8 cm of the six hand keypoints (palm, fingers and a fleece sleeve beyond the 4 cm carve), the rest real clutter left of and in front of the book; addScan now carves 9 cm around the joints and widens the arm cone by 4 cm. Measured reach in this run: 37 cm.

Second follow-up (2026-11-01, Nils's decisions on the Muse Spark and GPT reviews): every 8 s wait is 6 s; the agent's choice is verified too; rejected locks fall back to the likeliest one ("I'm not sure this is the X."); one look-around call per lock names things, flags dangerous ones and adds flat hazards (sim `hazard`: 20/20, no touch); a same-kind thing starts a which-one talk; no support height keeps every surface except the landing patch (sim `no_support` 20/20); hand capsules from the measured hand replace the 9 cm ball (replay of `burst_1_1`: the ball removed 61–137 points per scan, about half of them below the hand, i.e. clutter under it; capsules remove 0–24); "Not sure" reminder after 6 s, hand away -> guide again. Live Spark test of the utensil-holder photo not run (no key in `sightline/.env`). 202 tests pass; iOS build succeeds.

Third follow-up (2026-11-01): Nils's case 1 / case 2. A sure user closes the app; double tap = "Is this it?" -> "Yes. That's the X." / "No. The X is still there." / "I can't tell. Hold it up to the camera." + one more look after 3 s, then "I still can't tell. It may be the X."; `user_confirmed` obsolete. Then (Nils: "It may be the X." is not responsible): an unsure held-up look hands over to a Spark description of the hand photo or how to move it into view; Spark prompts ask for the simplest reply instead of word caps. 204 tests pass; sim all positive scenarios 20/20 (self = user closed the app 0–6 per scenario), faults 0/20 with no silence or loops; iOS build succeeds. STT experiment (304 synthetic clips from past test lines): Apple cuts 28/28 mid-sentence pauses and is ready 2.1 s after speech; Muse realtime with a punctuation-aware stop is ready in 0.5 s, cuts 7 (complete short sentences), key word right 93 % vs 82 %. See `docs/STT_EXPERIMENT.md`.

Open points: wrong identity above the verify threshold (fixed in code, device pending); no obstacle map without a support height; the target's own edge named as an obstacle; the map growing several hundred points per second (check what the rolling scan adds); two "Not sure" ends with no double tap.

## T12: v9.2 follow-up + Muse speech on the device (2026-11-01 15:54–16:13 PDT, `logs/v9.2/20261101_145437`, `find_log_1793573677.csv`)
Build: branch `muse-voice` (v9.2 follow-up + Muse Voice Transcribe). Nils, 11 searches and one room scan.

| Search | Result | Time | Notes |
|---|---|---|---|
| "I need my headphone" | Got it | 53 s | Not in view, scan, found 40 cm; 4 directions |
| "find my iPad" | Got it (2nd check) | 90 s | Spark said no to the lock; 56 s of scanning, then "I'm not sure this is the ipad." and it was |
| "help me find my cup" (clear glass) | Yes after a double tap | 107 s | 4 cups: "the one on your left or one on the right?"; Nils: "What's different?"; the agent only had positions. LiDAR shape "flat 35x0x64 cm" = the table seen through the glass |
| "scan the room" | Saved, 26 items | 32 s | Tapped after 3 views because the line said "Tap when done" |
| "I need napkin" | "Got it" on a cloth | 67 s | SAM's "napkin" was a green cloth; Spark described a receipt in the hand; Nils meant kitchen paper |
| "like kitchen paper" | Got it | 83 s | Room-map hint used ("last seen ahead, a little to your right") |
| "I'm thirsty" ×2, "it's not a water bottle", "it's not a … cup" | 2 stopped, 2 got it (143–200 s) | | The agent ran `find_object` on the current view for tumbler and black bottle, which the room scan had saved elsewhere, and offered only what was in view. 3 Spark rejections before the small cup |

- **Saved room map never matched at launch:** `room_map_fallback` 8 s after launch, in this run and in all 5 earlier logged launches (V5 to V9.1.3). Hints only worked after a scan in the same launch.
- **Hold checks were right:** the clear-glass "Yes" (all spot depth invalid, Spark yes) shows Nils holding the glass. Depth layers say nothing on clear or flat things; Spark carried the checks.
- **Speech (Muse vs Apple, same audio):** Apple "I need my head", "Scanner room", "Vasala the difference", "The class", "And nap"; Muse got all of these right but repeated words twice ("help help", "don't don't") and heard "Up." where Apple heard nothing.

Changes (2026-11-01, Nils: "scan the room mode shouldn't ask user tap to stop"; "the system doesn't use the scan room saved map"; "doesn't describe the shape or appearance when there're two or more same name object"; "can't the system identify flat, transparent or no color object?"):
- Room scan ends by itself (`ScanPlanner.mappingDone`: the camera swept all 12 sectors and ≥ 6 views, or 12 views).
- Relocalization 30 s with spoken outcome; a tap to search ends it.
- Agent: `find_object` with nothing found returns the room-map place; the instructions say `scan_for` at once.
- After each find, a labelled-box photo; look-alikes are asked about by appearance.
- See-through: a LiDAR shape wider than 2.5x the photo box + 5 cm is dropped (`ObjectModel.fitsBox`).

208 tests pass; sim unchanged (positive 20/20, faults 0/20); iOS build succeeds. Device pending.

Follow-up (2026-11-01, Nils: "why not let the LLM read the map first and infer the position from related things"): the map held only names + positions in the saved ARKit frame, useless without a match. Now the room scan also saves what each object stands on and fixed landmarks; relations are said with no frame; landmark alignment (Spark lists the view, RANSAC over name matches, 4 degrees of freedom: turn about gravity + shift) gives the saved frame back without ARKit. 215 tests (relations, old files without the new fields, a known 70° turn recovered within 1 cm, a moved cup left out, 2 movable things rejected, 2 fixed accepted); iOS build succeeds. Device pending.

## T13: room map, find the vitamin (2026-11-02 11:37–11:40 PST, `logs/map feature/20261102_113703`, `find_log_1793648224.csv`)

Build `muse-voice` (de6415e + uncommitted review fixes). Nils tapped before the saved map matched, scanned the room
again (auto stop after 8 views, 28 items, 42 s), then asked twice for "vitamin". Same launch, so the map had a frame.

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
| 1 | Vitamin not found in 2 searches (17 SAM calls), reported as "map feature failed" | The map worked: `room_hint vitamin bottle` both times and the user was turned to it ("Hold still. Looking there now."); the Nature Made jar is in plain sight in `19_scan_photo.jpg`. SAM was asked for "vitamin", which is not a thing it can see; the scan had saved it as "vitamin bottle" | `RoomInventory.searchName(for:)`: SAM is asked for the saved name when it is the user's word plus more; log `sam_query vitamin -> vitamin bottle (room map)` | Unit test `searchesForTheSavedNameWhenItSaysMore`; iOS build | Fixed, not on device |
| 2 | The give-up line said "behind you, half a turn, 2 m" after the first said "a quarter turn right, 1 m" | The user had turned past it while the scan said "Turn right slowly. I haven't looked there yet." | Partly: the scan now looks again in directions searched from more than 75 cm away (`ScanPlanner.scannedFrom`) | Unit test `aDirectionIsNewAgainAfterWalking` | Not on device |
| 3 | Spark's last guess "Check the white shelf on your left" ignored the map | `spark_suggest` does not get the room map | None yet | - | Open |
| 5 | Follow-up (Nils: "do all five") | SAM is asked for what it can see: room-map name or scan alias, else Spark's name cached in `sam_names.json`; a crop around the map spot first, whole photo after a miss; scan directions new again after walking; Spark's alignment listing adds things the scan missed | See AGENTS.md "What SAM is asked for" | 222 unit tests, sim unchanged (positives 20/20, faults 0/20), iOS build | Not on device |
| 6 | Review of 5 (Nils: rolling update, fix the old hint) | "bottle" with two bottles saved was narrowed to one for SAM and the crop, and the spoken hint pointed at one; a moved thing left a duplicate entry | `RoomInventory.target` (one saved thing or none) for names, crop and hints, `fits` + "I remember a … and a …"; `refresh` rolling update with an in-view and nothing-in-front check; tiles decided by the user's word | 226 unit tests, sim unchanged, iOS build | Not on device |
| 4 | Room views 5, 6 and 8 listed nothing | Wall, window and chair; Spark skipped them as told | None needed | - | - |

## T14: v9.4 room map, water bottle, vitamin, sunglasses (2026-11-03 11:03–11:11 PST, `logs/v9.4/device/diag` from `diagnostics/20261103_105842`, `logs/v9.4/device/find_log_1793732323.csv`)

Build `muse-voice` (de6415e + uncommitted T13 fixes). Nils: "Big failed. all dots are gone. it couldn't find anything. the map
isn't remember and reconized anything. miss record the object. there's no water bottle. the target object be identify as
blocker". The saved map did not match at launch (`room_map_fallback`); Nils scanned again (5 views, 32 items, auto stop),
then asked for the water bottle twice, the vitamin by the agent and by the plain command, and the sunglasses. A second
launch at 11:11 only logged the start line. Logs and photos were copied from the phone with `devicectl` (read only).

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
| 1 | Water bottle (2 searches, 13 SAM calls) and sunglasses (4) not found; "Hold still. Looking there now." 3 times, then give up, 24 s with no call (also in T13) | Both were saved on the mantel, above the chest phone. Facing it, the camera view had already been searched, so `ScanPlanner` never scanned; the prompt compared only left/right, so it said "hold still" instead of "higher" | The saved spot inside the view and never looked at from here makes the view new (one call, the spot counts as looked at); facing it but out of view says "Point the phone a little higher." / "lower" | Unit test `aSavedSpotAboveTheViewIsNotAWait` (failed first, as on the phone); 227 tests, sim unchanged, iOS build | Fixed, not on device |
| 2 | "There's no water bottle" | The room scan named the clear shaker with a black lid on the mantel (`04_room_photo.jpg`) "water bottle" (aliases bottle, shaker); SAM does not call it one | A saved spot in clear view (within 2 m, nothing in front) where neither the crop nor the whole photo finds it counts once (`room_spot_empty`); twice in a launch: "I remembered a water bottle on the mantel, but it isn't there.", that entry is forgotten (`room_map_forgot`) and the scan stops steering there | Unit test `aThingNotAtItsSpotIsForgotten` (the rule in the app: iOS build only); 229 tests | Fixed, not on device |
| 3 | Vitamin through the agent: 6 `find_object` calls (vitamin bottle, pill bottle, medicine bottle, small bottle, yellow bottle, yellow box) on the same view, a question about the colour, 79 s, nothing | The bottles were on the window desk, not in that view (`18_sam_photo.jpg`), and not in the room map (the scan did not list them). The agent kept renaming instead of turning the user (`scan_for`) | After 2 names found nothing, the next `find_object` starts the scan for the first name instead (`agent_scan ... names not in view`); here it would have scanned after "medicine bottle", about 25 s in | iOS build | Fixed, not on device |
| 4 | Vitamin by the plain command: found in 16 s (scan, Spark's name "pill bottle"), two look-alikes asked by colour, guided to the green one, "at your fingers" with the index tip at the bottle's left side (`27_grab_overlay.jpg`) | Worked | - | Photos | - |
| 5 | Hold-check SAM asked for "vitamin" (`still_7_*`) | The check used the user's word, not the search name | The check uses `samQuery` ("pill bottle") | iOS build | Fixed, not on device |
| 6 | "The target object is identified as a blocker" (Nils: all three lines, "it doesn't identify the object entirely") | The lock sees only the bottle's front (LiDAR shape 3 x 7 x 4 cm for a 6.5 cm wide bottle). As the hand went round, the rolling scan saw its side and back, more than 4 cm from that front, and kept them as obstacles: "Something is ahead / on your right / on your left" | `ObjectModel.isHiddenPart`: a point behind a visible point as seen from the lock camera, up to the photo box width deep (`hiddenDepth`), is the target, not an obstacle. Something beside or in front of it still is | Unit test `theBackOfTheTargetIsNotAnObstacle` (failed first); 228 tests; sim unchanged (obstacle 17/20 and late_obstacle 16/20 warnings kept); iOS build | Fixed, not on device |
| 7 | "All dots are gone" (Nils: no finger or object dot) | The screen snapshots of this run have no dots; v9.2's (`logs/v9.2/20261101_145437/05_hand_seen_screen.jpg`) have them. Likely cause: the saved room did not match, so tracking was reset with `removeExistingAnchors`, and the dots' world anchor was never added again (v9.2 had no saved room, so never took this path). Not proven | The camera view adds a new dot anchor after each reset (`sessionResets`) or when its anchor left the scene | iOS build | Fixed (likely cause), not on device |

## Template
```
## Tn: <what> (<date> <time>, <log folder>)
Build `<commit>`. <who tested, how long, what was searched>.

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
```
