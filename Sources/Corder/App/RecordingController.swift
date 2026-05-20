import AppKit
import Foundation

@MainActor
final class RecordingController {
    static let shared = RecordingController()
    private init() {
        AppContext.shared.capture.delegate = self
    }

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
        // Permissions
        switch await PermissionsChecker.checkScreenRecording() {
        case .granted: break
        case .denied:
            present(error: "Нет разрешения Screen Recording. Открой System Settings → Privacy → Screen Recording.")
            PermissionsChecker.openScreenRecordingSettings()
            return
        case .notDetermined:
            present(error: "Нужно разрешение Screen Recording. Подтверди в System Settings и попробуй снова.")
            PermissionsChecker.openScreenRecordingSettings()
            return
        }
        // Microphone permission: only block on explicit .denied. For .notDetermined
        // we let AVAudioEngine.start() in CaptureEngine trigger the real TCC prompt —
        // that path reliably registers the app in System Settings → Microphone,
        // whereas AVCaptureDevice.requestAccess can silently fail to surface a prompt.
        if PermissionsChecker.checkMicrophone() == .denied {
            present(error: "Нет доступа к микрофону. Открой System Settings → Privacy → Microphone и включи Corder.")
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
            // Show the "Starting recording…" spinner inside the same
            // menu-bar popover the invite uses, so the user gets visible
            // feedback during the SCStream + AVAudioEngine warm-up
            // (~200-400 ms) on BOTH the manual Start and auto-detect
            // paths. The auto-detect path just closed the invite from
            // the same anchor, so invite → loading → blob reads as one
            // continuous element.
            MenuBarController.shared?.showLoadingState()
            try await AppContext.shared.capture.start(meetingId: id, source: source)
            AppContext.shared.recordingState = .recording(meetingId: id, startedAt: Date())
            // Capture is live — drop the loading popover. The floating
            // blob springs in from a tiny transparent dot (its own
            // entry animation), so the loading state never "morphs"
            // into it; it simply hands off.
            MenuBarController.shared?.finishLoadingState()
            // Float Granola-style recording pill over every space so the
            // user always knows capture is alive (and can stop without
            // chasing the menu bar).
            RecordingHUDPanel.shared.show()
            FileLogger.log("RecordingController: started \(id)")
        } catch {
            FileLogger.log("RecordingController: start failed for \(id): \(error)")
            // Tear down the loading popover so the user isn't left
            // staring at a spinner that never resolves.
            MenuBarController.shared?.finishLoadingState()
            present(error: "Не удалось начать запись: \(error.localizedDescription)")
            try? AppContext.shared.repo.deleteMeeting(id: id)
            AppContext.shared.recordingState = .idle
        }
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
        await AppContext.shared.capture.stop()

        // Tell the user *now* if nothing was actually captured (mic muted,
        // wrong input, permission silently lost) instead of letting them
        // discover an empty transcript after the meeting.
        if capturedSilence {
            FileLogger.log("stopRecording: \(id) captured silence (maxMic=\(maxMic) maxSys=\(maxSys))")
            if AppSettings.notificationsEnabled {
                NotificationsService.post(
                    title: L.notif("notif_silent_title"),
                    body: L.notif("notif_silent_body"))
            }
        } else if maxSys < 0.004 && AppContext.shared.capture.outputBluetoothAtStart {
            // We DID record audio (not the total-silence case above), but
            // the system track is empty while the output route was
            // Bluetooth — the exact signature of the process-tap-on-BT
            // failure. The user's own voice is fine; the remote side was
            // silently lost. Tell them why and how to fix it.
            FileLogger.log("stopRecording: \(id) system track silent on Bluetooth output — remote side not captured (maxMic=\(maxMic) maxSys=\(maxSys))")
            if AppSettings.notificationsEnabled {
                NotificationsService.post(
                    title: L.notif("notif_bt_title"),
                    body: L.notif("notif_bt_body"))
            }
        }

        let endedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationMs = Int64(Date().timeIntervalSince(startedAt) * 1000)

        // Auto-transcribe OFF: keep the recording but DON'T enqueue and
        // DON'T mark it .transcribing (that would hang forever and
        // resetStuckMeetings() would flip it to .failed next launch).
        // Land it .ready with no segments — it's browsable and the user
        // can produce a transcript on demand via the existing
        // right-click → Re-transcribe (the manual affordance).
        let autoTx = AppSettings.autoTranscribe
        do {
            if var meeting = try AppContext.shared.repo.meeting(id: id) {
                meeting.endedAt = endedAtMs
                meeting.durationMs = durationMs
                meeting.status = autoTx ? .transcribing : .ready
                // Snapshot the OUTPUT route now — the pipeline's
                // system-track chooser needs to know this recording was
                // on Bluetooth (faint tap) even if it transcribes later.
                meeting.outputBluetoothAtStart =
                    AppContext.shared.capture.outputBluetoothAtStart
                try AppContext.shared.repo.updateMeeting(meeting)
            }
            if AppSettings.notificationsEnabled {
                NotificationsService.post(
                    title: L.notif("notif_saved_title"),
                    body: L.notif("notif_saved_body")
                        .replacingOccurrences(of: "{s}", with: "\(durationMs / 1000)"))
            }
        } catch {
            present(error: "Не удалось сохранить запись: \(error.localizedDescription)")
        }

        AppContext.shared.recordingState = .idle

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
}

extension RecordingController: CaptureEngineDelegate {
    func captureEngine(_ engine: CaptureEngine, didStartMeeting id: String) {}
    func captureEngine(_ engine: CaptureEngine, didStopMeeting id: String) {}
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
