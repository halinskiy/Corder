import Foundation
import CoreAudio
import AVFoundation

/// Enumerate microphone-class Core Audio devices and apply a chosen
/// one to an `AVAudioEngine` instance via its private input unit.
///
/// Why this exists: `AVAudioEngine.inputNode` is implicitly bound to
/// the *system default input*. There's no public Swift API to swap
/// devices, you have to reach the underlying AUHAL (`audioUnit`) and
/// set `kAudioOutputUnitProperty_CurrentDevice` to the chosen
/// `AudioDeviceID`. This is documented for macOS but only works on
/// AUHAL units (i.e. AVAudioEngine on macOS, same call won't work
/// on iOS, which is fine because we're a Mac-only target).
///
/// Stability rule we obey here: we identify devices by their **UID**
/// (`kAudioDevicePropertyDeviceUID`), not by the numeric `AudioDeviceID`.
/// macOS re-issues the numeric id on every reboot/replug; the UID
/// stays the same. UserDefaults stores the UID; we resolve it back
/// to a live `AudioDeviceID` at the moment of recording. If the saved
/// UID can't be found (device unplugged), we fall back to the
/// system default and log it.
enum AudioInputDevices {

    /// One discoverable microphone-class device.
    struct Info {
        /// Stable, persisted across reboots & replug events.
        let uid: String
        /// Human-readable name as shown in System Settings → Sound.
        let name: String
        /// Manufacturer ("Apple Inc.", "Logitech, Inc.", ...), optional
        /// because not every aggregate or virtual device sets it.
        let manufacturer: String?
        /// Transport ("BuiltIn", "USB", "Bluetooth", "Virtual",
        /// "Aggregate", "Continuity"...), gives the UI an icon hint.
        let transport: String?
        /// True if the OS currently treats this as the default input.
        /// Useful so the picker can mark "(system default)" next to it.
        let isSystemDefault: Bool
    }

    // MARK: - Enumeration

