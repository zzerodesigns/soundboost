# SoundBoost Development Log

A chronological record of building **SoundBoost**, a lightweight native macOS 14.2+ per-app audio mixer and volume booster built without virtual audio drivers or third-party dependencies.

---

## Session Overview

- **Initial Release Date:** November 16, 2026
- **Target:** macOS 14.2+ (`SwiftUI`, `AppKit`, `CoreAudio`, `AudioToolbox`, `Accelerate`, `ServiceManagement`)

---

## Timeline & Milestones

### 1. Replacing Virtual Drivers with `AudioHardwareCreateProcessTap`
After testing existing macOS mixers that rely on virtual audio devices and background daemons, the goal was a minimal, menu-bar-only binary that intercepts audio purely in user space.

- **`AudioTapEngine.swift`** was designed around macOS 14.2's `CATapDescription(stereoMixdownOfProcesses:)` and `AudioHardwareCreateProcessTap`, paired with private `AudioHardwareCreateAggregateDevice` instances targeting `kAudioHardwarePropertyDefaultOutputDevice`.
- Setting `tapDescription.muteBehavior = .mutedWhenTapped` ensures the tapped app's direct output is silenced while active and immediately falls back to normal system audio if SoundBoost quits or crashes.
- Process discovery inspects `kAudioHardwarePropertyProcessObjectList` and `kAudioProcessPropertyIsRunningOutput`, walking parent PIDs via `sysctl` (`kinfo_proc`) so WebKit and Chromium/Electron helper processes group cleanly under their parent GUI app (e.g., Safari, Google Chrome).
- Inside `AudioDeviceCreateIOProcIDWithBlock`, audio processing avoids locks, allocations, and Swift runtime overhead:
  - Lock-free 32-bit `OSAtomic` CAS wrappers (`AtomicFloat`) pass target gain to the audio thread and peak levels back to the UI.
  - Per-frame linear gain ramping prevents zipper clicks during slider drags.
  - `Accelerate` (`vDSP_vsmul`, `vDSP_maxmgv`) handles unity/attenuated SIMD scaling and peak metering, while boosted signals (`> 100%`) pass through a $C^1$-continuous `tanhf` soft-knee limiter above `0.75` (`-2.5 dBFS`) to prevent harsh digital clipping.
- Caught and fixed an early memory bug in `AtomicFloat.deinit` where `storage.allocate()` had been written instead of `storage.deallocate()`.

### 2. Menu Bar UI, Persistence & Web Preview
- Implemented `AppModel.swift` with `UserDefaults` persistence keyed by bundle ID, `SMAppService.mainApp` Login Item support, master bypass teardown, and a 30 Hz popover peak-meter polling task.
- Built `MenuBarView.swift` and `AppMain.swift` using `MenuBarExtra` (`.window` style) backed by `NSVisualEffectView` (`.popover` material), a 0%–400% slider with a 100% magnetic detent, inline numeric percentage input, mute toggle, and unity reset controls.
- Added `README.md` with build/codesign instructions and updated `index.html` + `src/App.tsx` so the menu bar UI and `tanhf` limiter transfer curve could be previewed and auditioned interactively in the browser.

### 3. Fixing Swift Concurrency & Actor Isolation
When compiling locally with `swiftc`, strict concurrency checks flagged actor-isolation mismatches between `@MainActor`-isolated `AppModel` and `MenuBarView`'s helper subviews, plus an unused `self` capture warning in `AppModel.init()`:
- Replaced `guard let self else { return 1.0 }` in `engine.initialGainProvider` with `guard self != nil else { return 1.0 }`.
- Wrapped `engine.onAppsChanged` and `engine.onError` closures in `MainActor.assumeIsolated` (safe because `AudioTapEngine` dispatches both onto `DispatchQueue.main.async`).
- Marked both `MenuBarView` and `AppAudioRow` with `@MainActor`, resolving non-isolated context mismatches on `headerBar`, `permissionBanner`, and action closures.

### 4. First Live Run
- Compiled cleanly with `swiftc -O` and ad-hoc signed with `codesign --force --deep --sign - SoundBoost.app`, producing a lightweight standalone application bundle.
- Launched `SoundBoost.app`, granted System Audio Recording (`Audio Capture`) permission, and verified live per-app discovery, peak metering, and `200%` gain boosting on Google Chrome playing YouTube audio.

### 5. Build-Time App Icon & Multi-Threshold Slider Detents
- **`generate_icon.swift` & `build.sh`**: Added a standalone CoreGraphics/AppKit build-time generator that renders a `1024×1024` dark macOS squircle with rim lighting, a centered radial blue glow (`startRadius: 0` with `drawsBeforeStartLocation` to eliminate the initial center-dot artifact), and layered blue `speaker.wave.3.fill` waves, then uses `sips` and `iconutil` to pack `AppIcon.icns` into `Contents/Resources` and registers `CFBundleIconFile` in `Info.plist`—keeping binary image assets out of the repository.
- **Refined Slider Thresholds (`MenuBarView.swift`, `src/App.tsx`)**: Expanded magnetic snapping across both attenuation and boost ranges (`25%`, `50%`, `75%`, `100%`, `125%`, `150%`, `200%`, `250%`, `300%`) without trackpad haptics, keeping visible track markers uncluttered (`100%` primary anchor plus subtle `200%` and `300%` ticks) and masking ticks underneath the translucent native slider knob via `.compositingGroup()` and `.blendMode(.destinationOut)`.

### 6. Bundle Versioning & Local Build Ergonomics (`v0.2.0`)
- **Dynamic Bundle Version Stamping (`build.sh`, `Info.plist`)**: Updated `Info.plist` to `0.2.0` and configured `build.sh` to resolve `CFBundleShortVersionString` automatically (CLI argument → latest Git tag → `Info.plist` fallback) and `CFBundleVersion` from `git rev-list --count HEAD` via `/usr/libexec/PlistBuddy`, eliminating redundant version files and hardcoded `1.0` Finder metadata.
- **Gatekeeper & Interactive `zsh` Fixes (`build.sh`, `README.md`)**: Switched documented invocations to `bash build.sh`, added `xattr -cr` cleanup inside the bundle step before `codesign`, and stripped inline `#` comments from copy-paste Terminal commands so macOS interactive `zsh` (`INTERACTIVE_COMMENTS` off by default) executes cleanly in one paste without quarantine prompts or `quote>` stalls.

---

## Next Up

- Add a right-click context menu on the menu bar status icon for quick quit and version/about actions.
- Align minor visual inconsistencies between the native macOS popover and web preview (menu bar speaker icon, per-app reset button glyph, and conditional output device display).
- Explore additional mixer features (per-app EQ / balance, global keyboard shortcuts, or pinned favorite apps).
