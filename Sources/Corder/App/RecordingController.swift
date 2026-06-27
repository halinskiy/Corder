import AppKit
import Foundation

@MainActor
final class RecordingController {
    static let shared = RecordingController()
    private init() {
        AppContext.shared.capture.delegate = self
    }

    /// Set when the mid-recording "far end lost on Bluetooth" warning has fired
    /// for the current session, so the stop-time warning doesn't repeat it.
    /// Reset at the top of each `startRecording`.
    private var farEndWarnedThisSession = false

    /// Start a new recording.
    ///
    /// `expectedOtherSpeakers` lets the caller seed the meeting with a
    /// known speaker count *before* transcription runs. The auto-detect
    /// path (MeetingDetector → `MenuBarController.showInviteOffer`) passes
    /// 1 because the vast majority of calls it catches are 1:1 — that
    /// keeps Gemini's over-counting (12-min audio sometimes diarized
    /// into 5 buckets for a single interlocutor) from showing up as a
    /// bogus "6 speakers" pill. The user can still flip to "3" or "4+"
    /// in the clarify banner and re-map without re-billing Gemini.
    /// Pass `nil` (the default, used by manual Start) to let Gemini
    /// pick the count.
    func startRecording(source: CaptureSource, expectedOtherSpeakers: Int? = nil) async {
        // If a silent pre-roll is already capturing this call, PROMOTE it
        // (keeps audio/video from the start) instead of opening a second
        // capture — covers a "Start recording" from the menu/hotkey while
        // the detector's offer (and its pre-roll) is up.
        if case .preroll = AppContext.shared.recordingState {
            await commitPreroll()
            return
        }
        // Never open a second capture over a live recording / teardown.
        guard AppContext.shared.recordingState == .idle else {
            FileLogger.log("startRecording: ignored — state is not idle")
            return
        }
        // Guest session cap. A signed-out user may HOLD at most
        // `guestSessionLimit` sessions at once; at the cap, Start always
        // offers sign-in instead of recording. This funnels every entry
        // point — menu-bar Start, the in-app button, AND the hotkey — through
        // one gate (they all land here). Deleting a session frees a slot.
        if Self.guestAtSessionCap() {
            FileLogger.log("startRecording: guest at \(Self.guestSessionLimit)-session cap — offering sign-in instead of recording")
            AuthController.shared.present()
            return
        }
        // Permissions are requested ON DEMAND, only for what THIS recording
        // actually needs — there is no up-front permission gate, and no modal
        // wall even though screen video defaults ON. Audio runs entirely off the
        // Core Audio process tap + the mic, neither of which needs Screen
        // Recording. When screen video is ON but Screen Recording isn't granted,
        // we DON'T block or prompt: the recording silently degrades to audio
        // (CaptureEngine only arms SCStream when the grant is already live), and
        // the Library's "Capture your screen too" ghost panel is the grant path.
        // So a brand-new user records the instant they hit Start, video or not.
        if AppSettings.captureVideo, await PermissionsChecker.checkScreenRecording() != .granted {
            FileLogger.log("RecordingController: screen video on but Screen Recording not granted — recording audio-only (ghost panel handles the grant)")
        }
        // Microphone permission: only block on explicit .denied. For .notDetermined
        // we let AVAudioEngine.start() in CaptureEngine trigger the real TCC prompt —
        // that path reliably registers the app in System Settings → Microphone,
        // whereas AVCaptureDevice.requestAccess can silently fail to surface a prompt.
        if PermissionsChecker.checkMicrophone() == .denied {
            present(error: "Corder needs the microphone to record you. Open System Settings → Privacy & Security → Microphone and turn Corder on.")
            PermissionsChecker.openMicrophoneSettings()
            return
        }

        // Disk-space preflight. A disk-full mid-recording is the
        // highest-severity failure (crash → zero-byte file). Refuse to
        // start under ~500 MB free instead of recording into a wall.
        if let free = Self.freeDiskBytes(), free < 500 * 1024 * 1024 {
            let mb = free / (1024 * 1024)
            present(error: "Мало места на диске (\(mb) МБ). Освободи место — запись не начата, чтобы не потерять её при заполнении диска.")
            return
        }

        // Per-recording session: zero the level meter so the post-stop
        // silence check reflects THIS recording only.
        RecordingLevelMeter.shared.reset()
        farEndWarnedThisSession = false

        let id = UUID().uuidString.lowercased()
        let dir = AppPaths.recordingDir(for: id)
        let videoPath = dir.appendingPathComponent("video.mov").path
        let audioPath = dir.appendingPathComponent("mic.wav").path
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        var meeting = Meeting(
            id: id,
            startedAt: now,
            videoPath: videoPath,
            audioPath: audioPath,
            status: .recording
        )
        meeting.expectedOtherSpeakers = expectedOtherSpeakers

        do {
            try AppContext.shared.repo.insertMeeting(meeting)
            // Earlier we showed a "Starting recording…" spinner inside
            // the menu-bar popover during the SCStream + AVAudioEngine
            // warm-up (~200-400 ms). That spinner required flipping
            // popover.behavior to .applicationDefined and back, and
            // races between that swap and `RecordingController`'s
            // state transitions left the popover sticky (refusing
            // to dismiss on outside clicks). The floating HUD pill
            // is already the canonical "capture is alive" signal —
            // 400 ms with no menu-bar feedback is fine, the HUD
            // pops in right after. No spinner == no sticky popover.
            try await AppContext.shared.capture.start(meetingId: id, source: source)
            AppContext.shared.recordingState = .recording(meetingId: id, startedAt: Date())
            // Float Granola-style recording pill over every space so the
            // user always knows capture is alive (and can stop without
            // chasing the menu bar).
            RecordingHUDPanel.shared.show()
            FileLogger.log("RecordingController: started \(id)")
        } catch {
            FileLogger.log("RecordingController: start failed for \(id): \(error)")
            present(error: "Не удалось начать запись: \(error.localizedDescription)")
            try? AppContext.shared.repo.deleteMeeting(id: id)
            AppContext.shared.recordingState = .idle
        }
    }

