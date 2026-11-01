# labels: spike, needs-review
"""Round trip of the app's own spoken lines (2026-11-01): each line the app spoke in the
V9.1.3 device test, plus the v9.2 lines, is spoken by Samantha (the en-US system voice the
app uses) at ~165 words/min (the device logs measured 2.5-2.9 words/s), clean and with room
noise at SNR 5 dB, then transcribed. A line a recogniser cannot get back is a line a person
may mishear too; this is a proxy, not a listening test. Writes spike/stt/tts/ and tts.csv
in the corpus.csv format. Stdlib only."""
import csv, wave, array
from pathlib import Path
import make_corpus as mc  # reuses say/read/write/room_noise

HERE = Path(__file__).resolve().parent
OUT = HERE / "tts"
LINES = [
    "Hold your hand out.", "Checking.", "Forward, 8 centimetres.", "Down, 8 centimetres.", "Right, 8 centimetres.",
    "Left, 8 centimetres.", "Turn left slowly. I haven't looked there yet.", "I see your hand.",
    "Keep turning right, slowly.", "One moment.", "Point the phone lower, toward the floor, and turn slowly.",
    "I can't see your hand.", "Not sure. Double tap if you have it.", "I don't see the sanitizer here. Turn slowly.",
    "Keep going forward.", "Stop.", "Point the phone a little lower.", "Found the book. Ahead, a little right, 40 centimetres.",
    "A book is ahead. Go around it on your right.", "Okay. You have the book.", "Stop. The phone is at your fingers.",
    "Got it. You have the hand spray.", "Turn right, about a quarter turn, toward where I last saw it.",
    "Stop. The mug is at your fingers. Feel for the side.", "Keep going down.", "A little forward.",
    "Stop. A knife is in the way.", "Careful. A bottle is on your left.", "It's right below your hand.",
    "I need to see your hand to guide you.", "I'm not sure this is the mug.", "I couldn't check for danger. Go slowly.",
    "The X is still there.".replace("X", "mug"), "Lift your hand over it.",
]

def main():
    OUT.mkdir(exist_ok=True)
    rows = []
    sil = lambda s: [0] * int(mc.RATE * s)
    for i, text in enumerate(LINES):
        tmp = OUT / "_tmp.wav"
        import subprocess
        subprocess.run(["say", "-v", "Samantha", "-r", "165", "-o", str(tmp), f"--data-format=LEI16@{mc.RATE}", text], check=True)
        body = list(mc.read(tmp)); tmp.unlink()
        for cond in ["clean", "noise5"]:
            clip = sil(0.5) + body + sil(1.0)
            if cond == "noise5":
                nz = mc.room_noise(len(clip), i)
                k = mc.rms(body) / (mc.rms(nz) * 10 ** (5 / 20))
                clip = [max(-32768, min(32767, int(x + y * k))) for x, y in zip(clip, nz)]
            name = f"line{i:02d}__{cond}.wav"
            mc.write(OUT / name, clip)
            words = [w.strip(".,").lower() for w in text.split() if len(w.strip(".,")) > 3]
            rows.append(dict(file=name, id=f"line{i:02d}", text=text, keys=" ".join(words[:3]) or text.strip(".").lower(),
                             source="app line", voice="Samantha", accent="US", condition=cond,
                             speech_end_s=round(0.5 + len(body) / mc.RATE, 3), clip_s=round(len(clip) / mc.RATE, 3)))
    with open(HERE / "tts.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    print(len(rows), "clips")

main()
