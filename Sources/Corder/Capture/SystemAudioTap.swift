import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// System-audio capture via a Core Audio **process tap** (macOS 14.4+).
///
/// Why this exists: SCStream's `capturesAudio` taps the system *output
/// mix*. Communication apps (Zoom, Meet, Telegram, Discord, …) render
/// their call audio through a Voice-Processing I/O unit for echo
/// cancellation, and that path bypasses the mix SCStream taps — so on
/// a real call SCStream delivers digital silence for the remote
/// participants. A process tap reads each process's audio directly
/// (the same mechanism Granola / Loom use), which captures call audio
/// correctly.
///
/// Design: build a global tap that excludes our own process (so we
/// don't record Corder's own UI sounds / the meeting blob), wrap it in
/// a private aggregate device, and run an IOProc that hands every
/// buffer to `onAudio`. The tap is created `.unmuted` so the user
/// still hears the call while we record it.
final class SystemAudioTap {

    /// Delivered on the IOProc's dispatch queue. The buffer's format is
    /// `format` (see below); the callee copies what it needs and must
    /// not retain the buffer past the call. The second argument is the
    /// buffer's mach host time (`AudioTimeStamp.mHostTime`), sampled in the
    /// IOProc — the ONLY place it's available, since the PCM buffer carries
    /// no timestamp and the main-actor hop adds skew. The writer uses it to
    /// left-pad system.wav to the recording's start clock.
    var onAudio: ((AVAudioPCMBuffer, UInt64) -> Void)?

    /// Format of the tapped stream, valid only after a successful
    /// `start()`. Used by the caller to open the destination WAV.
    private(set) var format: AVAudioFormat?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.3mpq.corder.systemtap", qos: .userInitiated)

    // Self-heal watchdog. Confirmed failure mode (from the BT logs): the
    // tap + aggregate are created and `AudioDeviceStart` returns noErr, but
    // the IOProc NEVER fires — zero audio callbacks — when the Bluetooth
    // route is mid-switch (A2DP↔SCO) at create time. The whole session then
    // records system silence. We detect "no buffer within `watchdogDelay`"
    // and rebuild the tap from scratch, up to `maxRestarts` times. In a
    // healthy start the first buffer arrives in ~100 ms, so the watchdog is
    // a no-op and the working (non-BT) path is untouched.
    private let stateLock = NSLock()
    private var gotFirstBuffer = false
    private var generation = 0
    private var restarts = 0
    private let maxRestarts = 4
    private let watchdogDelay: TimeInterval = 1.5
    private let watchdogQueue = DispatchQueue(label: "com.3mpq.corder.systemtap.watchdog")

    enum TapError: Error, LocalizedError {
        case createTap(OSStatus)
        case tapUID(OSStatus)
        case tapFormat(OSStatus)
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case startDevice(OSStatus)

        var errorDescription: String? {
            switch self {
            case .createTap(let s):       return "AudioHardwareCreateProcessTap failed (\(s))"
            case .tapUID(let s):          return "read kAudioTapPropertyUID failed (\(s))"
            case .tapFormat(let s):       return "read kAudioTapPropertyFormat failed (\(s))"
            case .createAggregate(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .createIOProc(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .startDevice(let s):     return "AudioDeviceStart failed (\(s))"
            }
        }
    }

    func start() throws {
        stateLock.lock()
        gotFirstBuffer = false
        restarts = 0
        generation += 1
        let gen = generation
        stateLock.unlock()
        try buildAndStart()
        armWatchdog(generation: gen)
    }

    /// Arm (or re-arm) the no-audio watchdog for this generation. If no
    /// IOProc buffer has arrived by `watchdogDelay`, tear the tap down and
    /// rebuild it — the BT-mid-switch start race recovers on a fresh build.
    private func armWatchdog(generation gen: Int) {
        watchdogQueue.asyncAfter(deadline: .now() + watchdogDelay) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let stale = gen != self.generation          // a stop()/restart superseded us
            let healthy = self.gotFirstBuffer
            let canRetry = self.restarts < self.maxRestarts
            if stale || healthy { self.stateLock.unlock(); return }
            if !canRetry {
                self.stateLock.unlock()
                FileLogger.log("SystemAudioTap: still no audio after \(self.maxRestarts) restarts — giving up (BT route likely in HFP/SCO; remote side not capturable).")
                return
            }
            self.restarts += 1
            let attempt = self.restarts
            self.stateLock.unlock()
            FileLogger.log("SystemAudioTap: no IOProc audio within \(self.watchdogDelay)s — rebuilding tap (attempt \(attempt)/\(self.maxRestarts)).")
            TelemetryService.bump(.tapRebuilds)
            self.teardownCoreAudio()
            do {
                try self.buildAndStart()
                self.armWatchdog(generation: gen)
            } catch {
                FileLogger.log("SystemAudioTap: rebuild failed: \(error.localizedDescription)")
            }
        }
    }

