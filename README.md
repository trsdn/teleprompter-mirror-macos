<div align="center">

<img src="docs/icon.png" alt="App icon" width="128">

# Teleprompter Mirror

[![CI](https://github.com/trsdn/teleprompter-mirror-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/trsdn/teleprompter-mirror-macos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)](#requirements)
[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](Package.swift)

</div>

Teleprompter Mirror is a standalone native macOS app for a teleprompter or
mirror-glass setup. It captures a selectable source with ScreenCaptureKit,
mirrors or rotates the image, and shows the result full-screen on a **physical
target display**. The aspect ratio is preserved; unused areas are black.

Three source types are available:

| Source | Description | When useful |
| --- | --- | --- |
| **Virtual display** | Creates an invisible display named "Teleprompter Source". | When the presenter view should not be on any visible display. |
| **Display** | Mirrors a visible physical display. Source and target must not be identical. | When an existing display should remain usable. |
| **Window** | Mirrors exactly one window, for example the PowerPoint presenter view. | The simplest approach: everything remains visible and normally usable. |

The physical target display — by default a display named **AAA**, if present —
shows the mirrored/rotated stream. Because source and target are separate, the
full-screen output does not cover the source and no optical feedback loop is
created.

This app combines the earlier *Display Transformer* (display source) and
*Teleprompter Mirror* (virtual source) in one program and adds Window mode.

There are no third-party packages or permanently installed daemons. Only in
**Virtual display** mode, a second instance of the same signed binary runs
headless as a local display host while the app is running.

## The virtual source display

Capturing the same physical display that also contains the full-screen output is
not useful: the output covers the source. For that reason, the app can use the
**private CoreGraphics API** (`CGVirtualDisplay`, `CGVirtualDisplayDescriptor`,
`CGVirtualDisplaySettings`, `CGVirtualDisplayMode`) to create a synthetic
display named "Teleprompter Source" with `1920×1080@60`.

- The private classes are instantiated exclusively through `NSClassFromString`
  (see `Sources/VirtualDisplayBridge`, a separate Objective-C target component
  with ARC). No private symbols are linked.
- The main process starts the same signed binary with an internal headless
  argument. Only this display host holds the `CGVirtualDisplay` object; the main
  process uses only ScreenCaptureKit and the output. This process boundary is
  required on macOS 26 because a normal process launched through
  Finder/LaunchServices does not reliably receive capture callbacks for a
  virtual display it created itself.
- The display host exits together with the main process; as a result, the
  virtual display disappears no later than one second after the app ends.
- The virtual display receives a stable synthetic identity
  (manufacturer/product/serial number) and sRGB primaries so the configuration
  does not confuse it with real hardware.

The display host reports the actual `CGDirectDisplayID` once to the main process
through a private pipe. The capture source is exclusively the `SCDisplay` with
exactly this ID. ScreenCaptureKit is queried again briefly and in a limited way
for this; there is no fallback through names, positions, or the most recently
appeared display. After the first detection, the app waits once for five seconds
because macOS 26 can already list a new virtual display before its capture
framebuffer is ready. The filter uses `excludingWindows: []` because app and
output windows are on physical displays and never appear on the virtual source.

The full-screen output window is borderless, click-through, never becomes the
main or keyboard window, and does not activate the app. Before startup, the
control window is moved to another physical display whenever possible — never to
the invisible virtual display.

## Teleprompter setup

1. Place the physical target display so it shines into the mirror glass.
2. Mount the glass typically at approximately a 45° angle in front of the
   camera.
3. By default, **Mirror horizontally** at **0°** is enabled. Adjust rotation and
   vertical mirroring depending on the physical setup.
4. Choose a source: the presenter-view window (recommended), another physical
   display, or the virtual display "Teleprompter Source". Choose the font size
   for the actual camera distance.

## Requirements

- macOS 13 Ventura or newer
- Xcode or Command Line Tools with Swift 6
- Screen Recording permission for the built app bundle

## Building and testing

```bash
git clone https://github.com/trsdn/teleprompter-mirror-macos.git
cd teleprompter-mirror-macos
swift test
./build-app.sh
```

The script creates `dist/Teleprompter Mirror.app`. It automatically prefers an
available identity of type **Developer ID Application**, falls back to **Apple
Development**, and only falls back to an ad-hoc signature with a warning if no
stable identity is available. There is no hard-coded team or certificate
identifier. An identity can be set explicitly:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build-app.sh
```

The script signs with Hardened Runtime; Developer ID builds receive an Apple
timestamp.

### App icon

The icon is generated from code and is already present in the repository as
`Resources/AppIcon.icns`; no additional step is needed for a normal build.
After changes to `Scripts/make-icon.swift`, regenerate it:

```bash
swift Scripts/make-icon.swift
```

### Optional runtime self-test

Only if **Teleprompter Mirror itself** already has Screen Recording access can
the signed build be tested without a new permission dialog:

```bash
open "dist/Teleprompter Mirror.app" --args --self-test
```

The test forces the virtual source, selects the default target display, starts
the output, and reports `SELF_TEST_PASS` as soon as a complete frame of the
virtual source display has been accepted and the output layer reports rendering
status — otherwise `SELF_TEST_FAIL`. Without existing permission it reports
`SELF_TEST_SKIP`; it does not request permission and does not change any TCC
setting. The test does not replace a visual inspection: it says neither anything
about actually visible pixels nor whether the mirroring is correctly oriented in
the physical setup.

## Operation

1. Under **Source**, choose the type: **Virtual display**, **Display**, or
   **Window**. For Display or Window, additionally select the specific entry;
   the window list can be refreshed with the arrow icon. In virtual mode,
   **Arrangement in Display Settings …** opens the system setting directly,
   where you define at which edge the invisible display is located and where the
   mouse leaves it.
2. Select the physical **target display** for the output (default: **AAA**,
   otherwise the smallest external display). The target display can never also
   be the source.
3. Under **Orientation**, set rotation `0°`, `90°`, `180°`, or `270°` and
   horizontal and vertical mirroring. The small preview shows the result
   immediately; **Default** resets to 0° with horizontal mirroring.
4. Allow Screen Recording.
5. Choose **Start Output**.

There are no preset slots anymore: every change is saved automatically
immediately and restored on the next launch. All unused areas remain black
through proportional fitting. Transformations can be changed while output is
running.

### Stopping and control

- **Stop** in the control window
- `⌘.` while the app menu or control window is active
- **Stop Output** in the status menu in the macOS menu bar
- **Quit Teleprompter Mirror** in the status menu or app menu

`Escape` can trigger cancellation in the active control/menu context. The
passive output window is intentionally never the keyboard window and therefore
cannot receive `Escape` itself. The status menu remains the reliable way to
stop, even if the control window is covered or closed. No global keyboard event
taps are installed.

## Rendering and resource usage

Capture is limited to 30 Hz and `queueDepth = 4`. Only
ScreenCaptureKit screen samples with frame status `complete`, a valid sample
buffer, and a `CVPixelBuffer` are forwarded. The capture resolution (BGRA) is
proportionally limited to at most the longest edge of the target display so that
large sources such as a 5120×1440 display are not transferred unnecessarily at
full resolution. Audio is off; in Window mode, the mouse pointer is not
captured. Measured consumption while running: around 1–3% CPU and less than
50 MB of memory.

The preferred path
`ScreenCaptureKit → AVSampleBufferDisplayLayer` forwards IOSurface-backed BGRA
buffers directly under readiness and backpressure control; frames are not
queued up. A session can fall back to `Core Image → CALayer` at most once. This
safe fallback keeps only the newest frame and creates the context and 30 Hz
timer only when needed. On stop, frame, timer, layer, and context are released.
The app does not use `MTKView`. An initially empty virtual source remains active
so PowerPoint or another window can be moved to the virtual desktop later. Real
stream and rendering errors continue to be reported explicitly.

The complete Finder/LaunchServices path was visually verified on macOS 26.6.1
with an asymmetric L/R test image on the physical target display AAA: the red
`R` appeared on the left and the yellow `L` on the right, confirming that
horizontal mirroring was correct.

## Saved configuration and display identity

The app stores exactly one configuration through `Codable` in `UserDefaults`:
source type, selected source, **target display identity**, and transformation.
Older settings with three preset slots are migrated automatically to the last
active configuration on first launch; even older states with a display identity
under `display` continue to be adopted as the target display.

A window is recognized again by bundle ID, app name, and window title, never by
the transient `CGWindowID` alone. Ambiguous matches are not used automatically.

A display identity combines, as far as available:

- manufacturer, product, and serial number
- stable display UUID
- as a unique fallback, normalized name and rotation-independent native pixel
  dimensions

A transient `CGDirectDisplayID` is never stored alone or permanently. Ambiguous
matches are not used automatically.

## Permission, login start, and reconnection

Under **System Settings → Privacy & Security → Screen Recording**, the specific
signed app bundle must be allowed. A stable signature, bundle ID, and stable app
path help macOS recognize the permission again after builds. Creating the
virtual display itself does not require Screen Recording permission; only
capturing it does.

**Start at Login** uses `SMAppService.mainApp`. For reliable login start, the
signed app should first be moved to `/Applications` and registered from there.
**Automatically start output when the app starts** is a separate option.

If the saved target display is missing at startup or disconnected, the app waits
without polling for `didChangeScreenParametersNotification`. When it returns
unambiguously, a desired automatic output starts again. A manual stop suppresses
any automatic restart for the current app session; only an explicit **Start
Output** lifts the suppression. Capture or rendering errors are blocked instead
of creating restart loops.

## Limitations

- The app uses a **private, undocumented** CoreGraphics API for the virtual
  display. This can change between macOS versions and is **not suitable for the
  App Store**. If the API is not available, the app reports this and starts no
  output; Display and Window modes remain usable.
- The virtual display is operated blindly: it has its own menu bar and is only
  visible as a mirrored image, which is why the mouse feels "the wrong way
  around" there. Display or Window mode is preferable for interactive work.
- In Window mode, output ends when the source window is closed. The app then
  updates the window list automatically.
- Mirroring happens in the output layer (Core Animation / Core Image). There is
  **no** physical scanout flip of the display; therefore the app cannot
  guarantee that the orientation is correct in the specific mirror-glass setup —
  rotation and mirroring must be adjusted accordingly.
- If only one physical display is connected, it serves as the target and the
  output covers the desktop there. In this case, the menu bar intentionally
  remains reachable above the click-through output window so the status menu
  remains available for stopping and showing the controls again. As soon as at
  least one additional display is connected, the output fully covers the target
  display — including its menu bar and Dock — because otherwise the menus of the
  currently active app would be visible there instead of the mirrored image.
- The virtual display is headless and uses a 1920×1080 HiDPI framebuffer;
  windows may need to be moved there "blindly".
- DRM/HDCP-protected content may be delivered as **black** by macOS.
- Audio is not transmitted; the mouse pointer is captured.
- Identical target displays without serial numbers and without a unique UUID,
  name, or native dimensions require manual selection again.
- By default, the build script creates the current Mac architecture, not a
  Universal Binary.

## Contributing

Contributions are welcome. The development workflow, language and commit
conventions, and the intentionally narrow project scope are described in
[CONTRIBUTING.md](CONTRIBUTING.md).

Please do **not** report security-relevant findings as an issue; instead, use a
private report as described in [SECURITY.md](SECURITY.md).

The [Code of Conduct](CODE_OF_CONDUCT.md) applies to how we work together.

## License

[MIT](LICENSE) — Copyright © 2026 Torsten Mahr.
