<!-- labels: important, testing, needs-review -->
# G3 — ARWorldMap relocalization

**Question:** can a scan saved earlier be reloaded after the app restarts, so a target found yesterday is still at the right place today?

**Gate:** after a full app restart, ARKit relocalizes in **≤ 10 s** (from Load map to tracking `normal`), and the saved marker reappears on the same physical spot (eyeball, note the offset in cm). **Fail →** the demo scans the room in the same session.

## How it works
- Scan: world tracking runs; `mapping` goes `limited → extending → mapped` as you look around.
- **Place marker**: raycast from the yellow cross (screen centre) to a surface, add an `ARAnchor` named `g3_marker`. The anchor is saved inside the map.
- **Save map**: `getCurrentWorldMap` → `Documents/g3_worldmap.arworldmap` (one file, overwritten by each save).
- **Load map**: run with `initialWorldMap`. Tracking shows `limited_relocalizing` until ARKit matches the scene; the time to `normal` is logged. Timeout 30 s.

## Output files (app Documents)
- `g3_relocalize_<time>.csv` — **one file per app launch**, rewritten with all rows of that launch. The scan launch holds the `saved` row; the relaunch holds `load_start` and `relocalized`/`timeout`. Export at the end of **each** launch (so twice for one run).
- `g3_worldmap.arworldmap` — the saved map, overwritten by every save.

## How to run
1. Run from Xcode. The app opens on **G3 map**.
2. Stand in a normal lit room with furniture. Walk around slowly for 20–30 s, pointing at walls, furniture and the floor, until `mapping mapped`.
3. Point the yellow cross at a distinct spot (e.g. a corner of a table or book) and tap **Place marker**. A green dot appears there. Remember the exact spot.
4. Tap **Save map** (enabled when mapping is `extending` or `mapped`). Wait for the beep and "Map saved".
5. Tap **CSV** and save it (this launch's file).
6. **Force-quit** the app: swipe up from the bottom and hold, then swipe the Sightline card away.
7. Walk back roughly to where you stood when saving. Open Sightline again (from the phone, not Xcode) → it opens on G3.
8. Tap **Load map** and slowly point the phone at the same area. Wait for the 3-tone sound and "Relocalized in X s".
9. Check whether the green dot is back on the same spot. Estimate the offset in cm.
10. Tap **CSV** and save it (this second file).
11. Optional, harder: repeat steps 6–10 with the lights dimmer, or from a different starting point.
