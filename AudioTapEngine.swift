import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - Lock-Free Real-Time Atomic Float

/// Lock-free 32-bit atomic float backed by Darwin's OSAtomic CAS primitives.
/// Safe for use on CoreAudio's real-time IOProc thread with no locks, allocations, or bridging headers.
final class AtomicFloat {
    private let storage: UnsafeMutablePointer<Int32>

    init(_ initialValue: Float) {
        storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        storage.initialize(to: Int32(bitPattern: initialValue.bitPattern))
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    @inline(__always)
    func load() -> Float {
        let bits = OSAtomicAdd32Barrier(0, storage)
        return Float(bitPattern: UInt32(bitPattern: bits))
    }

    @inline(__always)
    func store(_ newValue: Float) {
        let newBits = Int32(bitPattern: newValue.bitPattern)
        while true {
            let current = OSAtomicAdd32Barrier(0, storage)
            if OSAtomicCompareAndSwap32Barrier(current, newBits, storage) {
                return
            }
        }
    }

    @inline(__always)
    func storeMax(_ candidate: Float) {
        while true {
            let currentBits = OSAtomicAdd32Barrier(0, storage)
            let current = Float(bitPattern: UInt32(bitPattern: currentBits))
            if candidate <= current {
                return
            }
            let newBits = Int32(bitPattern: candidate.bitPattern)
            if OSAtomicCompareAndSwap32Barrier(currentBits, newBits, storage) {
                return
            }
        }
    }

    @inline(__always)
    func exchange(_ newValue: Float) -> Float {
        let newBits = Int32(bitPattern: newValue.bitPattern)
        while true {
            let currentBits = OSAtomicAdd32Barrier(0, storage)
            if OSAtomicCompareAndSwap32Barrier(currentBits, newBits, storage) {
                return Float(bitPattern: UInt32(bitPattern: currentBits))
            }
        }
    }
}

// MARK: - Discovered Audio App Metadata

struct ActiveAudioApp: Identifiable, Equatable {
    let id: String              // Bundle ID (or "pid:<pid>" fallback)
    let bundleID: String?
    let name: String
    let icon: NSImage
    let processObjectIDs: [AudioObjectID]

    static func == (lhs: ActiveAudioApp, rhs: ActiveAudioApp) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.processObjectIDs == rhs.processObjectIDs
    }
}

// MARK: - Per-Tap Real-Time DSP State

private final class TapDSPState {
    let targetGain = AtomicFloat(1.0)
    let peakLevel = AtomicFloat(0.0)
    // Owned exclusively by the real-time IOProc thread while the IOProc is running.
    let currentGainPtr: UnsafeMutablePointer<Float>

    init(initialGain: Float) {
        currentGainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        currentGainPtr.initialize(to: initialGain)
        targetGain.store(initialGain)
    }

    deinit {
        currentGainPtr.deinitialize(count: 1)
        currentGainPtr.deallocate()
    }
}

private final class ManagedProcessTap {
    let appID: String
    var processObjectIDs: [AudioObjectID]
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID
    let dspState: TapDSPState

    init(
        appID: String,
        processObjectIDs: [AudioObjectID],
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        dspState: TapDSPState
    ) {
        self.appID = appID
        self.processObjectIDs = processObjectIDs
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.ioProcID = ioProcID
        self.dspState = dspState
    }

