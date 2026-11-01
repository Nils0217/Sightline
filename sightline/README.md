<!-- labels: important -->
# Sightline

> Built from scratch during the **Meta Global AI Developer Hackathon (Oct 26 – Nov 4, 2026)**, Indie Developer track, theme *Build for Your World*.

Sightline is an indoor find-and-grab aid for blind and low-vision people. Say what you want; Sightline finds it with the chest-mounted iPhone and talks your hand to it ("Right, 20 centimetres." "Stop. The book is at your fingers."), then checks that you picked up the right thing.

## How to use it (v9)

1. Secure the iPhone on your chest. The first time, hold your hand out comfortably and **press and hold** the screen: Sightline measures your reach and hand size and remembers them; distance thresholds scale to your body.
2. **Tap** and say what to find. Sightline says where it is ("Found the book. Ahead, a little right, 50 centimetres.") and asks you to hold your hand out.
3. Follow the short directions. "Stop. Something's in the way." stops your hand. Far objects are guided too.
4. Pick it up. Touching the object and then lifting or taking it away starts a check at once (a hand moved without touching it does not): "Got it. You have the book.", "The book is still there.", or "Not sure. Double tap if you have it."
5. **Double tap** always means "I have it": if the check cannot tell, your word is taken. **Tap** during a task stops it. "Scan the room" maps the room; tap when done.

VoiceOver: double tap = "I have it", two-finger double tap = start / stop, plus Stop, Status, I have it and Measure reach in the actions rotor.

## How it works

| Layer | Component | Rate | Job |
|---|---|---|---|
| Commander | **Muse Spark** (Meta Model API) | event-driven | Understand the request, choose between candidates, check the held object |
| Eyes | **SAM 3.1** (Meta Model API) | event-triggered | Find and segment the target by text prompt; locate it again on each hold check |
| Space | ARKit + LiDAR (on device) | 60 Hz | Phone pose, object surface, obstacles on the next move |
| Hand | Apple Vision hand pose (on device) | 30 Hz | One real fingertip in 3D |
| Voice | Local controller | real time | Short spoken directions + distance tones |

Cloud models understand and decide; the guidance loop runs on the phone and never waits on the network.

## Tests and docs

- Unit tests: `swift test --package-path Packages/SightlineCore`
- Simulator (synthetic users and sensing, not proof of real-world safety): `swift run -c release --package-path Packages/SightlineCore SightlineSim`
- [PRD](docs/PRD.md) · [Device test steps](docs/FIND_TEST.md) · [Test log](docs/TEST_LOG.md) · [Task list](docs/SPIKE.md)

## Status

Research prototype. v9 (2026-10-31) has passed unit tests, the simulator and an iOS build; it has not yet been tested on the iPhone or with blind users.

## Safety and related work

Indoor, within arm's reach, body still. Sightline does not replace a cane or guide dog, does not navigate walking routes, and gives no medical advice. Transparent, reflective, thin or hidden objects and depth errors can be missed; the obstacle check is conservative, not a guarantee. Related work includes [PalmSight](https://publications.ri.cmu.edu/palmsight-an-assistive-technology-helping-the-blind-to-locate-and-grasp-objects), NaviSense and AIGuide (see the PRD); Sightline does not claim to be the first hand-guidance aid.
