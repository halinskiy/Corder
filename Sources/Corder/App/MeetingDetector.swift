import AppKit
import CoreAudio
import Foundation

/// Watches the system for the start of a videoconference call. When
/// it detects one, asks the user via `MeetingInvitePanel` whether to
/// start recording.
///
/// Two signals combined keep the detector quiet:
///   1. A known meeting app is running (Zoom / Teams / Meet / Slack / …).
///   2. *Some other process* has just opened the default input device.
///
/// Either alone is too noisy — Zoom running with no call open, or any
/// app casually touching the mic for a UI sound. Together they map
/// reliably onto "someone just joined a call".
///
/// The detector triggers on the *rising edge* of (1) ∧ (2), and remembers
/// which apps it already offered for so a single sustained call never
/// re-prompts. Quitting the meeting app clears the per-app guard so the
/// next launch counts as a new meeting.
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()
    private init() {}

    private var timer: Timer?
    /// Bundles we've already offered to record this session. Cleared
    /// per-tick for apps that have quit, so reopening Zoom for a new
    /// call gets a fresh offer.
    private var offeredFor: Set<String> = []
    /// Bundle id of the currently-open invite. Cleared when the user
    /// accepts or dismisses.
    private var pendingInviteFor: String?
    /// When the default-input device first became claimed by some
    /// process. `nil` means the mic is idle. The trigger fires on the
    /// rising edge of this becoming non-nil; we record the edge
    /// timestamp in `lastTriggerMicBusyEdge` so a long call doesn't
    /// re-trigger every tick.
    private var inputBusySince: Date?
    private var lastTriggerMicBusyEdge: Date?

    /// Bundle id → human-readable app name shown in the invite, in
    /// priority order. The first matching running app wins when
    /// multiple meeting apps are open at once (Slack and Zoom both
    /// running ⇒ pick Zoom — more likely the actual call host).
    private static let knownApps: [(bundle: String, name: String)] = [
        ("us.zoom.xos",                  "Zoom"),
        ("com.microsoft.teams2",         "Teams"),
        ("com.microsoft.teams",          "Teams"),
        ("com.cisco.webexmeetingsapp",   "Webex"),
        ("com.google.GoogleMeet",        "Google Meet"),
        ("com.tinyspeck.slackmacgap",    "Slack"),
        ("com.hnc.Discord",              "Discord"),
        ("com.skype.skype",              "Skype"),
        ("ru.yandex.desktop.yatelemost", "Я.Телемост"),
        // Browsers — sit at the bottom of the priority list. A dedicated
        // meeting app holding the mic always wins; the browser branch
        // catches web-hosted calls (Meet in a tab, Whereby, Around,
        // Tuple, Discord web, Telegram web, Slack huddle in browser).
        // False-positive risk is low because we gate on the system
        // input device being actively claimed for ≥3 s — a browser
        // sitting open with no call doesn't trip the detector.
        ("ai.perplexity.comet",          "Comet"),
        ("com.google.Chrome",            "Chrome"),
        ("company.thebrowser.Browser",   "Arc"),
        ("com.brave.Browser",            "Brave"),
        ("com.microsoft.edgemac",        "Edge"),
        ("com.apple.Safari",             "Safari"),
        ("org.mozilla.firefox",          "Firefox"),
        ("com.vivaldi.Vivaldi",          "Vivaldi"),
        ("com.operasoftware.Opera",      "Opera"),
    ]

    func start() {
        stop()
        // 4 s tick (was 2 s) — meetings don't appear in single-digit
        // milliseconds, and each tick pulls the full running-apps list
        // from AppKit, which is not free. `tolerance` lets macOS coalesce
        // ticks with other timers to save battery.
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 1.0
        FileLogger.log("MeetingDetector: started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manual recording start path (menu bar) calls this so any pending
    /// invite is cleared and we don't show a stale offer after the user
    /// already kicked things off themselves.
    func userStartedRecordingManually() {
        if let pending = pendingInviteFor {
            offeredFor.insert(pending)
        }
        pendingInviteFor = nil
        MeetingInvitePanel.shared.hide(animated: false)
    }

    private func tick() {
        // Don't poll during our own recording or the stopping handoff —
        // CaptureEngine is the process holding the mic right now, and we
        // already know about the meeting.
        switch AppContext.shared.recordingState {
        case .recording, .stopping: return
        case .idle: break
        }

        // Gate on a meeting app being running FIRST — if nothing of
        // interest is open, skip the CoreAudio device query entirely.
        // The mic check is the only part of the tick that touches
        // hardware and it's wasted work when there's no candidate
        // app to attribute a busy mic to anyway.
        let runningBundles = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        offeredFor = offeredFor.filter { runningBundles.contains($0) }

        let hasMeetingAppRunning = Self.knownApps.contains(where: { runningBundles.contains($0.bundle) })
        let now = Date()
        if hasMeetingAppRunning {
            let busy = Self.isInputDeviceClaimedByOtherProcess()
            if busy {
                if inputBusySince == nil { inputBusySince = now }
            } else {
                inputBusySince = nil
            }
        } else {
            // No candidate app → don't even ask CoreAudio. Reset the
            // busy-edge so a future genuine call still triggers.
            inputBusySince = nil
        }

        if pendingInviteFor != nil { return }

        // Need a sustained mic-busy state (3 s) — filters "checking
        // my mic" + UI alert sounds that briefly open the device.
        guard let since = inputBusySince,
              now.timeIntervalSince(since) >= 3,
              lastTriggerMicBusyEdge != since
        else { return }

        guard let match = Self.knownApps.first(where: { runningBundles.contains($0.bundle) }),
              !offeredFor.contains(match.bundle)
        else {
            // No interesting candidate this edge. Mark the edge consumed
            // so we don't re-check the same busy span every tick — a
            // genuinely-new edge needs the mic to go idle first.
            lastTriggerMicBusyEdge = since
            return
        }

        lastTriggerMicBusyEdge = since
        offeredFor.insert(match.bundle)
        pendingInviteFor = match.bundle
        FileLogger.log("MeetingDetector: offering record for \(match.name)")
        MeetingInvitePanel.shared.show(
            appName: match.name,
            onAccept: { [weak self] in
                self?.pendingInviteFor = nil
                Task { @MainActor in
                    // Seed expectedOtherSpeakers=1 for auto-detected calls
                    // so Gemini's diarization doesn't fan a single
                    // interlocutor out into 4-5 phantom speakers. The
                    // clarify banner is still available for the rare
                    // 3-way / group-call case.
                    await RecordingController.shared.startRecording(
                        source: .fullDisplay,
                        expectedOtherSpeakers: 1
                    )
                }
            },
            onDismiss: { [weak self] in
                self?.pendingInviteFor = nil
            }
        )
    }

    /// True iff some process has the default input device live. We don't
    /// distinguish processes here — the caller gates on `recordingState`
    /// to make sure Corder itself isn't the one holding the device.
    private static func isInputDeviceClaimedByOtherProcess() -> Bool {
        var device: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let s1 = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size, &device)
        guard s1 == noErr, device != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let s2 = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        return s2 == noErr && running != 0
    }
}