    // MARK: - Silent pre-roll (opt-in)

    /// Begin a SILENT pre-roll capture (no HUD, hidden row) the instant a
    /// call is detected, so accepting the offer keeps audio/video from the
    /// very start. Returns the pre-roll meeting id, or nil if it couldn't
    /// start (permissions not already granted, disk low, or not idle) — the
    /// caller then falls back to the normal record-on-accept flow. Never
    /// prompts and never shows an error: pre-roll must be invisible.
    @discardableResult
    func startPreroll(source: CaptureSource, expectedOtherSpeakers: Int? = nil) async -> String? {
        guard AppContext.shared.recordingState == .idle else { return nil }
        // Guest at the session cap: don't even silently pre-roll. The
        // detector then falls back to the visible offer, and accepting it
        // routes through `startRecording`, which surfaces the sign-in prompt.
        if Self.guestAtSessionCap() { return nil }
        // Silent → require permissions ALREADY granted (we can't prompt
        // without UI). Screen Recording for SCStream; mic must not be denied.
        guard case .granted = await PermissionsChecker.checkScreenRecording() else { return nil }
        if PermissionsChecker.checkMicrophone() == .denied { return nil }
        if let free = Self.freeDiskBytes(), free < 500 * 1024 * 1024 { return nil }

        RecordingLevelMeter.shared.reset()
        let id = UUID().uuidString.lowercased()
        let dir = AppPaths.recordingDir(for: id)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var meeting = Meeting(
            id: id,
            startedAt: now,
            videoPath: dir.appendingPathComponent("video.mov").path,
            audioPath: dir.appendingPathComponent("mic.wav").path,
            status: .preroll
        )
        meeting.expectedOtherSpeakers = expectedOtherSpeakers
        do {
            try AppContext.shared.repo.insertMeeting(meeting)
            try await AppContext.shared.capture.start(meetingId: id, source: source)
            AppContext.shared.recordingState = .preroll(meetingId: id, startedAt: Date())
            FileLogger.log("RecordingController: pre-roll started \(id)")
            return id
        } catch {
            FileLogger.log("RecordingController: pre-roll start failed \(id): \(error)")
            try? AppContext.shared.repo.deleteMeeting(id: id)
            try? FileManager.default.removeItem(at: dir)
            AppContext.shared.recordingState = .idle
            return nil
        }
    }

