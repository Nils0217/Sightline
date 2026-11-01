<!-- labels: reference, needs-review -->
# Speech to text: Apple on-device vs Muse Voice Transcribe (2026-11-01)

Nils asked: should listening move to Muse Voice Transcribe? Measure, on past test situations: start-to-end time, cut-off or garbled speech, clear content, voice quality, anything else that matters.

## What was run
- **Lines.** 23 lines. 12 are what users really said in device tests (find logs V6, v7, V9.1.3) and 1 is the V5 phrase that was never transcribed ("The green key"). The other 10 are which-one, hand-help, "Is this it?" and "Stop" replies.
- **Voices.** Each line is spoken by 4 macOS voices: Samantha (US), Daniel (GB), Rishi (IN), and Meijia (a zh-TW voice reading English).
- **Conditions.** clean; room noise at SNR 10 dB; a 2 s pause mid-sentence (lines of 3+ words); quiet (−18 dB). That makes **304 clips**, 11.6 min of speech.
- **Streaming.** Every clip is streamed at real-time pace, like a microphone, with 3 s of silence after it (`spike/stt/stt_bench.swift`).
- **Engines.**
  - Apple on-device: the same request settings as `SpeechInput.swift`.
  - Muse realtime: ENDPOINTING over a websocket, 24 kHz PCM.
  - Muse file: PUSH_TO_TALK.
- **Scoring.** `spike/stt/analyze.py` applies each stop rule to the recorded events. The full tables are in `spike/stt/results/summary.md`.
- **Cost.** 801 Muse calls, $0.20 in total ($0.18 per audio hour), all logged in `logs/api_calls.csv`.
- **Limits.**
  - Synthetic voices are cleaner than people, so these numbers rank the engines; they do not predict real accuracy.
  - Apple ran on the Mac, not on the iPhone.
  - Muse latency includes the network from this Mac.
  - The first Apple run (4 clips in parallel) said "No speech detected" for 205 of 304 clips. It was redone one clip at a time; the parallel run is kept as `apple_parallel_invalid.jsonl`.

## Results (304 clips)
Times are in seconds. "End→ready" runs from the moment the user stops speaking until the app has the text. "Start→ready" runs from the moment the user starts speaking.