    deinit {
        // AudioDeviceStop blocks until any in-flight IOProc finishes before destroying the proc.
        AudioDeviceStop(aggregateDeviceID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// MARK: - Real-Time Audio DSP

/// Soft-knee hyperbolic tangent limiter.
/// Passes signals below `knee` untouched; smoothly saturates peaks above `knee` toward +/-1.0.
@inline(__always)
private func softLimitSample(_ sample: Float) -> Float {
    let knee: Float = 0.75
    let headroom: Float = 0.25 // 1.0 - knee
    let absVal = fabsf(sample)
    if absVal <= knee {
        return sample
    }
    let excess = (absVal - knee) / headroom
    let limited = knee + headroom * tanhf(excess)
    return copysignf(limited, sample)
}

private func processAudioBlock(
    inInputData: UnsafePointer<AudioBufferList>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    dsp: TapDSPState
) {
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    let outList = UnsafeMutableAudioBufferListPointer(outOutputData)

    guard outList.count > 0 else { return }

    // Zero all output buffers upfront so unmatched/surround channels stay silent.
    for i in 0..<outList.count {
        if let data = outList[i].mData {
            memset(data, 0, Int(outList[i].mDataByteSize))
        }
    }

    guard inList.count > 0, let firstInData = inList[0].mData else { return }

    let inChannels0 = max(1, Int(inList[0].mNumberChannels))
    let inFrames = Int(inList[0].mDataByteSize) / (MemoryLayout<Float>.size * inChannels0)

    let outChannels0 = max(1, Int(outList[0].mNumberChannels))
    let outFrames = Int(outList[0].mDataByteSize) / (MemoryLayout<Float>.size * outChannels0)

    let frameCount = min(inFrames, outFrames)
    guard frameCount > 0 else { return }

    let startGain = dsp.currentGainPtr.pointee
    let endGain = dsp.targetGain.load()
    dsp.currentGainPtr.pointee = endGain

    let isRamping = fabsf(endGain - startGain) > 0.0001
    let needsLimiter = endGain > 1.001 || startGain > 1.001
    let gainStep = isRamping ? (endGain - startGain) / Float(frameCount) : 0.0

    let inPtr0 = firstInData.assumingMemoryBound(to: Float.self)
    let inIsInterleavedStereo = (inList.count == 1 && inChannels0 >= 2)
    let inIsDualMono = (inList.count >= 2 && inList[1].mData != nil)
    let inPtr1 = inIsDualMono ? inList[1].mData!.assumingMemoryBound(to: Float.self) : inPtr0

    let outIsInterleaved = (outList.count == 1 && outChannels0 >= 2)
    let outIsDualMono = (outList.count >= 2 && outList[1].mData != nil)
    guard let firstOutData = outList[0].mData else { return }
    let outPtr0 = firstOutData.assumingMemoryBound(to: Float.self)
    let outPtr1 = outIsDualMono ? outList[1].mData!.assumingMemoryBound(to: Float.self) : outPtr0

    var blockPeak: Float = 0.0

    // Fast SIMD path via Accelerate when gain is static and <= 1.0, and layout matches 1:1.
    if !isRamping && !needsLimiter && inIsInterleavedStereo && outIsInterleaved && inChannels0 == 2 && outChannels0 == 2 {
        var g = endGain
        let sampleCount = vDSP_Length(frameCount * 2)
        vDSP_vsmul(inPtr0, 1, &g, outPtr0, 1, sampleCount)
        vDSP_maxmgv(outPtr0, 1, &blockPeak, sampleCount)
        dsp.peakLevel.storeMax(blockPeak)
        return
    }

    for frame in 0..<frameCount {
        let g = isRamping ? (startGain + gainStep * Float(frame)) : endGain

        let rawL: Float
        let rawR: Float
        if inIsInterleavedStereo {
            let base = frame * inChannels0
            rawL = inPtr0[base]
            rawR = inPtr0[base + 1]
        } else if inIsDualMono {
            rawL = inPtr0[frame]
            rawR = inPtr1[frame]
        } else {
            let mono = inPtr0[frame * inChannels0]
            rawL = mono
            rawR = mono
        }

        var l = rawL * g
        var r = rawR * g

        if needsLimiter {
            l = softLimitSample(l)
            r = softLimitSample(r)
        }

        let absL = fabsf(l)
        let absR = fabsf(r)
        if absL > blockPeak { blockPeak = absL }
        if absR > blockPeak { blockPeak = absR }

        if outIsInterleaved {
            let base = frame * outChannels0
            outPtr0[base] = l
            outPtr0[base + 1] = r
        } else if outIsDualMono {
            outPtr0[frame] = l
            outPtr1[frame] = r
        } else {
            outPtr0[frame] = 0.5 * (l + r)
        }
    }

    dsp.peakLevel.storeMax(blockPeak)
}

// MARK: - CoreAudio Tap Engine

@available(macOS 14.2, *)
final class AudioTapEngine {
    var onAppsChanged: (([ActiveAudioApp]) -> Void)?
    var onError: ((String?) -> Void)?
    var initialGainProvider: ((String) -> Float)?

    private let controlQueue = DispatchQueue(label: "com.soundboost.AudioTapEngine.control", qos: .userInitiated)
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private var activeApps: [ActiveAudioApp] = []
    private var activeTaps: [String: ManagedProcessTap] = [:]
    private var desiredGains: [String: Float] = [:]
    private var isBypassed: Bool = false

    private var currentOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var currentOutputDeviceUID: String?

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var processRunningListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    private var pendingRefreshWorkItem: DispatchWorkItem?

    func start() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.installSystemListeners()
            self.updateDefaultOutputDevice()
            self.refreshProcessesAndTaps()
        }
    }

    func stop() {
        controlQueue.sync {
            pendingRefreshWorkItem?.cancel()
            pendingRefreshWorkItem = nil
            removeSystemListeners()
            removeAllProcessListeners()
            activeTaps.removeAll()
        }
    }

    func setBypass(_ bypassed: Bool) {
        controlQueue.async { [weak self] in
            guard let self, self.isBypassed != bypassed else { return }
            self.isBypassed = bypassed
            if bypassed {
                self.activeTaps.removeAll()
                self.desiredGains.removeAll()
            } else {
                self.refreshProcessesAndTaps()
            }
        }
    }

    func setGain(_ gain: Float, forAppID appID: String) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            let clamped = max(0.0, min(4.0, gain))
            self.desiredGains[appID] = clamped
            if let tap = self.activeTaps[appID] {
                tap.dspState.targetGain.store(clamped)
            }
        }
    }

    func resetAllGains() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            for key in self.desiredGains.keys {
                self.desiredGains[key] = 1.0
            }
            for tap in self.activeTaps.values {
                tap.dspState.targetGain.store(1.0)
            }
        }
    }

    /// Thread-safe poll for UI meters. Returns peak amplitude per app ID and resets the latch.
    func readAndResetPeaks() -> [String: Float] {
        var result: [String: Float] = [:]
        controlQueue.sync {
            for (appID, tap) in activeTaps {
                result[appID] = tap.dspState.peakLevel.exchange(0.0)
            }
        }
        return result
    }

    // MARK: - Listeners

    private func installSystemListeners() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        var processListAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let procBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        processListListener = procBlock
        AudioObjectAddPropertyListenerBlock(systemObj, &processListAddr, controlQueue, procBlock)

        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChanged()
        }
        defaultOutputListener = outBlock
        AudioObjectAddPropertyListenerBlock(systemObj, &defaultOutAddr, controlQueue, outBlock)
    }

    private func removeSystemListeners() {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)

        if let procBlock = processListListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObj, &addr, controlQueue, procBlock)
            processListListener = nil
        }

        if let outBlock = defaultOutputListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObj, &addr, controlQueue, outBlock)
            defaultOutputListener = nil
        }
    }

    private func syncProcessRunningListeners(allProcessObjects: [AudioObjectID]) {
        let currentSet = Set(allProcessObjects)

        for (objID, block) in processRunningListeners where !currentSet.contains(objID) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(objID, &addr, controlQueue, block)
            processRunningListeners.removeValue(forKey: objID)
        }

        for objID in allProcessObjects where processRunningListeners[objID] == nil {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleRefresh()
            }
            if AudioObjectAddPropertyListenerBlock(objID, &addr, controlQueue, block) == noErr {
                processRunningListeners[objID] = block
            }
        }
    }

    private func removeAllProcessListeners() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for (objID, block) in processRunningListeners {
            AudioObjectRemovePropertyListenerBlock(objID, &addr, controlQueue, block)
        }
        processRunningListeners.removeAll()
    }

    private func scheduleRefresh() {
        pendingRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshProcessesAndTaps()
        }
        pendingRefreshWorkItem = work
        controlQueue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: - Device & Process Discovery

    private func handleDefaultOutputDeviceChanged() {
        let oldUID = currentOutputDeviceUID
        updateDefaultOutputDevice()
        if oldUID != currentOutputDeviceUID {
            // Rebuild aggregate devices against the new output hardware.
            activeTaps.removeAll()
            refreshProcessesAndTaps()
        }
    }

    private func updateDefaultOutputDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            currentOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
            currentOutputDeviceUID = nil
            return
        }
        currentOutputDeviceID = deviceID
        currentOutputDeviceUID = readStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func refreshProcessesAndTaps() {
        let allProcessObjects = readProcessObjectList()
        syncProcessRunningListeners(allProcessObjects: allProcessObjects)

        struct GroupedApp {
            let id: String
            let bundleID: String?
            let name: String
            let icon: NSImage
            var objectIDs: [AudioObjectID]
        }

        var grouped: [String: GroupedApp] = [:]

        for objID in allProcessObjects {
            guard readUInt32Property(objectID: objID, selector: kAudioProcessPropertyIsRunningOutput) == 1 else {
                continue
            }
            let pid = pid_t(readInt32Property(objectID: objID, selector: kAudioProcessPropertyPID) ?? -1)
            guard pid > 0, pid != selfPID else { continue }

            let processBundleID = readStringProperty(objectID: objID, selector: kAudioProcessPropertyBundleID)
            let resolved = resolveOwnerApp(pid: pid, fallbackBundleID: processBundleID)

            if var existing = grouped[resolved.id] {
                existing.objectIDs.append(objID)
                grouped[resolved.id] = existing
            } else {
                grouped[resolved.id] = GroupedApp(
                    id: resolved.id,
                    bundleID: resolved.bundleID,
                    name: resolved.name,
                    icon: resolved.icon,
                    objectIDs: [objID]
                )
            }
        }

        let discovered = grouped.values
            .map {
                ActiveAudioApp(
                    id: $0.id,
                    bundleID: $0.bundleID,
                    name: $0.name,
                    icon: $0.icon,
                    processObjectIDs: $0.objectIDs.sorted()
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if discovered != activeApps {
            activeApps = discovered
            let callback = onAppsChanged
            DispatchQueue.main.async {
                callback?(discovered)
            }
        }

        syncTaps(for: discovered)
    }

    private func syncTaps(for apps: [ActiveAudioApp]) {
        guard !isBypassed else {
            if !activeTaps.isEmpty {
                activeTaps.removeAll()
            }
            return
        }

        guard let outputUID = currentOutputDeviceUID,
              currentOutputDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            activeTaps.removeAll()
            return
        }

        let activeIDs = Set(apps.map(\.id))

        // Tear down taps for apps that stopped outputting audio.
        for id in activeTaps.keys where !activeIDs.contains(id) {
            activeTaps.removeValue(forKey: id)
        }

        var lastErrorMessage: String?

        for app in apps {
            if let existing = activeTaps[app.id], existing.processObjectIDs == app.processObjectIDs {
                continue
            }

            // Replace if helper PIDs changed, or create fresh tap.
            activeTaps.removeValue(forKey: app.id)

            let initialGain = desiredGains[app.id] ?? initialGainProvider?(app.id) ?? 1.0
            desiredGains[app.id] = initialGain

            do {
                let tap = try createManagedTap(
                    appID: app.id,
                    processObjectIDs: app.processObjectIDs,
                    outputDeviceUID: outputUID,
                    initialGain: initialGain
                )
                activeTaps[app.id] = tap
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }

        let errorCallback = onError
        DispatchQueue.main.async {
            errorCallback?(lastErrorMessage)
        }
    }

    private func createManagedTap(
        appID: String,
        processObjectIDs: [AudioObjectID],
        outputDeviceUID: String,
        initialGain: Float
    ) throws -> ManagedProcessTap {
        let tapUUID = UUID()
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDesc.uuid = tapUUID
        tapDesc.name = "SoundBoost Tap (\(appID))"
        tapDesc.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(tapStatus),
                userInfo: [NSLocalizedDescriptionKey: "Audio Capture permission required or tap creation failed (OSStatus \(tapStatus))."]
            )
        }

        let aggUID = "com.soundboost.agg.\(UUID().uuidString)"
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundBoost Aggregate (\(appID))",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggDeviceID)
        guard aggStatus == noErr, aggDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(aggStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate output device (OSStatus \(aggStatus))."]
            )
        }

        let dspState = TapDSPState(initialGain: initialGain)
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggDeviceID, nil) { _, inInputData, _, outOutputData, _ in
            processAudioBlock(inInputData: inInputData, outOutputData: outOutputData, dsp: dspState)
        }

        guard ioStatus == noErr, let validProcID = ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(ioStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to attach real-time IOProc (OSStatus \(ioStatus))."]
            )
        }

        let startStatus = AudioDeviceStart(aggDeviceID, validProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggDeviceID, validProcID)
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(startStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to start aggregate device (OSStatus \(startStatus))."]
            )
        }

        return ManagedProcessTap(
            appID: appID,
            processObjectIDs: processObjectIDs,
            tapID: tapID,
            aggregateDeviceID: aggDeviceID,
            ioProcID: validProcID,
            dspState: dspState
        )
    }

    // MARK: - Process Resolution Helpers

    private func resolveOwnerApp(pid: pid_t, fallbackBundleID: String?) -> (id: String, bundleID: String?, name: String, icon: NSImage) {
        // Walk up process tree to attribute WebKit/Chrome/Electron helpers to their host GUI app.
        var cursorPID = pid
        for _ in 0..<5 {
            if let runningApp = NSRunningApplication(processIdentifier: cursorPID),
               runningApp.activationPolicy != .prohibited {
                let bid = runningApp.bundleIdentifier ?? fallbackBundleID
                let name = runningApp.localizedName ?? bid ?? "App (\(cursorPID))"
                let icon = runningApp.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
                return (bid ?? "pid:\(cursorPID)", bid, name, icon)
            }
            guard let parent = parentPID(of: cursorPID), parent > 1, parent != cursorPID else {
                break
            }
            cursorPID = parent
        }

        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            let bid = runningApp.bundleIdentifier ?? fallbackBundleID
            let name = runningApp.localizedName ?? bid ?? "Process \(pid)"
            let icon = runningApp.icon ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
            return (bid ?? "pid:\(pid)", bid, name, icon)
        }

        let cleanName = fallbackBundleID?.components(separatedBy: ".").last ?? "Audio Process \(pid)"
        let fallbackIcon = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
        return (fallbackBundleID ?? "pid:\(pid)", fallbackBundleID, cleanName, fallbackIcon)
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - CoreAudio Property Readers

    private func readProcessObjectList() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr else {
            return []
        }
        return list
    }

    private func readUInt32Property(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readInt32Property(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Int32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func readStringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &cfStr) == noErr,
              let retained = cfStr?.takeRetainedValue() else {
            return nil
        }
        return retained as String
    }
}
