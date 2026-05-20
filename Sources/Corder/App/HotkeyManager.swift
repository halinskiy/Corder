import AppKit
import Carbon.HIToolbox

/// One global hotkey (Carbon `RegisterEventHotKey`) that toggles
/// recording. Carbon is the right tool here: it's the standard
/// menu-bar-app global-hotkey API, works with the app unfocused, and
/// needs NO Accessibility permission (an `NSEvent` global monitor would
/// need one and still couldn't swallow the key).
///
/// Conflict reality: macOS exposes no registry of other apps' hotkeys,
/// and `RegisterEventHotKey` happily "succeeds" even when a *system*
/// shortcut already owns the combo (the system just eats the key
/// first). So real-world conflict handling is: (1) report whether
/// `RegisterEventHotKey` returned noErr at all (caught here, mirrored
/// via `HotkeyStatusSnapshot`), and (2) warn against a curated table of
/// well-known macOS system shortcuts (in `Routes`). We're honest in the
/// UI that a clashing *third-party* app can't be detected.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    /// Invoked on the main actor when the hotkey fires.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    // 'CORD' — distinguishes our hotkey in the shared dispatcher.
    private let signature: OSType = 0x434F5244

    /// Register (replacing any previous binding). `keyCode` is a Carbon
    /// virtual key code; `modifiers` a Carbon mask (cmdKey 256 |
    /// shiftKey 512 | optionKey 2048 | controlKey 4096). Returns whether
    /// the OS accepted it.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
        let ok = (status == noErr) && (ref != nil)
        if ok { hotKeyRef = ref }
        HotkeyStatusSnapshot.update(ok)
        FileLogger.log("HotkeyManager: register code=\(keyCode) mods=\(modifiers) → \(ok ? "ok" : "FAILED(\(status))")")
        return ok
    }

    func unregister() {
        if let r = hotKeyRef {
            UnregisterEventHotKey(r)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let mgr = Unmanaged<HotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                // Carbon dispatches on the main run loop already; hop
                // through the main actor anyway for state-safe UI work.
                Task { @MainActor in mgr.onTrigger?() }
                return noErr
            },
            1, &spec, selfPtr, &eventHandler)
    }
}
