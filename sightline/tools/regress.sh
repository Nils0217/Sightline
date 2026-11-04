#!/bin/sh
# labels: testing, needs-review
# Every check before a device test (Nils, 2026-11-03: recorded failures must stay fixed).
#   sh tools/regress.sh [find_log.csv api_calls.csv]
# 1. unit tests (one per recorded failure where the rule is testable: FindRulesTests, ReachSafetyTests, ...);
# 2. the simulator: every positive scenario 20/20, every fault scenario 0/20, no silence, no loops;
# 3. with a device log: tools/check_log.py screens it for recorded failures.
# Reads and prints only; writes nothing.
set -e
cd "$(dirname "$0")/../Packages/SightlineCore"
echo "== unit tests"
swift test 2>&1 | grep -E "✘|Test run" | tail -5
echo "== simulator"
swift run -c release SightlineSim 2>/dev/null | python3 -I -c '
import re, sys
faults = {"wrong_object", "hand_only", "object_only", "slide_only"}
bad = seen = 0
for line in sys.stdin:
    p = line.split()
    if len(p) < 13 or not re.fullmatch(r"\d+/\d+", p[1]):
        continue
    seen += 1
    name, ok, silent, loop = p[0], p[1], int(p[11]), int(p[12])  # hits (p[10]) allowed: touching is fine (v9.2)
    n, total = map(int, ok.split("/"))
    want = 0 if name in faults else total
    if n != want or silent or loop:
        bad += 1
        print("FAIL", line.rstrip())
if seen < 25:
    bad += 1
    print("FAIL only %d scenarios ran (25 expected)" % seen)
print("simulator: %d scenarios, %s" % (seen, "all as expected" if not bad else "%d off" % bad))
sys.exit(1 if bad else 0)
'
if [ -n "$1" ]; then
  echo "== device log"
  cd ../..
  python3 -I tools/check_log.py "$1" ${2:+"$2"} || true
fi
