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

## Template
```
## Tn: <what> (<date> <time>, <log folder>)
Build `<commit>`. <who tested, how long, what was searched>.

| # | Issue | Root cause | Solution | Checked by | Status |
|---|---|---|---|---|---|
```


## 人因與取物控制修訂（2026-10-30，程式驗證；尚未實機驗證）

這次依使用者提出的十項問題，調整本機控制、介面與文件。原有未提交修改在開始前另存快照，既有測試紀錄保留；本節不是新增的 iPhone 或真人測試結果。

| 項目 | 修正 | 狀態 |
|---|---|---|
| 可及範圍 | 舒適食指距離量測、目標／路點／實際逐軸終點界線、背景後重測；量測含獨立逾時 | fixed (code)，待實機 |
| 人體動作 | 同一實際指尖；平面物件抬高／橫移／下降；近側邊緣與觸覺探索 | fixed (code)，待人因評估 |
| 障礙 | 當前點雲；正在執行與下一候選軸均檢查；含端點的膠囊間距；共用前臂近似與自身排除；深度不足保留未知 | fixed (code)，不是完整避障保證 |
| 失效停止 | tracking、旋轉／位移、無新影格、背景、手消失均有停止處理；定位恢復需新搜尋 | fixed (code)，待實機 |
| 持有確認 | 兩影格語意比對及共同移動；缺參考、單模型、物件消失、靜止或矛盾證據不成功；先播完提示再拍第二張 | fixed (code)，未呼叫真實雲端驗證 |
| 身份影像 | 每個候選保存自己的來源影格與裁圖；不再將被否定的候選在放棄時拿來引導 | fixed (code)，待實機 |
| 控制與取消 | 固定 Stop／Status／Check／自行確認／掃描儲存；取消麥克風、每個 await 後核對任務；影格含 session/check token | fixed (code)，待 VoiceOver |
| 語句 | 說明接觸尚未確認；明說移動手；成功說明物件身份；不確定後不導向舊位置 | fixed (code)，待使用者回饋 |

### 已完成驗證

- 修改前基準：125 項 Swift Testing 測試通過。
- 修改後：145 項測試、32 個 suite 全部通過，其中 ReachSafetyTests 新增 20 項，涵蓋伸手界線、分階段接近、追蹤與方向停止、手消失、活躍軸障礙、逐軸中間終點、前臂模型、深度未知與持有共同位移。
- iOS 17 arm64 目標：SightlineCore 模組編譯與全部 App Swift 原始碼型別檢查通過，包含 Observation 與 SwiftUI 巨集；使用專案的 MainActor 隔離設定。這不是已封裝的 App 建置。
- 完整 xcodebuild：未完成。專案本機 Swift package 的 manifest sandbox 在此執行環境回報 `sandbox_apply: Operation not permitted`；不將此寫成程式編譯失敗或成功。直接使用 SDK 的原始碼檢查已完成。
- `git diff --check` 通過。
- 兩軸獨立審查提出的活躍軸、超界中間終點、未知深度、自身前臂、第二影格時序、取消重開麥克風、候選圖片錯配與參考缺失均已修正。
- 合成模擬器已改用新版語句與兩影格共同移動判定；完成取物與停止分開呈現。單一固定 seed 的 normal 完成、obstacle 停止；完整批次結果另列於本節後續紀錄。

### 尚未完成

- iPhone 上的深度、姿態、動態障礙、校準及長時段音訊。
- VoiceOver 全流程、App 中斷／返回及真實網路逾時。
- 新版兩影格 API 延遲與實際帳單成本。
- 視障使用者共同設計、原有方法比較、疲勞和外援評估。

下一次實機測試依 FIND_TEST.md，不套用舊版 tap=check 或自動「Grab it」步驟。

完整模擬第一批（十五情境、各二十次）揭露短暫指尖缺失會反覆換點並重設靜止計時；已改成保留同一指尖直到持續缺失。瓶子情境也揭露過早側移可能離開畫面；立體物件改先對齊深度。這兩項各新增回歸測試，後續批次結果另列，不沿用原批次成功率。

瓶子確認的另一限制是握瓶時掌心容易超出胸前相機視野；兩影格共同移動改成必須使用兩次都可見的同一個實際手指關節，而不強制要求掌心。關節不同或缺失時仍不確認，不因放寬可見部位而降低物件身份／共同位移門檻。

### 最後針對性模擬（新版，固定 seeds 1–3）