    /// Promote the active pre-roll into a real, visible recording (HUD +
    /// sidebar row). Capture keeps running uninterrupted, so the result
    /// spans from the moment the call was detected. Returns false if there
    /// was no active pre-roll (caller falls back to `startRecording`).
    @discardableResult
    func commitPreroll() async -> Bool {
        guard case .preroll(let id, let startedAt) = AppContext.shared.recordingState else { return false }
        if var m = try? AppContext.shared.repo.meeting(id: id) {
            m.status = .recording
            try? AppContext.shared.repo.updateMeeting(m)
        }
        AppContext.shared.recordingState = .recording(meetingId: id, startedAt: startedAt)
        RecordingHUDPanel.shared.show()
        FileLogger.log("RecordingController: pre-roll committed \(id)")
        return true
    }

    /// Throw away the active pre-roll (declined, or the call ended before
    /// the user decided): stop capture, delete the hidden row + files, as if
    /// it never happened.
    func discardPreroll() async {
        guard case .preroll(let id, _) = AppContext.shared.recordingState else { return }
        AppContext.shared.recordingState = .stopping
        await AppContext.shared.capture.stop()
        try? AppContext.shared.repo.deleteMeeting(id: id)
        try? FileManager.default.removeItem(at: AppPaths.recordingDir(for: id))
        AppContext.shared.recordingState = .idle
        RecordingLevelMeter.shared.reset()
        FileLogger.log("RecordingController: pre-roll discarded \(id)")
    }

