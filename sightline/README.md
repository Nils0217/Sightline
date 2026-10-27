# Sightline

> Built from scratch during the **Meta Global AI Developer Hackathon (Oct 26 – Nov 4, 2026)**, Indie Developer track, theme *Build for Your World*.

Sightline is an indoor AI guide for blind and low-vision people. Say what you want, and Sightline finds it, then talks your hand to it: "move right 10 cm… a little higher… now grab."

## How it works

| Layer | Component | Rate | Job |
|---|---|---|---|
| Commander | **Muse Spark** (Meta Model API) | event-driven, ≤ 1 Hz | Parse the request, read live state via tool calling, decide the next step, rephrase guidance |
| Eyes | **SAM 3.1** (Meta Model API) | ~1 Hz | Find and segment the target by text prompt, re-confirm it is still there |
| Space | ARKit + LiDAR (on device) | 60 Hz | Baseline room map, depth, phone pose |
| Hand | Apple Vision hand pose (on device) | 30 Hz | 3D fingertip position |
| Voice | Local controller | real time | Hand-to-target vector → spoken micro-instructions + distance tones |

Cloud models understand and decide; the guidance loop runs entirely on the phone, so latency never reaches the user's hand.

## Status

Work in progress. See [docs/PRD.md](docs/PRD.md) for scope, milestones and risks.

## Safety

Indoor use only. Sightline does not replace a cane or guide dog, does not navigate walking routes, and gives no medical advice.
