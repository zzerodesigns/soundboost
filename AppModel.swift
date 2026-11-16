import AppKit
import Foundation
import Observation
import ServiceManagement

@available(macOS 14.2, *)
struct AudioAppRowState: Identifiable, Equatable {
    let id: String
    let bundleID: String?
    let name: String
    let icon: NSImage
    var gainPercent: Double     // 0.0 ... 400.0
    var isMuted: Bool
    var peakLevel: Float        // Linear smoothed amplitude 0.0 ... 1.0+

    var effectiveLinearGain: Float {
        isMuted ? 0.0 : Float(gainPercent / 100.0)
    }

    var isModified: Bool {
        isMuted || abs(gainPercent - 100.0) > 0.5
    }
}

@available(macOS 14.2, *)
@MainActor
@Observable
final class AppModel {
    private enum DefaultsKey {
        static let rememberVolumes = "SoundBoost.rememberVolumes"
        static let savedVolumes = "SoundBoost.savedVolumes"
    }

    var isMasterEnabled: Bool = true {
        didSet {
            if isMasterEnabled != oldValue {
                handleMasterToggleChanged()
            }
        }
    }

    var rememberVolumes: Bool {
        didSet {
            UserDefaults.standard.set(rememberVolumes, forKey: DefaultsKey.rememberVolumes)
            if !rememberVolumes {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.savedVolumes)
            } else {
                persistCurrentVolumes()
            }
        }
    }

    var launchAtLogin: Bool = false
    var apps: [AudioAppRowState] = []
    var tapErrorMessage: String?

    private let engine = AudioTapEngine()
    private var meterTask: Task<Void, Never>?

    var hasBoostedApp: Bool {
        isMasterEnabled && apps.contains { !$0.isMuted && $0.gainPercent > 100.5 }
    }

    var menuBarSymbolName: String {
        if !isMasterEnabled {
            return "speaker.slash.fill"
        }
        return hasBoostedApp ? "speaker.wave.3.fill" : "speaker.wave.2.fill"
    }

    init() {
        if UserDefaults.standard.object(forKey: DefaultsKey.rememberVolumes) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKey.rememberVolumes)
        }
        self.rememberVolumes = UserDefaults.standard.bool(forKey: DefaultsKey.rememberVolumes)
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        engine.initialGainProvider = { [weak self] appID in
            guard self != nil else { return 1.0 }
            let remember = UserDefaults.standard.bool(forKey: DefaultsKey.rememberVolumes)
            guard remember,
                  let dict = UserDefaults.standard.dictionary(forKey: DefaultsKey.savedVolumes) as? [String: Double],
                  let savedPercent = dict[appID] else {
                return 1.0
            }
            return Float(max(0.0, min(400.0, savedPercent)) / 100.0)
        }

        engine.onAppsChanged = { [weak self] discovered in
            MainActor.assumeIsolated {
                self?.mergeDiscoveredApps(discovered)
            }
        }

        engine.onError = { [weak self] message in
            MainActor.assumeIsolated {
                self?.tapErrorMessage = message
            }
        }

        engine.start()
    }

    func teardown() {
        stopMeterPolling()
        engine.stop()
    }

    // MARK: - Popover Meter Polling

    func startMeterPolling() {
        guard meterTask == nil else { return }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self else { break }
                self.updateMeters()
            }
        }
    }

    func stopMeterPolling() {
        meterTask?.cancel()
        meterTask = nil
        for index in apps.indices {
            apps[index].peakLevel = 0.0
        }
    }

    private func updateMeters() {
        guard isMasterEnabled else {
            for index in apps.indices {
                apps[index].peakLevel = 0.0
            }
            return
        }
        let peaks = engine.readAndResetPeaks()
        for index in apps.indices {
            let id = apps[index].id
            let rawPeak = peaks[id] ?? 0.0
            let prev = apps[index].peakLevel
            // Fast attack, smooth exponential decay for readable Control Center meters.
            apps[index].peakLevel = rawPeak >= prev ? rawPeak : prev * 0.82
        }
    }

    // MARK: - Controls

    func setGainPercent(_ percent: Double, forAppID id: String) {
        let clamped = max(0.0, min(400.0, percent.rounded()))
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].gainPercent = clamped
        if clamped > 0 && apps[idx].isMuted {
            apps[idx].isMuted = false
        }
        engine.setGain(apps[idx].effectiveLinearGain, forAppID: id)
        saveVolumeIfEnabled(percent: clamped, forAppID: id)
    }

    func toggleMute(forAppID id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].isMuted.toggle()
        engine.setGain(apps[idx].effectiveLinearGain, forAppID: id)
    }

    func resetApp(id: String) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].isMuted = false
        apps[idx].gainPercent = 100.0
        engine.setGain(1.0, forAppID: id)
        saveVolumeIfEnabled(percent: 100.0, forAppID: id)
    }

    func resetAllToUnity() {
        for idx in apps.indices {
            apps[idx].isMuted = false
            apps[idx].gainPercent = 100.0
            apps[idx].peakLevel = 0.0
        }
        engine.resetAllGains()
        if rememberVolumes {
            persistCurrentVolumes()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    func openAudioCapturePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Internal State Sync

    private func handleMasterToggleChanged() {
        if !isMasterEnabled {
            for idx in apps.indices {
                apps[idx].isMuted = false
                apps[idx].gainPercent = 100.0
                apps[idx].peakLevel = 0.0
            }
            engine.setBypass(true)
            tapErrorMessage = nil
        } else {
            engine.setBypass(false)
            for idx in apps.indices {
                let percent = rememberedPercent(for: apps[idx].id) ?? 100.0
                apps[idx].gainPercent = percent
                apps[idx].isMuted = false
                engine.setGain(Float(percent / 100.0), forAppID: apps[idx].id)
            }
        }
    }

    private func mergeDiscoveredApps(_ discovered: [ActiveAudioApp]) {
        let existingMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        apps = discovered.map { item in
            if let existing = existingMap[item.id] {
                return AudioAppRowState(
                    id: item.id,
                    bundleID: item.bundleID,
                    name: item.name,
                    icon: item.icon,
                    gainPercent: existing.gainPercent,
                    isMuted: existing.isMuted,
                    peakLevel: existing.peakLevel
                )
            }
            let initialPercent = isMasterEnabled ? (rememberedPercent(for: item.id) ?? 100.0) : 100.0
            return AudioAppRowState(
                id: item.id,
                bundleID: item.bundleID,
                name: item.name,
                icon: item.icon,
                gainPercent: initialPercent,
                isMuted: false,
                peakLevel: 0.0
            )
        }
    }

    private func rememberedPercent(for appID: String) -> Double? {
        guard rememberVolumes,
              let dict = UserDefaults.standard.dictionary(forKey: DefaultsKey.savedVolumes) as? [String: Double] else {
            return nil
        }
        return dict[appID].map { max(0.0, min(400.0, $0)) }
    }

    private func saveVolumeIfEnabled(percent: Double, forAppID appID: String) {
        guard rememberVolumes else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: DefaultsKey.savedVolumes) as? [String: Double]) ?? [:]
        dict[appID] = percent
        UserDefaults.standard.set(dict, forKey: DefaultsKey.savedVolumes)
    }

    private func persistCurrentVolumes() {
        var dict = (UserDefaults.standard.dictionary(forKey: DefaultsKey.savedVolumes) as? [String: Double]) ?? [:]
        for app in apps {
            dict[app.id] = app.gainPercent
        }
        UserDefaults.standard.set(dict, forKey: DefaultsKey.savedVolumes)
    }
}