    func stopRecording() async {
        guard case .recording(let id, let startedAt) = AppContext.shared.recordingState else { return }
        AppContext.shared.recordingState = .stopping
        // Snapshot the silence verdict BEFORE hide(): when the floating
        // HUD is suppressed (Library window open — the normal "record a
        // call I'm watching" case) `hide()` takes its `window == nil`
        // branch and SYNCHRONOUSLY calls `RecordingLevelMeter.reset()`,
        // which zeroes sessionMax. Reading `capturedSilence` after that
        // always reported silence and fired a false "No audio captured"
        // alarm on perfectly good recordings. sessionMax already holds
        // the whole session's peak by now, so reading here is accurate.
        let capturedSilence = RecordingLevelMeter.shared.capturedSilence
        let maxMic = RecordingLevelMeter.shared.sessionMaxMic
        let maxSys = RecordingLevelMeter.shared.sessionMaxSystem
        RecordingHUDPanel.shared.hide()
        let btAtStart = AppContext.shared.capture.outputBluetoothAtStart
        await AppContext.shared.capture.stop()

        // Reliability telemetry (anonymous counts only). `farEndLost` =
        // we DID record (mic had audio) but the system track came out
        // silent, i.e. the other person was lost — the exact failure we
        // need real-world numbers on, split by Bluetooth.
        TelemetryService.bump(.recordings)
        if btAtStart { TelemetryService.bump(.btRecordings) }
        if !capturedSilence && maxSys < 0.004 {
            TelemetryService.bump(.farEndLost)
            if btAtStart { TelemetryService.bump(.btFarEndLost) }
        }

        // Tell the user *now* if nothing was actually captured (mic muted,
        // wrong input, permission silently lost). The silent-recording
        // notification is fired in the meeting-save block below — kept
        // there so it goes out only AFTER the row is actually marked as
        // archived (we don't want to say "moved to Archive" and then
        // have the save fail).
        if capturedSilence {
            FileLogger.log("stopRecording: \(id) captured silence (maxMic=\(maxMic) maxSys=\(maxSys))")
        } else if maxSys < 0.004 && AppContext.shared.capture.outputBluetoothAtStart && !farEndWarnedThisSession {
            // We DID record audio (not the total-silence case above), but
            // the system track is empty while the output route was
            // Bluetooth — the exact signature of the process-tap-on-BT
            // failure. The user's own voice is fine; the remote side was
            // silently lost. Tell them why and how to fix it — UNLESS the
            // mid-recording warning already fired for this session (the tap
            // watchdog gave up early), so we don't double up.
            FileLogger.log("stopRecording: \(id) system track silent on Bluetooth output — remote side not captured (maxMic=\(maxMic) maxSys=\(maxSys))")
            if AppSettings.notificationsEnabled {
                NotificationsService.post(
                    title: L.notif("notif_bt_title"),
                    body: L.notif("notif_bt_body"))
            }
            // Always surface it in-window too (not gated by the
            // notifications toggle) — losing the far end is important
            // enough that the user must see it even if they record with a
            // BT headset on a call (HFP), where macOS gives us no reliable
            // way to capture the remote side.
            LibraryWindow.shared.postToast(
                title: L.notif("notif_bt_title"),
                body: L.notif("notif_bt_body"),
                kind: "error")
        }

        let endedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationMs = Int64(Date().timeIntervalSince(startedAt) * 1000)

        // Auto-archive in two cases:
        //   1. Under 5 seconds — almost always a misclick (Start →
        //      immediate Stop, Discord toast vanished, etc). User
        //      asked to bin those without thinking.
        //   2. Silent recording under a minute — setup mistake
        //      (muted mic, wrong input, forgot the call). Long
        //      silent runs are intentional (timer, leaving the
        //      room) and stay in the main library.
        let isUltraShort = durationMs < 5_000
        let isShortSilent = capturedSilence && durationMs < 60_000
        let shouldAutoArchive = isUltraShort || isShortSilent

        // Auto-transcribe OFF: keep the recording but DON'T enqueue and
        // DON'T mark it .transcribing (that would hang forever and
        // resetStuckMeetings() would flip it to .failed next launch).
        // Land it .ready with no segments — it's browsable and the user
        // can produce a transcript on demand via the existing
        // right-click → Re-transcribe (the manual affordance).
        // Silent recordings skip transcription regardless of length
        // (nothing to transcribe). Only the SHORT silent ones also
        // auto-archive (see `shouldAutoArchive` above).
        // Auto-transcribe skips silent takes (nothing to transcribe)
        // AND ultra-short ones (5s isn't a meeting; even with audio,
        // sending to Whisper just burns API quota for nothing).
        let autoTx = AppSettings.autoTranscribe && !capturedSilence && !isUltraShort
        do {
            if var meeting = try AppContext.shared.repo.meeting(id: id) {
                meeting.endedAt = endedAtMs
                meeting.durationMs = durationMs
                meeting.status = autoTx ? .transcribing : .ready
                if shouldAutoArchive { meeting.archivedAt = endedAtMs }
                // Snapshot the OUTPUT route now — the pipeline's
                // system-track chooser needs to know this recording was
                // on Bluetooth (faint tap) even if it transcribes later.
                meeting.outputBluetoothAtStart =
                    AppContext.shared.capture.outputBluetoothAtStart
                try AppContext.shared.repo.updateMeeting(meeting)
            }
            if AppSettings.notificationsEnabled {
                if shouldAutoArchive {
                    NotificationsService.post(
                        title: L.notif("notif_silent_archived_title"),
                        body: L.notif("notif_silent_archived_body"))
                } else if capturedSilence {
                    // Long silent recording — kept, but flag that
                    // nothing was captured so the user isn't surprised
                    // when the transcript stays empty.
                    NotificationsService.post(
                        title: L.notif("notif_silent_title"),
                        body: L.notif("notif_silent_body"))
                } else {
                    NotificationsService.post(
                        title: L.notif("notif_saved_title"),
                        body: L.notif("notif_saved_body")
                            .replacingOccurrences(of: "{s}", with: "\(durationMs / 1000)"))
                }
            }
            // Also surface the short-silent → archived event as an
            // in-app toast for the Library window's WKWebView, so a
            // user with the window already open sees a banner without
            // having to glance at the Notification Center.
            if shouldAutoArchive {
                LibraryWindow.shared.postToast(
                    title: L.notif("notif_silent_archived_title"),
                    body: L.notif("notif_silent_archived_body"),
                    kind: "info")
            }
        } catch {
            present(error: "Не удалось сохранить запись: \(error.localizedDescription)")
        }

        AppContext.shared.recordingState = .idle

        // Silent + auto-archived: nothing left to do — no transcription,
        // no playback mix needed (the row is in Archive). The user can
        // restore + manually re-transcribe from the bin if they really
        // want to keep an empty row around.
        if capturedSilence {
            FileLogger.log("stopRecording: auto-archived silent recording \(id)")
            return
        }

        guard autoTx else {
            FileLogger.log("stopRecording: auto-transcribe OFF — \(id) saved un-transcribed (manual re-transcribe available)")
            // The playback mix (audio.wav = mic + far end) is normally
            // produced inside transcribe(). With auto-transcribe off
            // that never runs, so the audio route falls back to
            // mic.wav and the far end seems "not recorded" on playback
            // even though system.wav captured it fine. Produce the mix
            // now so an untranscribed recording is fully playable.
            // On a Bluetooth route the tap (system.wav) is faint, so
            // prefer the SCStream backup for an audible far end —
            // mirrors the transcription chooser's intent.
            let dir = AppPaths.recordingDir(for: id)
            let micURL = dir.appendingPathComponent("mic.wav")
            let mixURL = dir.appendingPathComponent("audio.wav")
            let tapURL = dir.appendingPathComponent("system.wav")
            let sckURL = dir.appendingPathComponent("system_sck.wav")
            let fm = FileManager.default
            if fm.fileExists(atPath: micURL.path),
               !fm.fileExists(atPath: mixURL.path) {
                // Pick the system track that ACTUALLY carries the far
                // end by voiced energy — never the BT flag and never
                // file size (system_sck.wav is 11 MB of pure zeros in
                // every observed run; the Core-Audio tap is the track
                // that really records, even on Bluetooth). Mirrors the
                // TranscriptionPipeline chooser. Off the main actor so a
                // long recording's VAD scan doesn't stall the UI.
                let chosen: URL? = await Task.detached(priority: .utility) {
                    () -> URL? in
                    let f = FileManager.default
                    let tapV = f.fileExists(atPath: tapURL.path)
                        ? (VoiceActivityDetector.voicedEnergy(audioURL: tapURL)?.voicedMs ?? -1)
                        : -1
                    let sckV = f.fileExists(atPath: sckURL.path)
                        ? (VoiceActivityDetector.voicedEnergy(audioURL: sckURL)?.voicedMs ?? -1)
                        : -1
                    if max(tapV, sckV) <= 0 { return nil }
                    return sckV > tapV ? sckURL : tapURL
                }.value
                do {
                    try await AudioMixer.produceWhisperInput(
                        systemURL: chosen, micURL: micURL, outputURL: mixURL)
                    FileLogger.log("stopRecording: produced playback mix audio.wav (mic\(chosen.map { "+\($0.lastPathComponent)" } ?? " only")) for un-transcribed \(id)")
                } catch {
                    FileLogger.log("stopRecording: playback mix failed (\(error)) for \(id) — playback falls back to mic.wav")
                }
            }
            return
        }

        // Kick off transcription. TranscriptionPipeline is @MainActor — running it
        // on the main actor (instead of a detached Task) keeps NSLog/FileLogger
        // emission consistent and prevents the in-flight task from being silently
        // dropped if the dispatch queue gets cleaned up under memory pressure.
        FileLogger.log("stopRecording: scheduling transcription for \(id)")
        Task { @MainActor in
            await TranscriptionPipeline.shared.enqueue(meetingId: id).value
            if AppSettings.notificationsEnabled {
                NotificationsService.post(
                    title: L.notif("notif_ready_title"),
                    body: L.notif("notif_ready_body"))
            }
        }
    }

