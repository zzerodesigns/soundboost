# SoundBoost

A lightweight, native macOS 14.2+ menu bar volume booster and per-app audio mixer built exclusively with Apple system frameworks (`SwiftUI`, `AppKit`, `CoreAudio`, `AudioToolbox`, `Accelerate`, `ServiceManagement`). No virtual audio drivers, kernel extensions, or third-party dependencies.

## Architecture

- **`AudioTapEngine.swift`** — Discovers active audio-producing processes via `kAudioHardwarePropertyProcessObjectList` and `kAudioProcessPropertyIsRunningOutput`, resolves helper processes (WebKit, Chromium/Electron renderers) back to their parent GUI `NSRunningApplication`, creates per-app taps using `AudioHardwareCreateProcessTap` and `CATapDescription(stereoMixdownOfProcesses:)` with `.mutedWhenTapped`, and routes them through private `AudioHardwareCreateAggregateDevice` instances targeting `kAudioHardwarePropertyDefaultOutputDevice`.
- **Real-Time DSP (`IOProc`)** — Runs directly on CoreAudio's real-time HAL I/O thread with zero locks, zero heap allocations, and zero Swift runtime overhead. Uses lock-free `OSAtomic` CAS floats for target gain and peak metering, linear per-frame gain ramping across buffers to prevent zipper noise, `Accelerate` (`vDSP`) for SIMD scaling/peak detection, and a $C^1$-continuous `tanhf` soft-knee limiter above `0.75` when gain exceeds `100%`.
- **`AppModel.swift`** — Manages per-app state, `UserDefaults` persistence (keyed by bundle identifier, with an option to disable memory), 30 Hz popover peak meter polling, master bypass teardown, and `SMAppService.mainApp` Launch at Login registration.
- **`MenuBarView.swift` & `AppMain.swift`** — Renders a `MenuBarExtra` `.window` popover backed by `NSVisualEffectView` (`.popover` material), featuring a 0%–400% slider with visible tick marks at `100%`, `200%`, and `300%` (masked cleanly under the knob), subtle magnetic detents at `25%`, `50%`, `75%`, `100%`, `125%`, `150%`, `200%`, `250%`, and `300%`, inline numeric percentage editing, per-app dB meters, quick mute, and single-click unity reset.
- **`Info.plist` & `generate_icon.swift`** — Configures `LSUIElement = YES` (menu-bar-only, no Dock icon), `LSMinimumSystemVersion = 14.2`, `NSAudioCaptureUsageDescription`, and `CFBundleIconFile` pointing to a Retina `AppIcon.icns` generated at build time.

## Requirements

- macOS 14.2 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`) or Xcode 15.2+

## Build & Package Locally

Run the build script from the repository root on your Mac to generate the Retina `AppIcon.icns`, stamp the bundle version (from `bash build.sh <version>`, the latest Git tag, or `Info.plist`), compile the Swift binary, and ad-hoc sign `SoundBoost.app`:

```bash
bash build.sh
bash build.sh 0.2.0
```

> **Note:** Running via `bash build.sh` avoids macOS Gatekeeper blocking a freshly downloaded `.sh` file. If you prefer `./build.sh`, clear the browser quarantine attribute once first with `xattr -d com.apple.quarantine build.sh && chmod +x build.sh`.

Or paste the manual commands directly into Terminal (comment-free so interactive `zsh` executes them in one go):

```bash
mkdir -p SoundBoost.app/Contents/MacOS SoundBoost.app/Contents/Resources
cp Info.plist SoundBoost.app/Contents/Info.plist
mkdir -p AppIcon.iconset
swift generate_icon.swift AppIcon.png
for size in 16 32 128 256 512; do
  sips -z $size $size AppIcon.png --out AppIcon.iconset/icon_${size}x${size}.png >/dev/null
  sips -z $((size*2)) $((size*2)) AppIcon.png --out AppIcon.iconset/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o SoundBoost.app/Contents/Resources/AppIcon.icns
rm -rf AppIcon.iconset AppIcon.png
swiftc -O \
  -target "$(uname -m)-apple-macosx14.2" \
  -o SoundBoost.app/Contents/MacOS/SoundBoost \
  AudioTapEngine.swift AppModel.swift MenuBarView.swift AppMain.swift \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework Accelerate \
  -framework ServiceManagement
xattr -cr SoundBoost.app
codesign --force --deep --sign - SoundBoost.app
```

### Building a Universal Binary (Apple Silicon + Intel)

```bash
swiftc -O -target arm64-apple-macosx14.2 -o SoundBoost-arm64 \
  AudioTapEngine.swift AppModel.swift MenuBarView.swift AppMain.swift \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework ServiceManagement

swiftc -O -target x86_64-apple-macosx14.2 -o SoundBoost-x86_64 \
  AudioTapEngine.swift AppModel.swift MenuBarView.swift AppMain.swift \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework ServiceManagement

lipo -create -output SoundBoost.app/Contents/MacOS/SoundBoost SoundBoost-arm64 SoundBoost-x86_64
rm SoundBoost-arm64 SoundBoost-x86_64
codesign --force --deep --sign - SoundBoost.app
```

### Run & Grant Permissions

```bash
open SoundBoost.app
```

1. Start playing audio in any app (for example, Safari, Spotify, or Music).
2. macOS will prompt for **System Audio Recording Only** permission (`Audio Capture`). Approve it in the prompt or under **System Settings → Privacy & Security → Screen & System Audio Recording**.
3. Click the speaker icon in the macOS menu bar to adjust per-app gain from `0%` to `400%`.

## Notes on the Web Preview

Because CoreAudio `AudioHardwareCreateProcessTap` and SwiftUI `MenuBarExtra` require macOS 14.2+, the `src/` web application provides an interactive UI preview of the `MenuBarView` popover, magnetic 100% detent, inline gain entry, soft-knee `tanhf` limiter transfer curve, and optional Web Audio auditioning inside the browser.
