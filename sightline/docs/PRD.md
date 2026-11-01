<!-- labels: important, needs-review -->
# Sightline — PRD

_As of 2026-10-26, find-and-grab section updated 2026-10-31 (v9) · Owner: Nils_

## Positioning
Say what you want; Sightline finds it and guides your hand to it. An indoor AI guide for blind, low-vision and older users.

**Problem**
- Description apps (Be My AI, Seeing AI) assume the user can aim the camera; blind users often can't tell what was captured.
- LiDAR obstacle apps (White Cane) give distance only, no meaning.
- None guide the hand the last metre: "right 10 cm, a bit higher, now grab."

**Hackathon:** Meta Global AI Developer Hackathon, Indie Developer track, *Build for Your World*. Submission due 2026-11-04, 9 PM ET (6 PM PT) on the Cerebral Valley platform.

- **Submit:** public repo + 3-minute demo video (primary judging artifact) + code and live product. No hosted link required; a native iOS app is fine.
- **Must:** use Meta models via Meta Model API; clearly show what was built during the event (Oct 26 – Nov 4). Demo shows only hackathon-built features.
- **Judging:** Stage 1 pass/fail (fits theme, uses Meta models). Stage 2, 0–10 each: Impact 30%, Use of Meta AI tooling 25%, Technical depth 20%, Demo 25%. Top 5 per track go to a live final round on 11/9.
- **Bonus prizes worth targeting:** Best Agentic Use-Case ($5K, Muse as commander with tool calling); Most Viral on X ($20K, post the demo by 11/8).
- **Avoid looking like an anti-project:** "simple image analyzer" and "medical advice" are named. Lead the demo with hand guidance, not object description.

## Current find-and-grab behaviour (v9.2, 2026-10-31)

This section is the current requirement; where older sections below differ (e.g. "now grab", ≤ 5 SAM calls), this one wins. Background: v8 (a ChatGPT rewrite, 2026-10-30) added reach safety but latched every stop, required a 4 cm movement test and seven on-screen controls; Nils rejected the flow and voice. Its Chinese PRD is kept in the `chatgpt-reach` branch (commit 93766c8).

**Scope.** Body still, phone on the chest, objects within comfortable reach indoors. Not included: walking or outdoor navigation, a full body/forearm model, grip-strength or safe-grasp guarantees, external sensors, accounts, offline search, medical advice, multiple app languages.

