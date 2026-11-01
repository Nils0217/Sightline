# labels: spike, needs-review
"""Scores spike/stt/results/*.jsonl against corpus.csv. Stdlib only.
Stop rules (what the app would hand on as "what the user said", and when):
- apple_app: SpeechInput.swift today: stop on a final result, 1.5 s after the text last changed
  (checked every 0.2 s), or 8 s after listening starts.
- muse_rt_first: Muse realtime ENDPOINTING, the first speechComplete.
- muse_rt_join: same, but a new speechStart within 1.0 s after a speechComplete joins the next turn.
- muse_rt_hybrid: the first speechComplete, or the latest partial once it has not changed for 1.5 s
  (Apple's rule): short commands ("Stop", "I'm thirsty") often never get a speechComplete.
- muse_rt_smart: like hybrid, but a partial that ends a sentence (. ? !) needs 0.8 s unchanged and
  one that does not ("Can you help me find") needs 3 s: Muse punctuates only finished sentences.
- muse_file: PUSH_TO_TALK upload after a local 1.5 s silence (as apple_app finds it), plus the upload time.
Times are from the clip start; the user starts speaking at 0.5 s.
Cut off = the rule stopped before the user finished. Key miss = a key word of the request is missing.
"""
import csv, json, re, statistics as st, sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
RES = HERE / "results"
corpus = {r["file"]: r for r in csv.DictReader(open(HERE / "corpus.csv"))}

NUM = {"fifty five": "55", "fifty-five": "55"}
def norm(s):
    s = s.lower().replace("’", "'")
    for a, b in NUM.items(): s = s.replace(a, b)
    s = re.sub(r"[^a-z0-9' ]", " ", s)
    s = s.replace("where's", "where is").replace("i'm", "i am").replace("it's", "it is")
    return s.split()

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r))

def keys_ok(keys, hyp):
    joined = "".join(norm(hyp))
    return all(k in joined for k in keys.split())

def apple_app(ev):
    parts = [e for e in ev if e["kind"] == "partial"]
    t, text, last = 0.0, "", None
    while t < 8.0:
        t = round(t + 0.2, 3)
        for p in parts:
            if p["t"] <= t:
                if p["text"] != text and p["text"]: text, last = p["text"], p["t"]
                if p["final"] and p["t"] <= t: return t, text
        if last is not None and t - last > 1.5: return t, text
    return t, text

def muse_events(row):
    off = row.get("stream_offset_s", 0)
    out = []
    for e in row["events"]:
        if e["kind"] == "msg":
            m = json.loads(e["raw"]); m["t"] = e["t"] - off; out.append(m)
    return out

def muse_first(ms):
    for m in ms:
        if m["type"] == "speechComplete": return m["t"], m.get("transcript", "")
    return None, ""

def muse_join(ms, gap=1.0):
    texts, stop = [], None
    for m in ms:
        if m["type"] == "speechComplete":
            texts.append(m.get("transcript", "")); stop = m["t"]
        elif m["type"] == "speechStart" and stop is not None and m["t"] - stop > gap:
            break
    return stop, " ".join(texts)

def muse_hybrid(ms, quiet=1.5, done_quiet=None):
    text, last = "", None
    ticks = sorted({round(m["t"], 2) for m in ms} | {round(x * 0.2, 1) for x in range(0, 60)})
    for t in ticks:
        for m in ms:
            if abs(round(m["t"], 2) - t) > 1e-9: continue
            if m["type"] == "speechComplete": return t, m.get("transcript", "") or text
            if m["type"] == "transcript" and m.get("transcript") and m["transcript"] != text:
                text, last = m["transcript"], t
        wait = done_quiet if done_quiet is not None and text.rstrip()[-1:] in ".?!" else quiet
        if last is not None and t - last > wait: return t, text
    return (None, text) if last is None else (last + quiet, text)  # (approximate past the last tick)

def load(name):
    p = RES / f"{name}.jsonl"
    return [json.loads(l) for l in open(p)] if p.exists() else []