    /// Max sessions a signed-out (guest) user may hold at once. Beyond this,
    /// Start offers sign-in instead of recording. Signed-in users are
    /// unlimited. Shared with the `/api/account/usage` route + the header
    /// "N left" counter.
    static let guestSessionLimit = 5

    /// Sessions the guest currently holds (library + archive, minus pre-roll).
    /// 0 for signed-in users (the cap doesn't apply, so we don't query).
    static func guestSessionsHeld() -> Int {
        guard !AppSettings.isSignedIn else { return 0 }
        return (try? AppContext.shared.repo.heldMeetingCount()) ?? 0
    }

    /// True when a signed-out user is at/over the session cap.
    static func guestAtSessionCap() -> Bool {
        !AppSettings.isSignedIn && guestSessionsHeld() >= guestSessionLimit
    }

    /// Free space on the volume holding the recordings dir, in bytes.
    private static func freeDiskBytes() -> Int64? {
        let url = AppPaths.recordingDir(for: "probe").deletingLastPathComponent()
        let vals = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let v = vals?.volumeAvailableCapacityForImportantUsage { return v }
        // Fallback for volumes that don't report the "important usage" key.
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    private func present(error: String) {
        let alert = NSAlert()
        alert.messageText = "Corder"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.runModal()
    }

    // `presentScreenRecordingNeeded` (the restart-aware "Allow Screen Recording"
    // modal wall) was removed: screen video defaults ON and a missing grant
    // degrades to audio silently, with the Library's "Capture your screen too"
    // ghost panel as the grant path. No modal interrupts the record click.
}

extension RecordingController: CaptureEngineDelegate {
    func captureEngine(_ engine: CaptureEngine, didStartMeeting id: String) {}
    func captureEngine(_ engine: CaptureEngine, didStopMeeting id: String) {}