**Required behaviour**
1. Reach is measured once (long press, index fingertip held out comfortably, stable ≥ 0.8 s; median distance minus 3 cm) and saved, together with the hand length (median wrist-to-index-tip, accepted 10–26 cm). Both are user settings, not ergonomic or clinical assessments.
2. Distance never stops guidance (Nils, 2026-10-31: "I don't care how far the object is, it must guide"). The reach only scales thresholds (11) and decides whether a staged waypoint is used (horizontal distance; a drop down to 1.2 × reach and a rise up to 0.5 × reach count as within it). A staged waypoint beyond reach falls back to going straight for the object only when the object is within reach. (v9 ended the search with "It's out of reach. Move closer, then search again."; removed.)
3. Directions use one real fingertip (index first). Flat objects: up, across, down to the near edge; solid objects: depth first, then the near side.
4. Obstacles (v9.2; Nils: touching things on the way is normal for a blind user, time to the object is the core KPI). The map starts from the lock frame (things 3–50 cm above the table near the target, away from the body and the target's edge; at least 3 points; the user's arm removed when the hand appears) and grows with a rolling scan about once a second (a cell joins only when seen in two scans in a row; arm and hand removed). One Spark look at a photo with numbered marks names the things. A move heading into one gets one line with the name and the side to pass it ("A bottle is ahead. Go around it on your right." / "Careful. A bottle is on your left."), then guidance goes straight on; no stop, no planned detour by default (the v9.1 detours are kept behind `maxDetours`). The side is the object's side, else away from the thing, else the side with fewer things. Nothing ends the search. Something dangerous (blade, flame, spikes, broken glass) is always stopped for and gone around; a look-around Spark call at each lock names things, flags danger and finds flat hazards. Without a measured support height every surface counts (the table too) except where the hand lands. Another thing like the target nearby: a short talk asks which one. This is a screen, not proof that the path is clear.
5. Near the object: "Stop. The book is at your fingers." (cups: "Feel for the side."). The user explores by touch and chooses the grip. Proximity is never reported as contact.
6. Lost tracking: "Hold still." and resume. A turned or moved body re-bases the direction frame. An object more than 20° to the side: "Turn a little to your right, to face it.", then guidance.
7. A hold check is started by the object, not by any hand movement (v9.1; Nils: "if I place my hand without grabbing anything, it must not count"). First the fingertips must come near the object (a contact candidate: ≥ 2 tips within a hand-sized 4 cm of its points; this is not proof of contact). Then one of: the hand moves a reach-scaled 10 cm away from where the object was (`near_then_left` / `left_object`), the hand rises a reach-scaled 5 cm above its lowest point near the object for 0.2 s (`near_then_rose`, tall objects), or the hand is lost for 1.5 s after contact (`near_then_lost`). One check per event; a hand put down and lifted away from the object never checks. Since v9.2 two more events check: the same direction said 4 times without a "Stop." in between (`stalled`: the user may hold it, hidden while gripping), and the object's spot going empty in LiDAR for 0.5 s after it was seen full (`spot_empty`, objects ≥ 3 cm thick). The check: one photo, SAM (where the object is now) + Spark (photo and reference crop: is the hand holding it), combined by `HoldDecision`. At most 6 automatic checks per search; 12 hold SAM calls per search.
8. Results: "Got it. You have the X." / "The X is still there." (guide again) / "I can't tell. Hold it up to the camera." (one more look 3 s later; if still unsure, Spark says how to move it into view or what it sees in the hand, then "Double tap to check again.") The hand resting on the object 12 s without a pick-up: "It's right below your hand." every 6 s. A hand that leaves the object after an unsure check is guided again. The hand gone about 11 s: "I need to see your hand to guide you." and up to 3 spoken turns with Spark (v9.2). Holding it (2026-11-01): a user who is sure closes the app; one who is not asks "Is this it?" (double tap): "Yes. That's the X." / "No. The X is still there." / "I can't tell. Hold it up to the camera."
9. Controls: tap = start / stop (finishes a room scan), double tap = "Is this it?", long press = measure reach. VoiceOver: activate = double tap, magic tap = tap, named actions Stop, Status, Is this it?, Measure reach.
10. Voice: one action per line, about 8 words or fewer; no button names; no disclaimers; only Stop, obstacles and check results interrupt.
11. Body scale (Nils: no centimetre threshold may be absolute, because everyone's reach differs). Arm-sized thresholds (leave 10 cm, rise 5 cm, forearm 20 cm) scale by reach / 52 cm; hand-sized ones (near 4 cm, grab radius, axis and start tolerance, path clearance 8 cm) by hand length / 18 cm. Each ratio is clamped to 0.6–1.5; with nothing measured the ratio is 1. Object and sensor thresholds (spot radius, depth tolerance) are not scaled.
12. Evidence for tuning, record only: each check logs `spot_evidence` (depth at the object's old points: vacated / occupied / occluded / invalid) and saves a burst (2 s before and 2 s after, 10 Hz: depth, confidence, poses, joints, small photos; ≤ 5 per search, ≤ 30 per launch). Neither changes the result yet.

**Release checks.** Report unit tests, simulation, compilation, device runs and blind-user evaluation separately; a passing test is not a safety certification. Track: Stop from every state, stale cloud results never restarting a task, false successes (wrong object, object not moved, hand passing over it), obstacle stops, VoiceOver on and off, time to first response vs. first usable direction, cost per search from the logs. Real use is judged against the participant's own way of finding things.

## Users and scenarios
Primary: blind and low-vision people. Secondary: older adults with declining sight. Caregivers do the first room scan.

| Scenario | User says | Sightline does |
|---|---|---|
| Find and grab | "Sightline, find the cup" | Locates the cup, guides the hand: "right 10 cm… now grab" |
| New floor obstacle | (automatic) | Detects something not in the baseline map: "shoe on the floor, 1.2 m ahead" |
| Read a label | "What is this?" | Reads name and text of the held object |

## Architecture
1. **Scan:** RoomPlan / LiDAR builds a baseline room map.
2. **Label:** SAM 3.1 + Muse attach semantic labels, e.g. `cup @ (x, y, z)`.
3. **Trigger:** Action Button (primary) or Siri / Vocal Shortcut via App Intents.
4. **Command:** Muse Spark reads live state via tool calling; decides target, handles obstacles, rephrases.
5. **Local loop (30–60 Hz):** ARKit + Vision hand pose → hand-to-target vector → spoken guidance.
6. **Re-check (event-triggered):** SAM confirms the target is still there on target lock, when tracking confidence drops, and once before "now grab"; re-locks if moved. ≤ 5 SAM calls per guidance session.
7. **Map fills blind spots:** obstacles outside the current view stay in the map to warn about collisions.

## Meta tools
| Component | Role | Rate |
|---|---|---|
| Muse Spark | Commander: parse, read state, decide, phrase | event-driven, ≤ 1/s |
| SAM 3.1 | Eyes: find and segment by text, re-confirm | event-triggered, ≤ 5 per session |
| Muse Code | Scoped coding tasks (functions, bugs, tests) | dev time |

## Division of labour
| Who | Owns |
|---|---|
| Claude Code / Claude | Main Swift codebase, architecture, code review, docs |
| Muse Code | Scoped tasks on `muse/<task>` branches, reviewed before merge |
| Nils | On-device builds and tests, numbers and logs, scope decisions |

## Cost model (zero out-of-pocket)
All usage bills the $150 hackathon Model API credit; no paid Muse Code plan. Meta requires a card on file, so a Spend Limit ≤ $150 is set.

| Item | Estimate |
|---|---|
| One guided grab (SAM ≤ 5 calls, Muse ~10 calls at `reasoning_effort: medium`, 512 px images) | ~$0.05–0.15 |
| Dev + demo (~300 sessions) | ~$15–45 |
| Muse Code coding usage | biggest risk; cap ~$15/day, else shift to Claude |

Verify with the Billing delta after the first spike run (see `docs/SPIKE.md`).

## Competition and differentiation
Closest: **NaviSense** (Penn State, ASSETS '25) — voice → VLM → LiDAR/AR → hand guidance; and **AIGuide** (ARKit hand guidance). Commercial: Seeing AI Find My Things, Google Lookout Find, Apple Magnifier, Be My AI, Envision Ally Solos, White Cane.

Sightline's differences:
1. Tracks the **actual hand** (Vision) with the phone worn on the chest; NaviSense infers the hand from phone motion, so the phone must be in the reaching hand.
2. **Baseline map + change detection** remembers the home and spots new obstacles; NaviSense avoids pre-scanning.
3. **Muse as commander** via tool calling, not just a recognizer.
4. **Pixel-level SAM masks** give a precise 3D grasp point, not a box centre.

Cite NaviSense in the demo and README.

## MVP scope
**In:** room scan + labelled baseline map; Action Button (primary) / Siri trigger; full find-and-grab flow; new-obstacle detection; speech + distance tones.
**Out:** walking navigation, outdoor, external sensors, multi-language, accounts, offline, medical advice.

## Milestones
| Date | Milestone |
|---|---|
| 10/26 | Spike 0 (`docs/SPIKE.md`): ARKit sample on device; Muse + SAM on 5 photos with latency and cost; read official rules |
| 10/27–28 | **Gate:** hand 3D error ≤ 3 cm; relocalization |
| 10/29–31 | Core: find + grab |
| 11/1–2 | Obstacle detection + voice trigger |
| 11/2–3 | Blindfold testing and fixes |
| 11/3–4 | Demo video, README |
| 11/4 | Submit before noon PT |

Gate fallbacks: hand error > 3 cm → guide to within 10 cm then prompt touch exploration; relocalization unstable → scan and use in the same session.

## Success metrics
| Metric | Target |
|---|---|
| Hand-to-target 3D error | ≤ 3 cm |
| Blindfold grab success | ≥ 8/10 |
| Command to first guidance | ≤ 3 s |
| Local guidance update rate | ≥ 10 Hz |
| Floor obstacle detection | objects ≥ 5 cm tall |
| API spend | < $150 total |

## Risks
| Risk | Mitigation |
|---|---|
| Borrowed iPhone time limited | Fixed 2–3 h/day on the Mac; unit-test logic on Mac first |
| Unfamiliar with Swift / Xcode | Code written by Claude Code; run Apple's ARKit sample day 1 |
| Hand 3D error too large | Measure 10/27–28; fallback above |
| Relocalization fails | Same-session scan for demo |
| SAM / Muse latency | Cloud only identifies; guidance is local; "identifying" tone while waiting |
| Credit burned by coding agent | Claude writes the main code; Muse Code on scoped tasks; daily Billing check |
| Muse misnames object | Say "not sure"; user can correct by voice |
| Judges can't run a native app | Check rules; video + repo, TestFlight as backup |
| Safety liability | Indoor only; not a cane or guide-dog replacement; no walking navigation |

## Vision
Sight should not decide whether someone can live on their own.
- **2–4 weeks after:** Chinese voice, multi-room maps, small pilot with a blind-services org.
- **1–3 months:** chest depth camera (e.g. OAK-D Lite) + earbuds, or Ray-Ban Meta via the Wearables Device Access Toolkit.
- **Later:** room-to-room indoor navigation, caregiver remote view, MapAnything 3D reconstruction for non-Pro phones.
