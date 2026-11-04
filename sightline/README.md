<!-- labels: important -->
# Sightline

> Built from scratch during the **Meta Global AI Developer Hackathon (Oct 26 – Nov 4, 2026)**, Indie Developer track, theme *Build for Your World*. Nothing existed before 2026-10-26: the first commit is from that evening, and every line of code, test and doc in this repo was written during the event.

Sightline is an indoor find-and-grab aid for blind and low-vision people. Say what you want; Sightline finds it with the chest-mounted iPhone and talks your hand to it ("Right, 20 centimetres." "Stop. The bottle is at your fingers."), then checks that you picked up the right thing.

**Demo video:** https://youtube.com/shorts/6mhpoczOCzY · Architecture diagram: [`docs/media/flow.png`](docs/media/flow.png)

## How to use it

1. Secure the iPhone on your chest. The first time, hold your hand out comfortably and **press and hold** the screen: Sightline measures your reach and hand size and remembers them; distance thresholds scale to your body.
2. Optional: say "Scan the room" and turn slowly; tap when done. Sightline remembers what is where (with how each thing looks) for later searches.
3. **Tap** and say what you want. If several saved things fit ("water bottle"), Sightline asks which one, describing each. It says where the target is and asks you to hold your hand out.
4. Follow the short directions. "Stop. Something's in the way." stops your hand. Targets are within hand reach.
5. Pick it up. Touching the object and then lifting it starts a check: "Got it. You have the bottle.", "The bottle is still there.", or "Not sure. Double tap if you have it."
6. **Double tap** always means "I have it". **Tap** during a task stops it.

VoiceOver: double tap = "I have it", two-finger double tap = start / stop, plus Stop, Status, I have it and Measure reach in the actions rotor.

## How it works

| Layer | Component | Kind | Runs where | Job |
|---|---|---|---|---|
| Commander | **Muse Spark** (`muse-spark-1.3`) | Meta model | Meta Model API (cloud) | Understand the request, talk with the user, pick the target in the photo, list a room, check the held object |
| Eyes | **SAM 3.1** (`sam-3.1`) | Meta model | Meta Model API (cloud) | Segment the target by text prompt; find it again on each hold check |
| Ears | **Muse Voice Transcribe** (`muse-voice-transcribe-1.0`) | Meta model | Meta Model API (cloud, realtime stream) | What the user said and when they finished |
| Ears, fallback | Apple Speech (`SFSpeechRecognizer`) | iOS built-in, on device | iPhone | Used only when the Muse stream fails to connect |
| Space | ARKit + LiDAR | iOS built-in, on device | iPhone, 60 Hz | Phone pose, object surface, obstacles on the next move |
| Hand | Apple Vision hand pose | iOS built-in, on device | iPhone, 30 Hz | One fingertip in 3D |
| Voice | `AVSpeechSynthesizer` + tones | iOS built-in, on device | iPhone | Short spoken directions and distance beeps (no AI voice model) |

Cloud models understand and decide; the guidance loop runs on the phone and never waits on the network. Every Meta Model API call is logged (`api_calls.csv`: label, model, latency, tokens), and every search writes a `find_log_*.csv` of what the app saw and said.

## Run it

Needs a Mac with Xcode 16+, an iPhone with LiDAR (Pro models, iOS 17+), and your own Meta Model API key. No key is in this repo.

1. `cp .env.example .env` and put your key in `META_MODEL_API_KEY`.
2. `tools/ios_secrets.sh` copies the key into `Sightline/Sightline/Secrets.plist` (gitignored).
3. Open `Sightline/Sightline.xcodeproj`, choose your own signing team, and run the `Sightline` scheme on the iPhone.

The app does not work in the iOS Simulator (it needs the camera and LiDAR).

## Tests, simulation and provenance

- Unit tests: `swift test --package-path Packages/SightlineCore` (one test per recorded device failure where the rule is testable).
- Simulator: `swift run -c release --package-path Packages/SightlineCore SightlineSim`. **Simulated:** synthetic users and sensing, no model calls; it checks the guidance rules, not real-world safety.
- All checks at once: `sh tools/regress.sh`; with a device log, `tools/check_log.py` screens it for every failure recorded so far.
- [Test log](docs/TEST_LOG.md) (device runs, what went wrong, what changed) · [Device test steps](docs/FIND_TEST.md) · [PRD](docs/PRD.md) · [Agent rules](AGENTS.md)

Nothing in the app is cached or stubbed: every search calls the live models.

## Status

Research prototype. Tested on the iPhone by the developer across the runs in the test log; not yet tested with blind users.

## Safety and related work

Indoor, within arm's reach, body still. Sightline does not replace a cane or guide dog, does not navigate walking routes, and gives no medical advice. Transparent, reflective, thin or hidden objects and depth errors can be missed; the obstacle check is conservative, not a guarantee. Related work includes [PalmSight](https://publications.ri.cmu.edu/palmsight-an-assistive-technology-helping-the-blind-to-locate-and-grasp-objects), NaviSense and AIGuide (see the PRD); Sightline does not claim to be the first hand-guidance aid.
