<!-- labels: important -->
# Sightline — PRD

_As of 2026-10-26 · Owner: Nils_

## Positioning
Say what you want; Sightline finds it and guides your hand to it. An indoor AI guide for blind, low-vision and older users.

**Problem**
- Description apps (Be My AI, Seeing AI) assume the user can aim the camera; blind users often can't tell what was captured.
- LiDAR obstacle apps (White Cane) give distance only, no meaning.
- None guide the hand the last metre: "right 10 cm, a bit higher, now grab."

**Hackathon:** Meta Global AI Developer Hackathon, Indie Developer track, *Build for Your World*. Judged on creativity, technical ambition, and whether it works. Submission due 2026-11-04, 6 PM PT.

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
All usage bills the $150 hackathon Model API credit; no paid Muse Code plan, no card (or a spend limit < $150).

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
