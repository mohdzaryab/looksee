# Looksee

Menu bar app for multi-monitor Macs, inspired by the Glance Switch demo. Turn your head toward a screen and keyboard focus lands back in the window you last used there. Runs on the Mac's camera; frames are analysed in memory and never stored or sent anywhere.

## For friends: install

1. Download **Looksee-x.y.z.dmg** from the [latest release](../../releases/latest), open it, and drag **Looksee** onto **Applications**. Open it from Applications, not from inside the DMG window.
2. The first time, macOS says it "could not verify" the app, because it isn't from the App Store or a registered developer:
   - **macOS 15 / 26:** click **Done** (not *Move to Bin*), open **System Settings › Privacy & Security**, scroll to the Security section and click **Open Anyway** next to Looksee, then confirm with your password.
   - **macOS 14:** Control-click Looksee › **Open** › **Open**.
3. Allow **Camera**, then turn on Looksee under **Privacy & Security › Accessibility**.
4. Click the eyes icon in the menu bar › **Calibrate Screens**. Face each screen as it lights up green and hold still for two seconds.

That's it. Needs macOS 14 or later and at least two displays. Works on Apple Silicon and Intel.

## Build and run

```
./build.sh run           # builds build/Looksee.app and launches it
./test.sh                # unit tests for the gaze classifier
./scripts/release.sh     # universal (Apple Silicon + Intel) app in dist/Looksee-<version>.dmg
```

Only the Command Line Tools are needed, no Xcode.

## First run

1. Allow **Camera** when macOS asks.
2. Allow **Accessibility** in System Settings → Privacy & Security (needed to see and raise other apps' windows).
3. Calibration starts on its own: each screen is highlighted in turn, look at it and hold still for a second. Rerun it any time from the menu if you move your monitors or the camera.

## Using it

- With a single display the app idles: the camera is off and the icon shows a slashed eye until another screen is connected.
- **⇧⌘G** pauses and resumes. Pausing turns the camera off. The menu bar icon shows eyes when active, an eye with a slash when paused, and a warning badge when something is missing (camera, calibration).
- The menu lists each screen and the window it currently remembers for it.
- **Options**
  - *Hold focus while typing*: glances are ignored for a moment after each keystroke, so reading from one screen while typing on another does not move focus.
  - *Raise top window if nothing remembered*: on the first glance at a screen, raise whatever window is on top there.
  - *Move pointer along* (on by default): also move the pointer to where it last was on that screen, since macOS sends scrolling to the window under the pointer. Not done while a mouse button is held down.
  - *Dwell*: how long you have to look before focus moves.
  - *Launch at login*.

## How it works

`GazeTracker` runs AVFoundation at 640×480 and Vision face detection on every other frame, producing head yaw, pitch and face position. `GazeClassifier` smooths that and matches it against the per-screen signatures from calibration with dwell and hysteresis. `FocusTracker` polls the frontmost window through Accessibility and remembers the last window per screen. `WindowSwitcher` activates the app and raises that window, falling back to the topmost window on the screen from the window server's z-order.

## Caveats

- Ad-hoc signing means every rebuild produces a "new" app to macOS, so the Accessibility grant stops matching after `./build.sh` even though the toggle still shows on. Fix for one build: `tccutil reset Accessibility com.zaryab.looksee`, relaunch, grant again. Permanent fix: create a self-signed code-signing certificate named "Zaryab Local Code Signing" in Keychain Access (Certificate Assistant → Create a Certificate, type Code Signing) and `build.sh` will use it automatically.
- Head pose, not eye gaze, is what the camera reads. Screens that sit very close to each other in your field of view will be harder to tell apart; moving them a little further apart or using the Relaxed dwell helps.
