<!-- labels: obsolete, reference, needs-review -->
# Human factors revision (v8, 2026-10-30) — OBSOLETE

> **Obsolete since v9 (2026-10-31).** Nils rejected the v8 flow and voice ("the whole process is a piece of shit user experience, and the voice instruction is crumbled"). The current contract is in [AGENTS.md](../AGENTS.md) and [PRD](PRD.md) ("Current find-and-grab behaviour"). This file is the English record of the v8 document, which a ChatGPT session wrote in Chinese; the original text is in the `chatgpt-reach` branch (commit 93766c8). What v9 kept is marked **kept**; the rest was replaced.

## Principle (kept)

The user decides whether to touch, how to grip, and whether to accept the system's verdict. The system helps locate and approach; it cannot infer real contact, load-bearing or safety from images or distances. A segmentation mask gives a visible surface, not full object geometry, friction, weight, temperature or grasp quality.

## The ten issues and the v8 fixes

| Issue | v8 fix | v9 |
|---|---|---|
| Found is not reachable | Measure comfortable reach on every mounting; gate target and waypoints; stop when out of range | **Kept**, but measured once and saved; a waypoint beyond reach falls back to the direct path |
| Fixed axis order is unnatural | Flat objects: up, across to the near edge, down; solid: depth first, then the near side | **Kept** (ReachApproach) |
| Moving on after an obstacle warning | Check the axis segment for fingertips, palm, wrist and a forearm approximation; latch a stop | Kept the check; the stop now resumes when the path is clear for 1 s (8 s blocked ends the search) |
| Near reported as contact | Near only starts tactile exploration | **Kept**; spoken as "Stop. The book is at your fingers." without a disclaimer |
| Centre is not a grasp point | Near edge for flat objects; edge / near side / handle hints | Kept in short form (cups: "Feel for the side.") |
| Occlusion treated as user error | Hand gone > 0.5 s: interrupt, silence, offer Check or return | Said once ("I can't see your hand."), only while guiding, after 1 s |
| Single image confirms success | Up to 3 observations, 2 identity-positive with shared motion of ≥ 2 fingertips; one requested 4 cm movement | Replaced by the v7 one-photo check (SAM + Spark, HoldDecision), any pick-up triggers it |
| Camera vs. body frame mixed | Fixed frame; > 15° or > 6 cm camera change latched a stop | Re-base the frame instead of stopping |
| Guiding on failed tracking | Tracking not normal, frames stalled > 0.75 s or app in background: latch a stop until a new search | "Hold still." and resume; background ends the task silently |
| Hidden state changes button meaning | Main area starts when idle and stops during tasks; fixed Stop, Status, Check, self-confirm, finish-scan controls | Tap / double tap / long press; VoiceOver actions; buttons only for a sighted helper |

## v8 limits that still apply (kept)

- The current point cloud only sees measurable surfaces in view; transparent, reflective, thin or hidden objects can be missed, and excluding the hand and target leaves blind spots.
- The forearm is approximated as a 20 cm segment from the wrist toward the camera with an 8 cm path clearance; not a skeleton or swept-volume model.
- No verified automatic detour or "safe grasp point".
- Comfortable reach is a user measurement, not a universal reach range.
- Shared motion or a model "yes" is stronger evidence, not proof of grip, identity or contact.
- Simulator and blindfold results cannot stand in for blind users' skills, habits or outcomes.

## References and next participation (kept)

- [CMU PalmSight](https://publications.ri.cmu.edu/palmsight-an-assistive-technology-helping-the-blind-to-locate-and-grasp-objects): prior work on locating and grasping with non-visual feedback; Sightline does not claim to be first.
- [Apple detection mode guide](https://support.apple.com/guide/iphone/detect-text-read-loud-iph29dbe3fb6/27/ios/27): a reminder not to treat camera detection as reliable for navigation or high-risk use.
- Next: review wording, mounting and daily tasks with blind participants and orientation-and-mobility / occupational professionals; compare with their own methods (time, collisions, wrong pick-ups, fatigue, help needed).

## v8 bounded-confirmation details (obsolete)

One confirmation cycle per search: at most 3 SAM + 3 identity calls in 35 s; a 30 s observation window; ≥ 2 common physical fingertips; hand and object each moving ≥ 3 cm with ≤ 2.5 cm relative drift; supported objects rising ≥ 3 cm; one 4 cm horizontal movement captured on observed motion (4 s deadline), vetoed by overshoot > 7 cm, reverse > 1.5 cm, reach, view or obstacles. Missing evidence disabled Check and offered self-confirm, New search or Stop.

## 2026-10-31 setup-sheet fix (obsolete)

A device screenshot showed the forced setup sheet staying up after a successful measurement. v8 replaced it with an in-page overlay that closed automatically. v9 removes the setup screen: a long press measures from the main screen.