    /// The process tap gave up on a Bluetooth route (HFP/SCO) — the far end is
    /// being lost right now. Warn the user mid-recording (≈8 s in) so they can
    /// switch their Mac's output off Bluetooth and re-record, instead of only
    /// discovering it at stop. Same copy as the stop-time warning; a guard stops
    /// the stop path from repeating it.
    func captureEngineFarEndUnavailable(_ engine: CaptureEngine) {
        guard !farEndWarnedThisSession else { return }
        guard case .recording = AppContext.shared.recordingState else { return }
        farEndWarnedThisSession = true
        FileLogger.log("RecordingController: far end uncapturable on Bluetooth (tap watchdog gave up) — warning mid-recording")
        if AppSettings.notificationsEnabled {
            NotificationsService.post(
                title: L.notif("notif_bt_title"),
                body: L.notif("notif_bt_body"))
        }
        // Always surface in-window too (not gated by the notifications toggle) —
        // losing the far end is important enough to show regardless.
        LibraryWindow.shared.postToast(
            title: L.notif("notif_bt_title"),
            body: L.notif("notif_bt_body"),
            kind: "error")
    }
    func captureEngine(_ engine: CaptureEngine, didFailWithError error: Error) {
        FileLogger.log("RecordingController: capture failed: \(error)")
        // Whatever meeting was being recorded is now toast — flip its DB
        // row to .failed so the UI never gets stuck on a green dot. The
        // app crash recovery (`resetStuckMeetings` on launch) covers the
        // scenario where the process dies before this delegate fires; this
        // path covers the scenario where the process stays up but SCStream
        // silently bails (most often: Screen Recording permission revoked
        // mid-session, or the user logged out and back in).
        if case .recording(let id, _) = AppContext.shared.recordingState {
            if var meeting = try? AppContext.shared.repo.meeting(id: id) {
                meeting.status = .failed
                try? AppContext.shared.repo.updateMeeting(meeting)
            }
        }
        RecordingHUDPanel.shared.hide()
        present(error: "Capture failed: \(error.localizedDescription)")
        AppContext.shared.recordingState = .idle
    }
}