| 情境 | 自動完成取物 | 鎖定停止 | 說明 |
|---|---|---|---|
| normal | 2/3 | 0/3 | 一次未在時限內取得足夠確認證據 |
| index_hidden | 3/3 | 0/3 | 食指 70% 掉點，參考點保留修訂後可繼續 |
| bottle_side | 0/3 | 3/3 | 目標超過二十度，先放下手、面向物件並重新搜尋；停止不算取物成功 |
| bottle_centered | 2/3 | 0/3 | 模擬重新面向瓶子後的新搜尋；一次未完成確認 |
| obstacle | 0/3 | 3/3 | 障礙否決動作，停止不算取物成功 |

這是合成資料，不是真人結果。較少自動成功是保留不確定的結果之一，不能宣稱所有場景均能可靠取物。模擬器尚未代替使用者在無法確認時選擇自行確認，也沒有測量真正的網路、左右手分類與硬體誤差。

瓶子案例排查也修正了模擬器的感測模型：最低有效關節數從四個改成與實機 HandKeypointLocator 相同的兩個；原本錯誤的硬編碼 phone 名稱改成各情境的真實名稱。未為提高成功率而放寬實際持有門檻。


## 有限次確認修訂：保留證據、一次水平動作、明確出口

本輪依使用者採納的六項方案實作，不新增真人測試結果。取代上一輪兩張固定配對與重試抬高流程。

- 身份改為比對原參考與當前畫框候選；持有使用本機共同位移與接近證據，沒有把拇指可見當必要條件，也沒有放寬四公分接近門檻。
- 最多三次影格請求／三次 SAM 與三次身份比對，總時限三十五秒；其中兩次身份肯定、至少兩個共同實際指尖與物件共同移動才確認。中間漏檢保留 anchor 與其自身表面。
- 同一關節一百五十毫秒內可補掉點；穩定需檢查整個窗口，不只比較首尾。自然移動先觀察，不另加動作。
- 若仍需動作，最多提示一次四公分水平移動，不再累積向上抬高。動作／提示播放／雲端等待期間持續查新深度、障礙、持物可見表面、共同指尖、視野、伸手距離、反向及七公分上限。
- 未確認後 Check 停用、GuidanceSession 停止自動再啟動；固定提供自行確認、New search、Stop。逾時與晚結果也不能重啟。
- 模擬器共享 collector、短歷史、動作規劃與否決，身份真值不再等同持有；加入 wrong_object、hand_only、object_only、slide_only。

### 程式驗證

- **169 項 Swift Testing 測試、33 個 suite 通過**；相對上一輪新增 24 項確認回歸測試。
- iOS 17 arm64：核心模組編譯與 App 全部 Swift 原始碼型別檢查通過。完整 Xcode 包裝／簽章／真機安裝未驗證，原環境套件沙盒限制仍未以完整建置重測。
- git diff --check 通過。
- 兩軸審查找到並修正：提示與雲端等待時監控中斷、只有一共同指尖未停止、持物邊緣漏查、anchor 表面錯配、首尾相同的來回移動誤判穩定、反向動作漏查，以及模擬身份與持有混用。

### 合成結果（seeds 1–10）

| 情境 | 自動完成 | 明確無法確認 | 停止 |
|---|---|---|---|
| normal | 4/10 | 6/10 | 0/10 |
| index_hidden | 2/10 | 8/10 | 0/10 |
| bottle_centered | 4/10 | 6/10 | 0/10 |
| obstacle | 0/10 | 0/10 | 10/10 |
| wrong_object | 0/10 | 10/10 | 0/10 |
| hand_only | 0/10 | 10/10 | 0/10 |
| object_only | 0/10 | 10/10 | 0/10 |
| slide_only（明確按 Check） | 0/10 | 10/10 | 0/10 |

slide_only 以模擬使用者按 Check 的整合案例驗證，讓未抬離支撐面的滑動確實進入 collector，而非只等待抓取逾時。四類反例合計四十次皆未自動確認成功，且均明確結束為無法確認。

原失敗 seed 的最後追蹤：normal seed 3 在 53.47 秒取得第二次肯定與共同位移並完成；bottle_centered seed 1 第一張 SAM 漏檢，第三張注入身份否定，在 33.10 秒明確結束，不繼續抬高／重試到 150 秒。後者不是取物成功，模型拒絕仍可能降低可用性。

這些是合成的模型漏檢、身份錯誤與關節誤差，不是真實 API 或 iPhone 數據。四個反例採可控制真值，不代表對真實同類物件誤認有零風險保證。自動成功率仍不足；保留不確定改善了退出行為，沒有證明產品已可靠。

### 待實機

VoiceOver 的終態選擇、按 Stop／New search 後的雲端取消隔離、真實身份提示品質、深度／姿態誤差、有限次觀測的延遲與費用，以及視障使用者疲勞與原有取物方法比較。
