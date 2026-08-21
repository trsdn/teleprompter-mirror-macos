# Teleprompter Mirror

Teleprompter Mirror is a standalone native macOS app for a teleprompter or
beam-splitter setup. It creates a **private virtual source display**, captures
it with ScreenCaptureKit, mirrors or rotates the image, and shows the result
full-screen on a **physical target display**. The aspect ratio is preserved;
unused areas stay black.

The presentation (PowerPoint, Keynote, browser …) is placed on the virtual
source display; the physical target display — by default a display named
**AAA**, if present — shows the mirrored/rotated stream. Because source and
target are separate, the full-screen output never covers the source and no
optical feedback loop occurs.

There are no third-party packages and no permanently installed daemons. A
second instance of the same signed binary runs headless as a local display host
for the lifetime of the app.

## Why a virtual source display

Capturing the same physical display that also carries the full-screen output
does not work: the output covers the source. The app therefore creates a
synthetic display named "Teleprompter Source" at `1920×1080@60` through the
**private CoreGraphics API** (`CGVirtualDisplay`, `CGVirtualDisplayDescriptor`,
`CGVirtualDisplaySettings`, `CGVirtualDisplayMode`).

- The private classes are instantiated exclusively through `NSClassFromString`
  (see `Sources/VirtualDisplayBridge`, a separate Objective-C target with ARC).
  No private symbols are linked.
- The main process launches the same signed binary with an internal headless
  argument. Only this display host holds the `CGVirtualDisplay` object; the
  main process uses ScreenCaptureKit and the output only. This process boundary
  is required on macOS 26, because a process started normally through
  Finder/LaunchServices does not receive reliable capture callbacks for a
  virtual display it created itself.
- The display host exits together with the main process; the virtual display
  therefore disappears at most one second after the app ends.
- The virtual display gets a stable synthetic identity (vendor/product/serial)
  and sRGB primaries so that a preset does not confuse it with real hardware.

The display host reports the actual `CGDirectDisplayID` to the main process
once through a private pipe. The capture source is exclusively the `SCDisplay`
with exactly that ID. ScreenCaptureKit is re-queried briefly and with a bound
for this; there is no fallback by name, position, or most recently appeared
display. After the first detection the app waits once for five seconds, because
macOS 26 can already list a new virtual display before its capture framebuffer
is ready. The filter uses `excludingWindows: []`, since the app and output
windows live on physical displays and never appear on the virtual source.

The full-screen output window is borderless, click-through, never becomes the
main or key window, and does not activate the app. Before starting, the control
window is moved to another physical display where possible — never to the
invisible virtual display.

## Teleprompter setup

1. Place the physical target display so that it projects into the beam
   splitter.
2. Mount the glass typically at roughly a 45° angle in front of the camera.
3. **Flip horizontally** at **0°** is active by default. Adjust rotation and
   vertical flipping to match the physical setup.
4. Drag the presenter view or presentation onto the virtual display
   "Teleprompter Source" and choose a font size that suits the actual camera
   distance.

## Requirements

- macOS 13 Ventura or newer
- Xcode or Command Line Tools with Swift 6
- Screen recording permission for the built app bundle

## Build and test

```bash
git clone https://github.com/trsdn/teleprompter-mirror-macos.git
cd teleprompter-mirror-macos
swift test
./build-app.sh
```

