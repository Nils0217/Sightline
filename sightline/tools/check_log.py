# labels: testing, needs-review
"""Screen a device find log for failures already recorded in docs/TEST_LOG.md.

Nils, 2026-11-03: "I don't want to keep facing an issue that was captured in the log." Each check below is one
recorded failure; a hit means it happened again on the device (or the run needs a look). Standard library only.

    python3 tools/check_log.py logs/v9.4/device/t20/find_log_1793773192.csv [api_calls.csv]

Reads only; prints one line per hit and a summary. Exit code 1 when anything was found.
"""

import csv
import re
import sys


def rows(path):
    with open(path, newline="") as f:
        out = []
        for r in csv.DictReader(f):
            try:
                r["t"] = float(r.get("elapsed_s") or "nan")
            except ValueError:
                r["t"] = float("nan")
            try:
                r["cm"] = float(r.get("hand_to_target_cm") or "nan")
            except ValueError:
                r["cm"] = float("nan")
            out.append(r)
        return out


def check(log, api):
    hits = []

    def hit(tag, r, text):
        hits.append((tag, r.get("timestamp", "")[11:19], r.get("session", ""), text))

    for i, r in enumerate(log):
        e, d = r.get("event", ""), r.get("detail", "")
        before = log[max(0, i - 40):i]
        same = [b for b in before if b.get("session") == r.get("session")]

        # T19: the room was saved empty while a view was failing or still being listed.
        if e == "map_finish" and re.search(r"\b0 items", d):
            hit("T19", r, "room saved with 0 items: " + d)

        # T20: a stall check with the hand far from the object and no "in the way" line just before.
        if e == "hold_check" and d == "stalled":
            far = [b for b in same if b["cm"] == b["cm"]][-1:]
            said = any("in the way" in b.get("detail", "") for b in same if r["t"] - b["t"] <= 15)
            if far and far[0]["cm"] > 12 and not said:
                hit("T20", r, "stall check %.0f cm from the object, never told what is in the way" % far[0]["cm"])

        # T17: Spark said no and the scan restarted although the same photo had more candidates.
        if e == "verify" and d.endswith("-> no"):
            found = [b for b in same if b.get("event") in ("sam_lock", "scan_found")][-1:]
            n = int(re.match(r"(\d+)", found[0]["detail"]).group(1)) if found and re.match(r"\d+", found[0]["detail"]) else 0
            nxt = log[i + 1:i + 3]
            if n >= 2 and any(x.get("event") == "scan_start" for x in nxt):
                hit("T17", r, "rejected one of %d candidates and scanned on without checking the others" % n)

        # T18 row 3: the target has no shape (Spark's point, no outline): hold checks will be unsure.
        if e == "object" and "no model" in d:
            hit("T18.3", r, "target without a shape: " + d)

        # T18 row 2: a Spark pick failed (timeout or no answer).
        if e == "api_error":
            hit("T18.2", r, "API error: " + d)

        # T16 row 2: a saved spot was called empty; look at the photo for something in front of it.
        if e == "room_map_forgot":
            hit("T16.2", r, "forgot a saved spot (check the photo for an occluder): " + d)

        # T18 row 4 / T16: give-up while Spark's after-give-up guess then saw it.
        if e == "spark_suggest" and any(b.get("event") == "scan_give_up" for b in same[-3:]):
            hit("T18.4", r, "gave up, then the guess says where it is: " + d)

        # T15 row 2: hand guidance to something out of reach (out of scope for the hackathon).
        m = re.search(r"Found the .*?(\d+) centimetres", d) if e == "say" else None
        if m and int(m.group(1)) > 100:
            hit("T15.2", r, "target %s cm away: out of hand reach" % m.group(1))

        # T18 row 2 / T16: a whole sentence used as the object's name.
        m = re.search(r"I don't see the (.+?) here", d) if e == "say" else None
        if m and len(m.group(1).split()) > 3:
            hit("T18.2", r, "a sentence as the name: " + m.group(1))

        # T18 row 11: the describe limit hit in a search that made fewer than 2 descriptions (count carried over).
        if e in ("check_skipped", "describe_skipped"):
            made = sum(1 for b in log[:i] if b.get("session") == r.get("session") and b.get("event") == "describe_held")
            if made < 2:
                hit("T18.11", r, "describe limit hit after %d description(s) in this search" % made)

        # T21: the room hint sent the user to a saved thing more than 60 cm away (out of reach) while another saved
        # entry with the name was nearer (the app now picks the nearer one; a hit means it did not).
        m = re.search(r"Your .+? was last seen .*?about (\d+(?:\.\d+)?) (centimetres|metres?) away", d) if e == "say" else None
        if m:
            cm = float(m.group(1)) * (1 if m.group(2).startswith("centi") else 100)
            chosen = any(b.get("event") == "which_saved_choice" for b in same)
            if cm > 60 and not chosen:
                hit("T21", r, "room hint to a thing %.0f cm away: check for a nearer one with the name" % cm)

        # T21 row 2: the which-one question about saved things got no clear answer; the nearer one was taken.
        if e == "which_saved_choice" and d.endswith("(no answer)"):
            hit("T21.2", r, "no clear answer to which saved one; took " + d)

        # T22: the output went to the earpiece while a line was being said (route change after a listen).
        if e == "audio_route" and "Receiver" in d:
            talking = [b for b in same if b.get("event") == "speech_start" and r["t"] - b["t"] <= 1.5]
            if talking:
                hit("T22", r, "voice moved to the earpiece during: " + talking[-1]["detail"][:60])

        # T22: "my" in a spoken name ("Your my phone was last seen").
        if e == "say" and re.search(r"\b(Your|The|the) my\b", d):
            hit("T22", r, "'my' in the name: " + d[:60])

        # T23: Spark's pick said "not in view" and SAM's crop at the saved spot then found it (the pick was waited for).
        if e == "sam_map_crop" and "found at the map spot" in d:
            prev = [b for b in same if b.get("event") == "spark_pick" and r["t"] - b["t"] <= 3]
            if prev and prev[-1]["detail"].endswith("not in view"):
                hit("T23", r, "Spark said not in view, the saved spot had it (the pick, 5-9 s, was waited for)")

        # T24: the agent kept going after Spark had picked the target (142 s to the lock).
        if e == "agent_tool" and not d.startswith("select_target"):
            picked = [b for b in same if b.get("event") == "spark_pick" and not b["detail"].endswith("not in view")]
            locked = any(b.get("event") == "target" for b in same)
            if picked and not locked:
                hit("T24", r, "agent turn after Spark picked it: " + d[:60])

        # T24: the phone is slow (frames processed under 5 per second or over 100 ms each) or hot.
        if e == "perf":
            m = re.match(r"([\d.]+) fps, (\d+) ms mean", d)
            if m and (float(m.group(1)) < 5 or int(m.group(2)) > 100):
                hit("T24", r, "slow frames: " + d)
        if e == "thermal" and "bursts off" in d:
            hit("T24", r, "phone hot: " + d)

        # T25: like things in view and Spark's choice taken before the user was asked which one.
        if e == "which_one" and re.search(r"-> (A|\d+)$", d):
            asked = any(b.get("event") in ("which_heard", "which_saved_choice") for b in same)
            refused = any(x.get("event") == "which_one" and "chose before asking" in x.get("detail", "") for x in log[i + 1:i + 2])
            if not asked and not refused:
                hit("T25", r, "chose which one without asking: " + d[:60])

        # sim "loop": the same line 3+ times in 10 s.
        if e == "say":
            again = [b for b in same if b.get("event") == "say" and b.get("detail") == d and r["t"] - b["t"] <= 10]
            if len(again) == 2:
                hit("loop", r, "said 3 times in 10 s: " + d)

    # sim "silent": more than 12 s without a line while guiding (between "I see your hand." and the end).
    guiding, last = {}, {}
    for r in log:
        s = r.get("session")
        if r.get("event") == "say" and r.get("detail", "").startswith("I see your hand"):
            guiding[s] = True
        if r.get("event") in ("hold_yes", "stop", "scan_give_up"):
            guiding[s] = False
        if r.get("event") == "say":
            if guiding.get(s) and s in last and r["t"] - last[s] > 12:
                hit("silent", r, "%.0f s without a line while guiding" % (r["t"] - last[s]))
            last[s] = r["t"]

    for a in api:
        label, ms = a.get("image", ""), float(a.get("latency_ms") or 0)
        # T19: a call that failed (timeout) and, before the fix, left no row.
        if label.endswith("_failed"):
            hits.append(("T19", a.get("timestamp", "")[11:19], "", "failed call %s after %.1f s" % (label, ms / 1000)))
        # T18 row 6 / T19: slow Spark calls (picks over 15 s, room views over 30 s).
        if label.startswith("pick_") and "_sam" not in label and ms > 15000:
            hits.append(("slow", a.get("timestamp", "")[11:19], "", "pick %s took %.1f s" % (label, ms / 1000)))
        if label.startswith("room_") and ms > 30000:
            hits.append(("slow", a.get("timestamp", "")[11:19], "", "room view %s took %.1f s" % (label, ms / 1000)))
    return hits


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    log = rows(sys.argv[1])
    api = []
    if len(sys.argv) > 2:
        with open(sys.argv[2], newline="") as f:
            first = log[0]["timestamp"][:10] if log else ""
            api = [a for a in csv.DictReader(f) if a.get("timestamp", "").startswith(first)]
    hits = check(log, api)
    for tag, when, session, text in hits:
        print("%-6s %s s%-3s %s" % (tag, when, session, text))
    print("%d hits in %s" % (len(hits), sys.argv[1]))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