results = []  # (rule, file, stop_t or None, text)
for r in load("apple"):
    results.append(("apple_app",) + (r["file"],) + apple_app(r["events"]))
for r in load("muse_rt"):
    ms = muse_events(r)
    results.append(("muse_rt_first", r["file"]) + muse_first(ms))
    results.append(("muse_rt_join", r["file"]) + muse_join(ms))
    results.append(("muse_rt_hybrid", r["file"]) + muse_hybrid(ms))
    results.append(("muse_rt_smart", r["file"]) + muse_hybrid(ms, quiet=3.0, done_quiet=0.8))
for r in load("muse_rt_keywords"):  # subset, room inventory names as keywords
    results.append(("muse_rt_smart_kw", r["file"]) + muse_hybrid(muse_events(r), quiet=3.0, done_quiet=0.8))
apple_stop = {f: t for rule, f, t, _ in results if rule == "apple_app"}
for r in load("muse_file"):
    c = corpus[r["file"]]
    text = r.get("body", {}).get("transcript", "") if isinstance(r.get("body"), dict) else ""
    vad = apple_stop.get(r["file"], float(c["speech_end_s"]) + 1.5)
    results.append(("muse_file", r["file"], vad + r.get("ms", 0) / 1000 if text or "ms" in r else None, text))

rows = []
for rule, f, stop, text in results:
    c = corpus[f]; end = float(c["speech_end_s"])
    rows.append(dict(rule=rule, file=f, cond=c["condition"], voice=c["voice"], id=c["id"], ref=c["text"], hyp=text,
                     stop=stop, after_end=None if stop is None else stop - end, start_to_ready=None if stop is None else stop - 0.5,
                     cut=stop is not None and stop < end - 0.05, empty=not norm(text), wer=wer(c["text"], text),
                     key=keys_ok(c["keys"], text)))

def summary(group):
    out = []
    keyf = lambda r: (r["rule"], r[group]) if group else (r["rule"],)
    g = defaultdict(list)
    for r in rows: g[keyf(r)].append(r)
    out.append(f"| rule | {group or 'all'} | n | key words right | WER | cut off | empty | median end→ready s | p90 end→ready s | median start→ready s |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for k in sorted(g):
        rs = g[k]; lat = sorted(r["after_end"] for r in rs if r["after_end"] is not None)
        s2r = [r["start_to_ready"] for r in rs if r["start_to_ready"] is not None]
        p90 = lat[int(0.9 * (len(lat) - 1))] if lat else float("nan")
        out.append(f"| {k[0]} | {k[1] if len(k) > 1 else ''} | {len(rs)} | {sum(r['key'] for r in rs)}/{len(rs)} | "
                   f"{st.mean(r['wer'] for r in rs):.2f} | {sum(r['cut'] for r in rs)} | {sum(r['empty'] for r in rs)} | "
                   f"{st.median(lat) if lat else float('nan'):.2f} | {p90:.2f} | {st.median(s2r) if s2r else float('nan'):.2f} |")
    return "\n".join(out)

md = ["# STT experiment results (generated by analyze.py)", "", summary(None), "", summary("cond"), "", summary("voice"), "",
      "## Misses (key word wrong, empty, or cut off)", "", "| rule | clip | heard | stop s | cut |", "|---|---|---|---|---|"]
for r in sorted(rows, key=lambda r: (r["rule"], r["file"])):
    if not r["key"] or r["empty"] or r["cut"]:
        md.append(f"| {r['rule']} | {r['file'][:-4]} | {r['hyp'] or '(nothing)'} | {r['stop'] if r['stop'] is None else round(r['stop'], 2)} | {'yes' if r['cut'] else ''} |")
(RES / "summary.md").write_text("\n".join(md) + "\n")
with open(RES / "scored.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
print("\n".join(md[:2 + 3 * 0]) ); print(summary(None)); print(); print(summary("cond")); print(); print(summary("voice"))
