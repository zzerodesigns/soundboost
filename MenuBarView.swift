import AppKit
import SwiftUI

// MARK: - Native Popover Material

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Main Popover View

@available(macOS 14.2, *)
@MainActor
struct MenuBarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let errorMessage = model.tapErrorMessage, model.isMasterEnabled {
                permissionBanner(message: errorMessage)
                Divider()
            }

            if model.apps.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.apps) { app in
                            AppAudioRow(
                                app: app,
                                isMasterEnabled: model.isMasterEnabled,
                                onGainChanged: { model.setGainPercent($0, forAppID: app.id) },
                                onToggleMute: { model.toggleMute(forAppID: app.id) },
                                onReset: { model.resetApp(id: app.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
        .background(VisualEffectBackground())
        .onAppear { model.startMeterPolling() }
        .onDisappear { model.stopMeterPolling() }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuBarSymbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.isMasterEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text("SoundBoost")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button {
                model.resetAllToUnity()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Reset All to 100%")
            .disabled(!model.isMasterEnabled || !model.apps.contains(where: \.isModified))

            Toggle("", isOn: $model.isMasterEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.isMasterEnabled ? "Bypass SoundBoost" : "Enable SoundBoost")

            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))

                Toggle("Remember App Volumes", isOn: $model.rememberVolumes)

                Divider()

                Button("Quit SoundBoost") {
                    model.teardown()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func permissionBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Audio Capture Privacy…") {
                    model.openAudioCapturePrivacySettings()
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No Active Audio Apps")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Play audio in any app to adjust its gain.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Per-App Row

@available(macOS 14.2, *)
@MainActor
private struct AppAudioRow: View {
    let app: AudioAppRowState
    let isMasterEnabled: Bool
    let onGainChanged: (Double) -> Void
    let onToggleMute: () -> Void
    let onReset: () -> Void

    @State private var isEditingText = false
    @State private var draftText = ""
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    PeakLevelMeter(level: isMasterEnabled && !app.isMuted ? app.peakLevel : 0.0)
                }

                Spacer(minLength: 4)

                if app.isModified && isMasterEnabled {
                    Button(action: onReset) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset \(app.name) to 100%")
                }

                percentageControl

                Button(action: onToggleMute) {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(!isMasterEnabled)
                .help(app.isMuted ? "Unmute" : "Mute")
            }

            DetentGainSlider(
                value: Binding(
                    get: { app.isMuted ? 0.0 : app.gainPercent },
                    set: { newValue in
                        let snapped = applyMagneticDetent(newValue)
                        onGainChanged(snapped)
                    }
                ),
                isEnabled: isMasterEnabled
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .opacity(isMasterEnabled ? 1.0 : 0.55)
    }

    @ViewBuilder
    private var percentageControl: some View {
        if isEditingText {
            TextField("100", text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                )
                .focused($textFieldFocused)
                .onSubmit { commitDraft() }
                .onExitCommand { isEditingText = false }
                .onChange(of: textFieldFocused) { _, focused in
                    if !focused && isEditingText {
                        commitDraft()
                    }
                }
        } else {
            Button {
                guard isMasterEnabled else { return }
                draftText = "\(Int(app.gainPercent.rounded()))"
                isEditingText = true
                textFieldFocused = true
            } label: {
                Text(app.isMuted ? "MUTE" : "\(Int(app.gainPercent.rounded()))%")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(percentageColor)
                    .frame(width: 44, alignment: .trailing)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(!isMasterEnabled)
            .help("Click to enter exact percentage (0–400)")
        }
    }

    private var percentageColor: Color {
        if app.isMuted { return .red }
        if app.gainPercent > 100.5 { return .orange }
        return .secondary
    }

    private static let snapThresholds: [(value: Double, radius: Double)] = [
        (25.0, 3.0),
        (50.0, 3.0),
        (75.0, 3.0),
        (100.0, 4.5),
        (125.0, 3.0),
        (150.0, 3.0),
        (200.0, 3.0),
        (250.0, 3.0),
        (300.0, 3.0)
    ]

    private func applyMagneticDetent(_ raw: Double) -> Double {
        for threshold in Self.snapThresholds where abs(raw - threshold.value) <= threshold.radius {
            return threshold.value
        }
        return raw
    }

    private func commitDraft() {
        let digits = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Double(digits) {
            onGainChanged(max(0.0, min(400.0, parsed)))
        }
        isEditingText = false
    }
}

// MARK: - Magnetic Detent Slider (0%–400% with Major Ticks & Incremental Snaps)

private struct DetentGainSlider: View {
    private static let visibleTicks: [Double] = [100, 200, 300]

    @Binding var value: Double
    let isEnabled: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let inset: CGFloat = 8
                let usable = max(1, geo.size.width - inset * 2)
                let clampedValue = max(0.0, min(400.0, value))
                let thumbX = inset + usable * (clampedValue / 400.0)

                ZStack {
                    ForEach(Self.visibleTicks, id: \.self) { threshold in
                        let fraction = threshold / 400.0
                        let tickX = inset + usable * fraction
                        let isUnity = threshold == 100

                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                isUnity
                                    ? Color.primary.opacity(0.55)
                                    : Color.secondary.opacity(0.28)
                            )
                            .frame(width: isUnity ? 2 : 1.5, height: isUnity ? 10 : 6)
                            .position(x: tickX, y: geo.size.height / 2)
                    }

                    // Carve a 16pt clearance around the translucent native knob so ticks never show through it.
                    Circle()
                        .frame(width: 16, height: 16)
                        .position(x: thumbX, y: geo.size.height / 2)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .frame(height: 16)
            .allowsHitTesting(false)

            Slider(value: $value, in: 0...400)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }
}

// MARK: - Minimal dB Peak Level Meter

private struct PeakLevelMeter: View {
    let level: Float

    private var normalizedDB: Double {
        guard level > 0.0001 else { return 0.0 }
        let db = 20.0 * Double(log10f(level)) // -60 dB to 0 dB
        return max(0.0, min(1.0, (db + 60.0) / 60.0))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(meterGradient)
                    .frame(width: max(0, geo.size.width * normalizedDB))
            }
        }
        .frame(height: 3.5)
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .orange],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