    /// Returns every device with at least one input channel, sorted
    /// to put the current system default first, then alphabetically.
    /// Output-only devices (most speakers / headphones-as-output) are
    /// filtered out by inspecting the input scope's stream config.
    static func list() -> [Info] {
        let defaultId = systemDefaultInputDeviceID()
        let ids = allDeviceIDs()
        var out: [Info] = []
        for id in ids {
            guard hasInputChannel(deviceID: id) else { continue }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { continue }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Unknown"
            let manu = stringProperty(id, kAudioObjectPropertyManufacturer)
            let transport = transportType(deviceID: id)
            out.append(Info(
                uid: uid,
                name: name,
                manufacturer: manu?.isEmpty == false ? manu : nil,
                transport: transport,
                isSystemDefault: id == defaultId
            ))
        }
        out.sort { a, b in
            if a.isSystemDefault != b.isSystemDefault { return a.isSystemDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return out
    }

    /// One-line snapshot of the current system default input, for start-up
    /// diagnostics (so a "recorded from the wrong mic" report is debuggable
    /// from the log alone).
    static func defaultInputSummary() -> String {
        guard let d = list().first(where: { $0.isSystemDefault }) else { return "none" }
        return "\(d.name) [\(d.transport ?? "?")]"
    }

    /// The Mac's built-in microphone, the always-reliable fallback when a
    /// finicky BT headset mic makes AVAudioEngine throw -10868 forever.
    static func builtInInput() -> Info? {
        return list().first(where: { $0.transport == "BuiltIn" })
    }

    // MARK: - Apply to AVAudioEngine

    /// Set the AVAudioEngine input node to read from the device whose
    /// UID matches `uid`. Returns the resolved live `AudioDeviceID`
    /// on success, `nil` if the UID doesn't match any currently
    /// connected device (caller should leave the engine on system
    /// default and surface a log line / future toast).
    ///
    /// Call this BEFORE `engine.prepare()` / `engine.start()`, once
    /// the unit is initialised, swapping device requires a stop/start
    /// cycle which we don't do mid-recording (yet).
    @discardableResult
    static func apply(uid: String, to engine: AVAudioEngine) -> AudioDeviceID? {
        guard !uid.isEmpty,
              let deviceID = resolveDeviceID(forUID: uid) else { return nil }
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr ? deviceID : nil
    }

    /// Look up the live `AudioDeviceID` for a saved UID. Returns
    /// `nil` if the device isn't currently connected.
    static func resolveDeviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allDeviceIDs() {
            if stringProperty(id, kAudioDevicePropertyDeviceUID) == uid { return id }
        }
        return nil
    }

    // MARK: - Core Audio plumbing

    /// Mutable address used to query global-scope properties on the
    /// hardware aggregate object. Element is always 0 / main.
    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids)
        guard getStatus == noErr else { return [] }
        return ids
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    /// True if the device exposes at least one input channel in its
    /// input scope. Speakers / output-only devices return false here
    /// and we drop them from the picker.
    private static func hasInputChannel(deviceID: AudioDeviceID) -> Bool {
        var addr = address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioDevicePropertyScopeInput
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID, &addr, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return false }
        let bufList = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: Int(size))
        defer { bufList.deallocate() }
        let getStatus = AudioObjectGetPropertyData(
            deviceID, &addr, 0, nil, &size, bufList)
        guard getStatus == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(bufList)
        var channels: UInt32 = 0
        for buf in buffers { channels += buf.mNumberChannels }
        return channels > 0
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var dataSize: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(dataSize)) { rawPtr in
                AudioObjectGetPropertyData(id, &addr, 0, nil, &dataSize, rawPtr)
            }
        }
        guard status == noErr, let cf = cfStr else { return nil }
        return cf as String
    }

    /// Map the numeric `kAudioDevicePropertyTransportType` constant to
    /// a short string we can render as an icon hint in the picker
    /// (mic vs headphones vs USB vs bluetooth dot). Returns nil if
    /// the device doesn't report a known transport.
    private static func transportType(deviceID: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &addr, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:      return "BuiltIn"
        case kAudioDeviceTransportTypeUSB:          return "USB"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:  return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI:         return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort:  return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay:      return "AirPlay"
        case kAudioDeviceTransportTypeAVB:          return "AVB"
        case kAudioDeviceTransportTypeThunderbolt:  return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual:      return "Virtual"
        case kAudioDeviceTransportTypeAggregate:    return "Aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "Continuity"
        default: return nil
        }
    }
}

// MARK: - Cached enumeration (server hot path)
//
// A full CoreAudio walk can block for SECONDS while a Bluetooth headset is
// connected (property reads round-trip the BT stack), and /api/settings ran
// it on every call while the UI polls settings every 4s. The server spent
// ~4s per request, the WKWebView's per-host connection pool filled with
// stacked polls, and the <audio> element's request never got a slot: Play
// did nothing (2026-08-31). The settings route now serves this cached
// snapshot instantly; the walk happens OFF the request thread.
extension AudioInputDevices {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedInfos: [Info] = []
    nonisolated(unsafe) private static var cacheFetchedAt: Date? = nil
    nonisolated(unsafe) private static var cacheRefreshing = false
    private static let cacheTTL: TimeInterval = 20

    /// Never blocks: returns the last snapshot (possibly empty right after
    /// launch, `warmCache()` at server start closes that window) and kicks a
    /// background refresh when the snapshot is older than `cacheTTL`.
    static func cachedList() -> [Info] {
        cacheLock.lock()
        let stale = cacheFetchedAt.map { Date().timeIntervalSince($0) > cacheTTL } ?? true
        let snapshot = cachedInfos
        let kick = stale && !cacheRefreshing
        if kick { cacheRefreshing = true }
        cacheLock.unlock()
        if kick {
            DispatchQueue.global(qos: .utility).async {
                let fresh = list()
                cacheLock.lock()
                cachedInfos = fresh
                cacheFetchedAt = Date()
                cacheRefreshing = false
                cacheLock.unlock()
            }
        }
        return snapshot
    }

    /// Fire the first background walk early (server start) so the first
    /// /api/settings call already has real devices to serve.
    static func warmCache() { _ = cachedList() }
}
