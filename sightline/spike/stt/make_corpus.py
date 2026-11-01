# labels: spike, needs-review
"""Speech-to-text experiment corpus (2026-11-01): what users said in past device tests
(find logs V6, v7, V9.1.3), plus which-one, hand-help and "is this it?" replies.
Each line is spoken by macOS voices (accents incl. a Mandarin voice reading English) in
4 conditions: clean, room noise (SNR 10 dB), a 2 s pause mid-sentence, quiet (-18 dB).
Writes 24 kHz mono 16-bit WAVs with 0.5 s lead-in and 3 s trailing silence (the mic keeps
running) to spike/stt/corpus/ and corpus.csv. Synthetic voices are cleaner than people:
this ranks engines, it does not predict real accuracy. Stdlib only."""
import csv, random, subprocess, wave, array, math
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "corpus"
RATE = 24000

# (id, text, key words that must be heard, source, pause split index in words or 0)
LINES = [
    ("cmd_phone", "I want my phone", "phone", "V6 log", 0),
    ("cmd_thirsty", "I'm thirsty", "thirsty", "V6 log", 0),
    ("cmd_green", "The green liquid", "green liquid", "V6 log", 0),
    ("cmd_key", "Where is my key", "key", "V6/V9.1.3 log", 0),
    ("cmd_book", "Can you help me find my book", "book", "v7 log", 5),
    ("cmd_ohphone", "Oh my phone", "phone", "v7 log", 0),
    ("cmd_sanitizer", "Can you help me find my sanitizer", "sanitizer", "V9.1.3 log", 5),
    ("cmd_spray", "Can you find a hand spray for me", "hand spray", "V9.1.3 log", 3),
    ("cmd_scan", "Scan the room", "scan room", "V9.1.3 log", 0),
    ("cmd_hairdryer", "Do you know where is my hairdryer", "hairdryer", "V9.1.3 log", 4),
    ("cmd_remember", "You said you remember 55 things in my room, what did you remember", "remember room", "V9.1.3 log", 7),
    ("cmd_mug", "Where's my mug", "mug", "V9.1.3 log", 0),
    ("cmd_greenkey", "The green key", "green key", "V5 (never transcribed)", 0),
    ("which_closest", "The closest one", "closest", "which-one reply", 0),
    ("which_right", "The one on the right", "right", "which-one reply", 0),
    ("which_red", "The red one, next to the lamp", "red lamp", "which-one reply", 3),
    ("hand_under", "My hand is under the table", "hand under table", "hand-help reply", 0),
    ("hand_holding", "I'm holding it now", "holding", "hand-help reply", 0),
    ("check_isthisit", "Is this it?", "this it", "case 2: not sure", 0),
    ("check_mug", "Is this my mug?", "this mug", "case 2: not sure", 0),
    ("check_rightone", "Is it the right one?", "right one", "case 2: not sure", 0),
    ("check_havekey", "I have it, is it my key?", "have key", "case 2: not sure", 3),
    ("stop", "Stop", "stop", "control", 0),
]
VOICES = [("Samantha", "US"), ("Daniel", "GB"), ("Rishi", "IN"), ("Meijia", "zh-TW reading English")]
CONDITIONS = ["clean", "noise", "pause", "quiet"]

def read(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        return array.array("h", w.readframes(w.getnframes()))

def write(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(array.array("h", samples).tobytes())

def say(voice, text, path):
    subprocess.run(["say", "-v", voice, "-o", str(path), f"--data-format=LEI16@{RATE}", text], check=True)
    return read(path)

def rms(s):
    return math.sqrt(sum(x * x for x in s) / max(1, len(s)))

def room_noise(n, seed):
    # Brown-ish noise (fan / room hum) plus a little white hiss.
    rnd = random.Random(seed); out = []; b = 0.0
    for _ in range(n):
        b = 0.98 * b + rnd.uniform(-1, 1); out.append(b * 0.3 + rnd.uniform(-1, 1) * 0.2)
    return out

def main():
    OUT.mkdir(exist_ok=True)
    rows = []
    sil = lambda s: [0] * int(RATE * s)
    for lid, text, keys, source, split in LINES:
        for voice, accent in VOICES:
            tmp = OUT / "_tmp.wav"
            speech = list(say(voice, text, tmp))
            if split:
                words = text.split()
                a = list(say(voice, " ".join(words[:split]), tmp)); b = list(say(voice, " ".join(words[split:]), tmp))
            for cond in CONDITIONS:
                if cond == "pause" and not split: continue
                body = a + sil(2.0) + b if cond == "pause" else speech
                clip = sil(0.5) + body + sil(3.0)
                if cond == "noise":
                    nz = room_noise(len(clip), hash((lid, voice)) & 0xffff)
                    k = rms(body) / (rms(nz) * 10 ** (10 / 20))
                    clip = [x + y * k for x, y in zip(clip, nz)]
                if cond == "quiet":
                    clip = [x * 10 ** (-18 / 20) for x in clip]
                clip = [max(-32768, min(32767, int(x))) for x in clip]
                name = f"{lid}__{voice}__{cond}.wav"
                write(OUT / name, clip)
                rows.append(dict(file=name, id=lid, text=text, keys=keys, source=source, voice=voice,
                                 accent=accent, condition=cond, speech_end_s=round(0.5 + len(body) / RATE, 3),
                                 clip_s=round(len(clip) / RATE, 3)))
            tmp.unlink()
    with open(HERE / "corpus.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    print(len(rows), "clips,", round(sum(r["speech_end_s"] for r in rows) / 60, 1), "min of speech,",
          round(sum(r["clip_s"] for r in rows) / 60, 1), "min with silence")

if __name__ == "__main__":
    main()