The script creates `dist/Teleprompter Mirror.app`. It automatically prefers an
existing **Developer ID Application** identity, falls back to **Apple
Development**, and only falls back to an ad-hoc signature — with a warning — if
no stable identity exists. There is no hard-coded team or certificate
identifier. An identity can be set explicitly:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build-app.sh
```

The script signs with Hardened Runtime; Developer ID builds get an Apple
timestamp.

### Optional runtime self-test

Only if **Teleprompter Mirror itself** already has screen recording access can
the signed build be tested without a new permission dialog:

```bash
open "dist/Teleprompter Mirror.app" --args --self-test
```

The test creates the virtual source display, selects the default target
display, starts the output, and reports `SELF_TEST_PASS` as soon as a complete
frame of the virtual source display has been accepted and the output layer
reports the rendering status — otherwise `SELF_TEST_FAIL`. Without the
permission it reports `SELF_TEST_SKIP`; it does not request the permission and
does not change any TCC setting. The test does not replace a visual check: it
says nothing about actually visible pixels, nor about whether the mirroring is
correctly oriented in the physical setup.

## Usage

1. Select one of the three preset slots and name it if needed.
2. Select the physical **target display** for the output (default: **AAA**,
   otherwise the smallest external display).
3. Set the rotation to `0°`, `90°`, `180°`, or `270°` and choose horizontal and
   vertical flipping.
4. Choose **Save preset**.
5. Allow screen recording.
6. Drag the presentation onto the virtual display "Teleprompter Source".
7. Choose **Start output**.

All unused areas stay black through proportional fitting. Transforms can be
changed while the output is running.

### Stopping and control

- **Stop** in the control window
- `⌘.` while the app menu or control window is active
- **Stop output** in the status menu of the macOS menu bar
- **Quit Teleprompter Mirror** in the status menu or app menu

`Escape` can trigger the local cancel action in an active control or menu
context. The passive output window deliberately never becomes the key window
and therefore cannot receive `Escape` itself. The status menu stays the
reliable way to stop, even when the control window is covered or closed. No
global keyboard event taps are installed.

## Rendering and resource usage

Capture is limited to 30 Hz and `queueDepth = 4`. Only ScreenCaptureKit screen
samples with frame status `complete`, a valid sample buffer, and a
`CVPixelBuffer` are forwarded. With BGRA `1920×1080` the capture surface matches
the virtual source mode exactly; audio is off and the pointer is visible.

The preferred path `ScreenCaptureKit → AVSampleBufferDisplayLayer` forwards
IOSurface-backed BGRA buffers directly, driven by readiness and backpressure;
frames are not queued up. A session can fall back to `Core Image → CALayer` at
most once. This safe fallback keeps only the newest frame and creates the
context and 30 Hz timer only when needed. On stop, frame, timer, layer, and
context are released. The app does not use `MTKView`. An initially empty virtual
source stays active so that PowerPoint or another window can still be moved to
the virtual desktop later. Real stream and render errors are still reported
explicitly.

The full Finder/LaunchServices path was visually verified on macOS 26.6.1 with
an asymmetric L/R test image on the physical target display AAA: the red `R`
appeared on the left and the yellow `L` on the right, so the horizontal
mirroring was correct.

## Presets and display identity

Each of the three named presets stores exactly one **target display identity**
and the transform through `Codable` in `UserDefaults`. The source is always the
virtual display and does not need to be stored. Presets from the earlier version
that still store a display identity under `display` are still adopted as the
target display. An identity combines, where available:

- vendor, product, and serial number
- stable display UUID
- as a unique fallback, the normalized name and rotation-independent native
  pixel dimensions

A volatile `CGDirectDisplayID` is never stored alone or persistently. Ambiguous
matches are not used automatically.

## Permission, launch at login, and reconnecting

Under **System Settings → Privacy & Security → Screen Recording** the specific
signed app bundle has to be allowed. A stable signature, bundle ID, and stable
app path help macOS recognize the permission again after builds. Creating the
virtual display itself needs no screen recording permission; only capturing it
does.

**Launch at login** uses `SMAppService.mainApp`. For a reliable launch at login,
the signed app should first be moved to `/Applications` and registered from
there. **Start output automatically when the app launches** is a separate
option.

If the saved target display is missing at launch or gets disconnected, the app
waits for `didChangeScreenParametersNotification` without polling. On an
unambiguous return, a requested automatic output starts again. A manual stop
suppresses every automatic restart for the running app session; only an explicit
**Start output** lifts the suppression. Capture or render errors block instead
of creating restart loops.

## Limitations

- The app uses a **private, undocumented** CoreGraphics API for the virtual
  display. It can change between macOS versions and is **not App Store
  compatible**. If the API is unavailable, the app reports this and does not
  start the output.
- Mirroring happens in the output layer (Core Animation / Core Image). There is
  **no** physical scanout flip of the display, so the app cannot guarantee that
  the orientation is correct in a specific beam-splitter setup — rotation and
  flipping have to be set accordingly.
- If only one physical display is connected, it serves as the target and the
  output covers the desktop there. The menu bar stays reachable above the
  click-through output window, so the status menu remains available for stopping
  and for showing the control window again.
- The virtual display is headless and uses a 1920×1080 HiDPI framebuffer;
  windows may have to be moved there "blindly".
- DRM/HDCP-protected content can be delivered **black** by macOS.
- Audio is not transmitted; the pointer is captured.
- Identical target displays without a serial number, unique UUID, name, or
  native dimensions require a manual selection again.
- By default the build script produces the current Mac architecture, not a
  universal binary.