    /// Destroy just the Core Audio objects (IOProc, aggregate, tap) without
    /// touching `onAudio` / watchdog state — used by both `stop()` and the
    /// watchdog rebuild.
    private func teardownCoreAudio() {
        if let proc = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func buildAndStart() throws {
        // 1. Our own process's audio object — so we can exclude it from
        //    the global tap (don't record Corder's own output).
        let ourObject = Self.processObject(forPID: getpid())

        // 2. Tap description: everything EXCEPT us, stereo, left
        //    unmuted so the user keeps hearing the call.
        let desc: CATapDescription
        if ourObject != AudioObjectID(kAudioObjectUnknown) {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ourObject])
        } else {
            // Couldn't resolve our object — fall back to a full global
            // mixdown. Worst case we also record our own blip sounds,
            // which is far better than missing the call audio.
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        desc.name = "Corder System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
        guard tapStatus == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.createTap(tapStatus)
        }
        tapID = newTap

        // 3. Read the tap UID + format.
        let uid = try Self.stringProperty(tapID, kAudioTapPropertyUID, TapError.tapUID)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let fmtStatus = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &asbdSize, &asbd)
        guard fmtStatus == noErr else { throw TapError.tapFormat(fmtStatus) }
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.tapFormat(-1)
        }
        self.format = avFormat

        // 4. Private aggregate device wrapping the tap. Private => not
        //    persisted, not shown to the user, torn down with us.
        let aggUID = "com.3mpq.Corder.aggregate.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Corder Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: uid,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg)
        guard aggStatus == noErr, newAgg != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.createAggregate(aggStatus)
        }
        aggregateID = newAgg

        // 5. IOProc — copy the input AudioBufferList into an
        //    AVAudioPCMBuffer and hand it off.
        let fmt = avFormat
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, ioQueue
        ) { [weak self] inNow, inInputData, inInputTime, _, _ in
            guard let self = self, let onAudio = self.onAudio else { return }
            // mHostTime of THIS buffer's input (mach host clock). Fall back to
            // `inNow` if the input timestamp's host time is missing. Reported
            // up so CaptureEngine can diff it against the recording-start clock
            // — done per buffer (cheap), the writer only uses the first one.
            var hostTime = inInputTime.pointee.mHostTime
            if hostTime == 0 { hostTime = inNow.pointee.mHostTime }
            let abl = inInputData.pointee
            guard abl.mNumberBuffers > 0 else { return }
            let firstBuf = withUnsafePointer(to: inInputData.pointee.mBuffers) { $0.pointee }
            let bytesPerFrame = max(1, fmt.streamDescription.pointee.mBytesPerFrame)
            let frameCount = firstBuf.mDataByteSize / bytesPerFrame
            guard frameCount > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return }
            pcm.frameLength = frameCount
            // Copy each buffer in the list into the PCM buffer's
            // matching channel/segment. For interleaved float this is
            // a single buffer; for non-interleaved it's one per channel.
            let srcList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            let dstList = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for i in 0..<min(srcList.count, dstList.count) {
                if let src = srcList[i].mData, let dst = dstList[i].mData {
                    memcpy(dst, src, Int(min(srcList[i].mDataByteSize, dstList[i].mDataByteSize)))
                }
            }
            // Mark the tap healthy on the first delivered buffer so the
            // watchdog stands down (and log it once for diagnostics).
            self.stateLock.lock()
            let firstTime = !self.gotFirstBuffer
            self.gotFirstBuffer = true
            self.stateLock.unlock()
            if firstTime { FileLogger.log("SystemAudioTap: first IOProc buffer (\(frameCount) frames) — tap healthy.") }
            onAudio(pcm, hostTime)
        }
        guard procStatus == noErr, let proc = procID else {
            throw TapError.createIOProc(procStatus)
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else { throw TapError.startDevice(startStatus) }
        FileLogger.log("SystemAudioTap: started (\(avFormat.sampleRate) Hz, \(avFormat.channelCount) ch)")
    }

    func stop() {
        // Supersede any pending watchdog: bumping the generation makes the
        // scheduled check see itself as stale and bail.
        stateLock.lock()
        generation += 1
        stateLock.unlock()
        // Serialise teardown on the watchdog queue so it can't race a
        // concurrent watchdog rebuild mutating the same Core Audio objects.
        watchdogQueue.sync { teardownCoreAudio() }
        onAudio = nil
        FileLogger.log("SystemAudioTap: stopped")
    }

    // MARK: - Core Audio helpers

    private static func processObject(forPID pid: pid_t) -> AudioObjectID {
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        return status == noErr ? objectID : AudioObjectID(kAudioObjectUnknown)
    }

    private static func stringProperty(_ object: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector,
                                       _ wrap: (OSStatus) -> TapError) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw wrap(status) }
        return cf as String
    }

    /// True when the system's default OUTPUT device is a Bluetooth
    /// route (AirPods / BT headset). A Core Audio process tap captures
    /// silence in that case — the audio is rendered to the BT device
    /// the global tap can't see — so the remote side of a call never
    /// makes it into system.wav. We use this only to warn the user;
    /// it never blocks recording.
    static func defaultOutputIsBluetooth() -> Bool {
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var devSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &devAddr, 0, nil, &devSize, &dev) == noErr,
              dev != AudioObjectID(kAudioObjectUnknown) else { return false }

        var trAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var trSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &trAddr, 0, nil, &trSize, &transport) == noErr
        else { return false }

        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
