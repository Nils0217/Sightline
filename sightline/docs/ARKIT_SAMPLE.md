<!-- labels: testing, reference -->

> Update 2026-10-31: this document keeps the original experiment and reference record. Current find-and-grab behaviour, call counts and acceptance are in [PRD](PRD.md), [TEST_LOG](TEST_LOG.md) (T10) and [FIND_TEST](FIND_TEST.md). Earlier passes do not mean the current version has been tested on the device or with blind users.
# S0.1 — Run Apple's ARKit scene-reconstruction sample on the iPhone 15 Pro

Goal: prove the Mac → iPhone toolchain works and LiDAR mesh classification runs. Do **not** copy the sample into this repo; keep it in `~/Developer/apple-samples/`.

## 1. Check versions
1. iPhone: **Settings → General → About → iOS Version**. Write it in `docs/SPIKE.md`.
2. Mac: open Xcode → **Xcode → Settings… → Components** (older Xcode: **Platforms**). The iOS platform listed must be ≥ the iPhone's iOS version. If not, update Xcode from the App Store.

## 2. Download the sample
1. Open https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
2. Click **Download** (top of the page), unzip into `~/Developer/apple-samples/`.
3. Double-click the `.xcodeproj` to open it in Xcode.

## 3. Sign with a free Apple ID
1. **Xcode → Settings… → Accounts → +** → Apple ID → sign in.
2. In the left sidebar click the blue project icon → select the app **target** → tab **Signing & Capabilities**.
3. Tick **Automatically manage signing**. **Team** → `<Your Name> (Personal Team)`.
4. **Bundle Identifier**: change to something unique, e.g. `com.nils.scenereconstruction`. (Free accounts fail on Apple's default ID.)

Free Personal Team limits: the app expires after 7 days (just run it again), max 3 sideloaded apps per device.

## 4. Prepare the iPhone
1. Connect by USB-C. On the iPhone tap **Trust** and enter the passcode.
2. **Settings → Privacy & Security → Developer Mode** → on → restart → confirm **Turn On** after reboot.
   (The Developer Mode switch only appears after the iPhone has been connected to Xcode once.)
3. In Xcode, top toolbar → device menu → pick the iPhone (wait for "Preparing device…" to finish, can take a few minutes the first time).

## 5. Run
1. Press **⌘R** (Product → Run).
2. First launch fails with "Untrusted Developer": on the iPhone go to **Settings → General → VPN & Device Management → Developer App → <your Apple ID> → Trust**, then ⌘R again.
3. Allow camera access. Slowly pan around the room.

**Pass:** a coloured mesh overlays the room, with different colours for floor / table / wall / seat. Tap a surface to see its classification label.

## 6. Report back
Paste into the chat:
- iOS version, Xcode version
- Pass / fail, and any red error text from Xcode
- Rough feel: how fast the mesh appears, does it lag

## Common errors
| Error | Fix |
|---|---|
| "Failed to register bundle identifier" | Change the Bundle Identifier to something more unique |
| "Developer Mode disabled" | Step 4.2 |
| "iOS x.y is not installed" / device unsupported | Update Xcode, or Xcode → Settings → Components → download the iOS platform |
| "Could not launch … Untrusted Developer" | Step 5.2 |
| Black screen / no mesh | Must be a LiDAR device (15 Pro is); improve lighting; move slower |