| Way of listening | Key word right | Cut off mid-sentence | Empty | End→ready (median / p90) | Start→ready (median) |
|---|---|---|---|---|---|
| **Apple, app today** (stops 1.5 s after the text last changed) | 250 (82 %) | **28 of 28 pauses** | 0 | 2.11 / 2.36 | 3.30 |
| Muse realtime, first end-of-turn only | 260 (86 %) | 2 | **29** (short lines get no end-of-turn) | 0.50 / 3.16 | 2.26 |
| **Muse realtime, "smart" stop** (see below) | **283 (93 %)** | 7 | 0 | **0.52 / 1.47** | **2.23** |
| Muse realtime, smart stop + room names as keywords* | 124 / 132 vs 114 / 132 without | | | | |
| Muse file (upload after Apple's silence rule) | 291 (96 %) | 5 | 0 | 3.21 / 3.60 | 4.44 |

\* This row was run on 132 clips of the 10 most error-prone lines. The keywords were the 52 names from the saved room inventory.

The **"smart" stop** works like this:
- Stop when Muse sends end-of-turn.
- Otherwise, stop when the partial text ends a sentence (`.`, `?` or `!`) and has not changed for 0.8 s.
- Otherwise, stop after 3 s with no change.

This works because Muse punctuates only finished sentences. During a pause, "Can you help me find" has no full stop.

### By condition (key word right / cut off)

| | clean (92) | noise (92) | 2 s pause (28) | quiet (92) |
|---|---|---|---|---|
| Apple, app today | 87 / 0 | 77 / 0 | **0 / 28** | 86 / 0 |
| Muse realtime, smart stop | 91 / 0 | 82 / 0 | 21 / 7 | 89 / 0 |

### Cut off or garbled
- **Apple cuts off every mid-sentence pause.** With 1.5 s of silence, "Can you help me find… my book" became "Can you help me find". The same happened to all 28 pause clips. A real user who pauses to think is cut off.
- **Muse waits through the pause.** It holds the turn open and ends right after "…my book?" (about 0.3 s after the last word). Its 7 cut-offs in pause clips are sentences that are complete on their own, such as "The red one." and "I have it."
- **The same confusions happen in both engines.** In noise, "mug" was heard as "mom", "mum", "mob" or "mud", and "key" as "tea". "Lamp" became "lamb" and "scan" became "spin". Apple also heard "Oh my phone" as "Oh my soul" and "Is this my mug?" as "Please please my mom" (Meijia voice).
- **Room names as Muse keywords fixed most key-word misses:** 10 more of the 132 clips were right. "Mug" in noise is still the weak spot.
- **Muse file mode repeats words** in 35 of 304 transcripts ("GotGot it", "Is this this it?"). Realtime did not.
- **Mixed-in Chinese.** With the zh-TW voice, Muse wrote "55" as 五十五 3 times. Fix: `languageBias: ["English"]`.
- **Muse realtime has no end-of-turn for short lines.** "Stop" and "I'm thirsty" got correct partial text but no end-of-turn even after 3 s of silence (29 clips). The smart stop is needed.

### Other things that matter
- **Connection.** The Muse handshake takes 0.46 s (median), 0.60 s at p90. Open the socket while the "listening" earcon plays.
- **Network.** Muse needs the network. Apple keeps working offline and stays the fallback.
- **Cost.** An open mic for a whole 1-minute search is about $0.003.
- **Echo.** A mic left open while the app speaks needs echo cancellation (`setVoiceProcessingEnabled` on the input node). Without it, the app hears its own lines. This was not tested here.
- **The Meta-model rule.** Muse Voice Transcribe is a Meta model. Apple speech counts as OS voice, which is allowed but must be labelled in the README.

## The app's own voice (output)
- **Round trip.** I spoke 34 app lines with Samantha at 165 words per minute, clean and in noise at SNR 5 dB, and transcribed them with Muse. All words came back in all 68 clips. The only differences were "8" vs "eight", "centimetres" vs "centimeters" and file-mode repeats. The voice is clear even in noise.
- **Speaking rate on the device:** 2.5–2.9 words/s (V5–V9.1.3 logs).
- **Lines cut by a newer line on the device:** V5 23 / 247 (9 %), V6 20 / 104 (19 %), v7 4 / 51 (8 %), V9.1.3 11 / 118 (9 %). These are mostly directions replaced by fresher ones, which is intended. But "Looking for the sanitizer." was cut twice.
- **Unclear lines in V9.1.3** (the user cannot tell what to do):
  - "Something is ahead. Go around it on your left." doesn't say what; since v9.2 the look-around names it.
  - "A roll is ahead." (a toilet paper roll).
  - "A guess: Check lower left on the wooden bed frame beside you."
  - Spark's which-one questions run 25–30 words ("…The closer one is bigger; on the right side of the table near you. I'm not sure of the cover. Do you want me to guide you to that one?").
  - "Your key was last seen behind you; half a turn to your left; about 90 centimetres away. I don't see the key here. Turn slowly." (22 words, two directions).

## Recommendation
Switch listening to **Muse realtime with the smart stop, room names as keywords and `languageBias: ["English"]`**, and keep Apple as the offline fallback. On these clips it is:
- 4× faster from the end of speech to the text (0.5 s vs 2.1 s);
- never cuts a mid-sentence pause (0 vs 28 of 28);
- more often right on the key word (93 % vs 82 %).

The same open stream can carry the spoken "Is this it?" during guidance, with echo cancellation. Before switching, Nils should record about 20 of his own phrases on the iPhone and repeat the comparison. Real voice, accent and room are the open question.
