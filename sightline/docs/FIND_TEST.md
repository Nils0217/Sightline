<!-- labels: important, testing, needs-review -->
# Find and grab — v1 device test

First end-to-end version of the core flow (PRD "Find and grab"). Goal of this run: does it work at all, and where does it break. Not the blindfold test yet.

## Flow
1. **Tap anywhere** on the screen (the whole screen is one button; VoiceOver reads it as "Speak a command").
2. Say a command: "find the cup", "where is my phone", "find the water bottle". Recognised **on the phone** (no audio upload).
3. The app says **"Looking for the cup."** at once, before any cloud call (G4 decision).
4. SAM 3.1 segments "cup" on the current frame → mask + LiDAR → world target (same code as G2). Green dot = target.
5. It says where it is: "Found the cup, about 40 centimetres ahead, slightly right. Reach out slowly."
6. ~30 Hz loop: fingertip (G1 pipeline, red dot) → offset in the body frame → one short cue at a time ("Left, 10 centimetres.", "A little higher.", "Forward, 20 centimetres.") plus beeps that get faster and higher as the finger gets closer (silent beyond 60 cm).
7. Fingertip within 4 cm of the target for 0.3 s → **"Now grab."** Done.
- Tap again while guiding = "Stopped." Saying "stop" works too.
- If tracking drops and recovers, SAM is called once more to re-lock. Max 5 SAM calls per search.
- The noun comes from your words, so the fast path never waits on Muse Spark.
- **Muse Spark as commander** (tool calling: `get_state`, `find_object`, `select_target`, `say`, `ask_user`, `stop`) steps in only when:
  - the command is not a simple "find X" (e.g. "I'm thirsty, is there anything to drink?") → effort `minimal`, says "One moment." first;
  - SAM finds several matches with similar confidence → says "I see more than one cup. Checking.", effort `medium` with the photo; it may ask you "The left one or the right one?" and listens for the answer.

## Body frame
Directions assume the phone faces forward from the chest: "right" is your right, "higher" is towards the ceiling, "forward" is away from your body, level with the floor. For this first test, hold the phone in your **left hand against your chest**, screen facing you, camera facing the table, and reach with your **right hand**.

## Output files (app Documents)
- `find_log_<time>.csv` — **one file per app launch**, rewritten after every event and always containing every search of that launch (cumulative). Export **once, at the end** with **Log CSV**.
- `api_calls.csv` — shared by all launches, appended forever (also gets the G2 calls).
- `g2/` is not used by Find.

Log columns: `timestamp, session, elapsed_s, event, target, detail, hand_to_target_cm, sam_calls, tracking_state`. Events: `command`, `command_agent`, `sam_lock`, `sam_lock_fail`, `target`, `sam_relock`, `cue`, `grab`, `stop`, `agent_tool`, `agent_answer`, `agent_text`, `agent_stop`, `agent_error`.

## How to run
0. On the Mac first (1 minute, a few cents): `.venv/bin/python spike/agent_spike.py` with the key exported. It runs the same tool-calling requests with fake tools and prints each call, so request-shape problems show up here instead of on the phone. Paste me the output.
1. Xcode → Run. The app opens on **Find** (tabs at the top: Find / G1 / G2 / G3). Allow **microphone** and **speech recognition** the first time. You should hear "Sightline ready…".
2. Put a cup (or bottle) on a table, 40–60 cm in front of you, with some other things around it.
3. Hold the phone as described above. Move it slowly for 2–3 s so tracking is normal.
4. Tap the screen, say "find the cup". Listen.
5. Follow the voice with your right index finger until "Now grab". Try it with eyes open first, then once with eyes closed.
6. Repeat with 3–5 different objects/positions. Each search costs at most 5 × $0.0025 for SAM.
7. Commander checks: say "I'm thirsty, is there anything to drink?" with a bottle on the table; then put **two cups** side by side and say "find the cup" — it should ask which one; answer "the left one".
8. Tap **Log CSV** and save it. Tell me: what it said that was wrong or confusing, whether the direction words matched your body, and whether the beeps helped.
