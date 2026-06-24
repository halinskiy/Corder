import AppKit
import CoreAudio
import Foundation

/// Watches the system for the start of a videoconference call. When
/// it detects one, asks the user via the menu-bar popover
/// (`MenuBarController.showInviteOffer`) whether to start recording.
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
    /// Last `bundlesRunningInput` snapshot we logged. Field is only used
    /// for the diagnostic log in `tick()`; not part of the decision.
    private var lastLoggedOwners: Set<String> = []

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
        // Telegram on macOS ships under three bundle ids in the wild:
        // ru.keepcoder.Telegram (the native app most users have),
        // org.telegram.desktop (the cross-platform Telegram Desktop),
        // ph.telegra.Telegraph (the Mac App Store "Telegram Lite"
        // build). All three carry the same voice/video call surface.
        ("ru.keepcoder.Telegram",        "Telegram"),
        ("org.telegram.desktop",         "Telegram"),
        ("ph.telegra.Telegraph",         "Telegram"),
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
        MenuBarController.shared?.cancelInviteOffer()
    }

    private func tick() {
        // Skip the entire detector while the Welcome wizard is
        // unfinished. Offering a recording before setup is locked
        // would be misleading — the user can't accept (popover Start
        // is gated) and the prompt would just nag.
        guard AppSettings.onboardingCompleted else { return }

        // Don't poll during our own recording or the stopping handoff —
        // CaptureEngine is the process holding the mic right now, and we
        // already know about the meeting.
        switch AppContext.shared.recordingState {
        // `.preroll` too: Corder is already silently capturing this call and
        // an offer is up, so don't re-detect/re-offer.
        case .recording, .stopping, .preroll: return
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

        // Per-process mic ownership when the API is available (macOS
        // 14.4+); `nil` ⇒ fall back to the old coarse heuristic.
        let micOwners = Self.bundlesRunningInput()
        // Surface every mic owner to the Settings picker so the user can
        // white/blacklist an app by tapping it (no bundle-id typing).
        if let owners = micOwners { MicAppsSnapshot.update(Array(owners)) }
        // One-shot diagnostic: log when the mic-owners set CHANGES so we
        // can see what bundle ids the CoreAudio process list reports —
        // Electron / Chromium apps (Discord, Telegram, Comet) own the
        // mic via helper processes with bundle ids like
        // `com.hnc.Discord.helper.Renderer`, NOT the main bundle, which
        // breaks `owners.contains(app.bundle)` exact matching below.
        if let owners = micOwners, owners != lastLoggedOwners {
            lastLoggedOwners = owners
            FileLogger.log(
                "MeetingDetector: mic owners = [\(owners.sorted().joined(separator: ", "))]")
        }

        // Effective offer set = built-in known apps + the user's
        // whitelist, minus anything the user blacklisted. Blacklist wins
        // over everything — even a known app actively on the mic.
        let blacklist = Set(AppSettings.meetingBlacklist)
        var effectiveApps: [(bundle: String, name: String)] =
            Self.knownApps.filter { !blacklist.contains($0.bundle) }
        for b in AppSettings.meetingWhitelist
        where !blacklist.contains(b) && !effectiveApps.contains(where: { $0.bundle == b }) {
            let name = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == b })?.localizedName ?? b
            effectiveApps.append((bundle: b, name: name))
        }

        let now = Date()
        // Precise path: a candidate meeting app must ITSELF be the
        // process holding the mic. Loom/OBS/QuickTime/Terminal recording
        // while Zoom merely sits open in the background no longer trips
        // an offer. Fallback path keeps the original device-global gate.
        // Match rule: exact bundle id OR `<bundle>.<suffix>` — Electron
        // and Chromium apps (Discord, Telegram, Comet, Chrome) hold the
        // mic via helper processes whose bundle ids extend the main app
        // bundle (`com.hnc.Discord.helper.Renderer` etc.). Exact-match
        // missed every one of them.
        let ownerMatchesApp: (String, Set<String>) -> Bool = { bundle, owners in
            owners.contains(where: { $0 == bundle || $0.hasPrefix(bundle + ".") })
        }
        let micBusy: Bool
        if let owners = micOwners {
            micBusy = effectiveApps.contains {
                runningBundles.contains($0.bundle) && ownerMatchesApp($0.bundle, owners)
            }
        } else {
            let anyRunning = effectiveApps.contains { runningBundles.contains($0.bundle) }
            micBusy = anyRunning && Self.isInputDeviceClaimedByOtherProcess()
        }
        if micBusy {
            if inputBusySince == nil { inputBusySince = now }
        } else {
            // Mic just went idle → this voice session ended. Clear the
            // "already offered" set so the NEXT session (mic released
            // then re-claimed — e.g. the user dismissed with "Not now",
            // stopped talking, then started a new call/recording) gets
            // a fresh offer. Previously `offeredFor` only cleared when
            // the app fully quit, so a second session in the same app
            // never re-prompted.
            if inputBusySince != nil { offeredFor.removeAll() }
            inputBusySince = nil
        }

        if pendingInviteFor != nil { return }

        // Need a sustained mic-busy state (3 s) — filters "checking
        // my mic" + UI alert sounds that briefly open the device.
        guard let since = inputBusySince,
              now.timeIntervalSince(since) >= 3,
              lastTriggerMicBusyEdge != since
        else { return }

        // When per-process info is available the offered app must be the
        // one actually on the mic; without it, first running candidate
        // (original behaviour). Same prefix-match rule as `micBusy`.
        // Blacklist already excluded above.
        guard let match = effectiveApps.first(where: { app in
                  runningBundles.contains(app.bundle)
                  && (micOwners.map { ownerMatchesApp(app.bundle, $0) } ?? true)
              }),
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
        // expectedOtherSpeakers = nil (auto-estimate) for auto-detected calls.
        // It used to be hardcoded to 1 to stop the OLD Gemini single-mic
        // diarization fanning one interlocutor into 4-5 phantom speakers — but
        // diarization is now FluidAudio VBx on the SYSTEM (far-end) track, and
        // forcing exactly 1 remote speaker COLLAPSES every 3+-person call into
        // a single "other" (the user's main complaint). nil lets VBx estimate
        // the real remote count; the clarify banner still lets the user pin it.
        let appName = match.name
        Task { @MainActor in
            // Opt-in silent pre-roll: start capturing BEFORE showing the
            // offer (await it so accept can't race the warm-up), so accepting
            // keeps audio/video from the very start of the call. No-op /
            // returns nil when disabled or permissions aren't already granted.
            if AppSettings.prerollEnabled {
                await RecordingController.shared.startPreroll(source: .fullDisplay, expectedOtherSpeakers: nil)
            }
            MenuBarController.shared?.showInviteOffer(
                appName: appName,
                onAccept: { [weak self] in
                    self?.pendingInviteFor = nil
                    Task { @MainActor in
                        // Promote the pre-roll if one is alive (keeps the
                        // start); otherwise record fresh from now.
                        let committed = await RecordingController.shared.commitPreroll()
                        if !committed {
                            // Same auto-estimate rationale as the pre-roll path
                            // above: nil lets FluidAudio VBx count the real
                            // remote speakers instead of collapsing a 3+-person
                            // call into one "other". Forcing 1 here would have
                            // re-introduced the bug whenever pre-roll was off.
                            await RecordingController.shared.startRecording(
                                source: .fullDisplay,
                                expectedOtherSpeakers: nil
                            )
                        }
                    }
                },
                onDismiss: { [weak self] in
                    self?.pendingInviteFor = nil
                    // Declined → throw the silent pre-roll away (no-op if none).
                    Task { @MainActor in await RecordingController.shared.discardPreroll() }
                }
            )
        }
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

    /// Bundle ids of every process Core Audio reports as actively
    /// running INPUT (microphone) right now. `nil` means the
    /// per-process API is unavailable or errored — the caller then
    /// falls back to the coarse device-global check + "any meeting app
    /// running" heuristic. macOS 14.4+ matches the process-tap path we
    /// already depend on for system-audio capture (`SystemAudioTap`).
    ///
    /// This is what lets the detector tell *who* owns the mic: a
    /// background Zoom while Loom / OBS / Terminal / QuickTime is the
    /// real recorder no longer mis-fires an offer, because none of
    /// those is a known meeting app that's *itself* on the input.
    private static func bundlesRunningInput() -> Set<String>? {
        guard #available(macOS 14.4, *) else { return nil }

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddr, 0, nil, &size) == noErr,
              size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                    count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddr, 0, nil, &size, &procs) == noErr else { return nil }

        var owners = Set<String>()
        for proc in procs where proc != AudioObjectID(kAudioObjectUnknown) {
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            var rAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(proc, &rAddr, 0, nil, &rSize, &running) == noErr,
                  running != 0 else { continue }

            var cf: CFString = "" as CFString
            var bSize = UInt32(MemoryLayout<CFString>.size)
            var bAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let st = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
                AudioObjectGetPropertyData(proc, &bAddr, 0, nil, &bSize, ptr)
            }
            if st == noErr {
                let bundle = cf as String
                if !bundle.isEmpty { owners.insert(bundle) }
            }
        }
        return owners
    }
}
