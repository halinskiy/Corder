import AppKit
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

protocol CaptureEngineDelegate: AnyObject {
    @MainActor func captureEngine(_ engine: CaptureEngine, didStartMeeting id: String)
    @MainActor func captureEngine(_ engine: CaptureEngine, didStopMeeting id: String)
    @MainActor func captureEngine(_ engine: CaptureEngine, didFailWithError error: Error)
}

enum CaptureError: Error, LocalizedError {
    case alreadyRecording
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Already recording"
        case .noDisplay: return "No displays available"
        }
    }
}

enum CaptureSource: Hashable {
    case fullDisplay
    case window(windowID: CGWindowID, title: String, ownerName: String, width: Int, height: Int)
}

@MainActor
final class CaptureEngine: NSObject {
    weak var delegate: CaptureEngineDelegate?

    private(set) var isRecording = false
    /// Latched synchronously at the top of `start()` (before the first
    /// `await`) so a second concurrent `start()` — or a `start()` racing a
    /// `stop()` during the ~300 ms permission/SCStream warm-up — is
    /// rejected instead of stomping the first run's stream/tap/files.
    private var starting = false
    /// Set by `stop()` when it's called WHILE `start()` is mid-warm-up
    /// (isRecording not yet true). `start()` checks it after arming and
    /// tears down immediately, so a sleep/lock during warm-up can't leave
    /// a live capture that nothing ever stops (privacy indicator stuck on).
    private var stopRequestedDuringStart = false
    /// Set true the instant `stop()` begins, before the async teardown.
    /// The system-audio writers open their AVAudioFile LAZILY on the
    /// first buffer (a nil file means "not opened yet"). After stop,
    /// `systemAudioFile`/`sckAudioFile` are also nil'd — so a late
    /// buffer whose main-actor `Task` lands AFTER stop would see nil
    /// and *re-create* the file with `AVAudioFile(forWriting:)`, which
    /// TRUNCATES the just-written recording to an empty file (root
    /// cause of the "473088 frames captured yet system.wav is 0 bytes"
    /// total loss). This flag disambiguates "not opened yet" from
    /// "closed after stop": once set, late buffers are dropped, never
    /// reopened.
    private var tearingDown = false
    private(set) var startedAt: Date?
    private(set) var meetingId: String?
    private(set) var videoURL: URL?
    private(set) var micURL: URL?
    private(set) var systemURL: URL?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.3mpq.corder.scstream", qos: .userInitiated)

    // Microphone via AVAudioEngine — runs on its own thread
    private var audioEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    // Diagnostic: how many sample frames the tap actually delivered. If this
    // stays at 0 across a recording, AVAudioEngine isn't getting any audio
    // (mic disabled / device race with Telegram / etc.).
    private var micFramesWritten: Int64 = 0

    // Video writer for screen capture. HEVC at 15fps + ~1.5 Mbps —
    // tuned for meeting recordings (mostly static UI, occasional cursor /
    // window motion). The first `.screen` sample's PTS becomes the
    // session start; subsequent samples are appended directly.
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoSessionStarted = false
    private var videoFramesAppended: Int64 = 0

    // System audio now comes from a Core Audio process tap (see
    // SystemAudioTap) instead of SCStream's `.audio` output. SCStream
    // delivered silence on real calls because communication apps render
    // through Voice-Processing I/O, which bypasses the system mix it
    // taps. The tap's buffers are mirrored into a standalone .wav so
    // transcription doesn't depend on AVAssetWriter finalising the .mov.
    private let systemTap = SystemAudioTap()
    private var systemAudioFile: AVAudioFile?
    private var systemAudioFormat: AVAudioFormat?
    // Diagnostic counter for the system-audio tap. If this stays at 0
    // across a recording, the process tap delivered no frames (TCC
    // denied, or genuinely nothing playing).
    private var systemFramesWritten: Int64 = 0
    private var loggedFirstSystemBuffer = false
    /// Snapshot of whether the default OUTPUT was Bluetooth when this
    /// recording started. The process tap captures silence on a BT
    /// route, so if system.wav ends up silent AND this is true, the
    /// remote side was lost to the BT limitation — RecordingController
    /// reads this post-stop to warn the user specifically. Survives
    /// stop() (cleared only on the next start()).
    private(set) var outputBluetoothAtStart = false

    // Secondary system-audio capture via SCStream's `.audio` output,
    // written to a SEPARATE system_sck.wav. This is a belt-and-braces
    // backup for the Core Audio process tap: the tap captures silence
    // on a Bluetooth output route (AirPods / BT headset — the common
    // case), whereas SCStream's audio tap captures the system mix in
    // that case. The two fail on opposite scenarios (SCStream is silent
    // on VPIO/WebRTC calls; the tap is silent on BT output), so writing
    // both and letting TranscriptionPipeline pick the non-silent track
    // means a recording is only lost when BOTH fail. Strictly additive:
    // the tap path (system.wav) is never touched, so worst case is
    // today's behaviour with no regression. We deliberately do NOT feed
    // RecordingLevelMeter from this path — the BT-warning heuristic in
    // RecordingController keys off sessionMaxSystem reflecting the TAP
    // only; mixing SCK levels in would mask the very failure we warn on.
    private var sckSystemURL: URL?
    private var sckAudioFile: AVAudioFile?
    private var sckFramesWritten: Int64 = 0
    private var loggedFirstSCKBuffer = false

    func start(meetingId: String, source: CaptureSource) async throws {
        FileLogger.log("CaptureEngine.start: meetingId=\(meetingId) source=\(source)")
        // Reject re-entry synchronously, BEFORE any await, so two near-
        // simultaneous starts (manual + auto-detect, double hotkey) can't
        // both pass and leak a stream/tap. `defer` clears the latch on
        // every exit; once `isRecording` is true the normal guard owns it.
        guard !isRecording, !starting else {
            FileLogger.log("CaptureEngine.start: rejected — already \(isRecording ? "recording" : "starting")")
            throw CaptureError.alreadyRecording
        }
        starting = true
        stopRequestedDuringStart = false
        defer { starting = false }
        tearingDown = false
        outputBluetoothAtStart = SystemAudioTap.defaultOutputIsBluetooth()
        if outputBluetoothAtStart {
            FileLogger.log("CaptureEngine.start: default OUTPUT is Bluetooth — process tap may capture silence (remote side at risk)")
        }
        // AVAudioEngine alone doesn't trigger the macOS Microphone TCC sheet.
        // We ask AVCaptureDevice explicitly — but a LSUIElement app has to be
        // .regular + active for the prompt to actually appear. Otherwise the
        // request resolves silently as "denied" and the user never sees the
        // dialog. We temporarily flip activation policy, ask, then restore.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        FileLogger.log("CaptureEngine.start: mic TCC status before request = \(micStatus.rawValue)")
        if micStatus == .notDetermined {
            let prevPolicy = await MainActor.run { NSApp.activationPolicy() }
            await MainActor.run {
                if prevPolicy == .accessory {
                    NSApp.setActivationPolicy(.regular)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            FileLogger.log("CaptureEngine.start: mic permission requested -> granted=\(granted)")
            await MainActor.run {
                if prevPolicy == .accessory {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        } else if micStatus == .denied || micStatus == .restricted {
            FileLogger.log("CaptureEngine.start: WARNING — mic permission denied/restricted; opening System Settings.")
            // Surface the panel so the user can flip the toggle.
            await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        guard !isRecording else {
            FileLogger.log("CaptureEngine.start: rejected — already recording")
            throw CaptureError.alreadyRecording
        }

        let dir = AppPaths.recordingDir(for: meetingId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let videoURL = dir.appendingPathComponent("video.mov")
        let micURL = dir.appendingPathComponent("mic.wav")
        let systemURL = dir.appendingPathComponent("system.wav")
        let sckSystemURL = dir.appendingPathComponent("system_sck.wav")
        FileLogger.log("CaptureEngine.start: dir=\(dir.path)")

        // Remove any leftovers from a previous failed run
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)
        try? FileManager.default.removeItem(at: sckSystemURL)

        // 1. Build the SCContentFilter for the chosen source.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let ourApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter: SCContentFilter
        let captureWidth: Int
        let captureHeight: Int

        switch source {
        case .fullDisplay:
            if let ourApp = ourApp {
                filter = SCContentFilter(display: display, excludingApplications: [ourApp], exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            captureWidth = display.width
            captureHeight = display.height
        case .window(let id, _, _, let w, let h):
            guard let win = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.noDisplay
            }
            filter = SCContentFilter(desktopIndependentWindow: win)
            captureWidth = w
            captureHeight = h
        }

        // 2. Configuration: source size + system audio.
        // We deliberately leave sampleRate / channelCount at defaults — pinning
        // them to 48k stereo causes SCStream.startCapture to fail with
        // "Stream failed to start audio" on devices where the actual output is
        // mono (Bluetooth headsets, some external DACs, AirPods in HFP mode).
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(CGFloat(captureWidth) * scale)
        config.height = Int(CGFloat(captureHeight) * scale)
        // YUV (4:2:0) is the H.264 encoder's native input format; using BGRA
        // forces SCStream → encoder to do an RGB↔YUV pass internally, and on
        // some macOS builds the converter throws -16122 partway through and
        // the writer flips to .failed. Feeding YUV directly is faster and
        // avoids the conversion path entirely.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 6
        // 15 fps is plenty for meeting recordings — cursor and window
        // motion read fine at that rate, and the encoder's per-second
        // bitrate target shrinks accordingly. 30 fps would just double
        // the data with no perceptible quality gain on screen content.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // We deliberately do NOT use SCStream's `.microphone` output even on
        // macOS 15+. It looks attractive — a single shared tap — but in
        // practice the system silently delivers zero frames whenever
        // another app (Meet, Zoom, Discord, Telegram) holds the mic via
        // WebRTC, or when the user is on Bluetooth headphones. Granola,
        // Loom, Krisp and the rest all go through `AVAudioEngine.installTap`
        // on the default input device for exactly this reason: it goes
        // through CoreAudio HAL where mic streams are shared, not exclusive.

        // 3. AVAssetWriter for video.mov. HEVC at ~1.5 Mbps + 15 fps,
        //    feeding the YUV samples SCStream already delivers — no
        //    BGRA→YUV converter pass, which is the path that historically
        //    flipped the writer to .failed with -16122 partway through.
        //    Session start is deferred to the first sample we receive
        //    (sample PTS, not zero) so SCStream's arbitrary clock origin
        //    doesn't blow up the writer. Failures here are non-fatal —
        //    audio capture continues, the frontend renders <audio> when
        //    the .mov is missing.
        // User can turn screen-video recording off (audio-only). Skipping
        // the writer is exactly the existing "init failed" path the rest
        // of the engine already tolerates: videoWriter stays nil,
        // writeVideo no-ops, the frontend renders <audio> via has_video.
        // The `.screen` SCStream output is still registered below (it
        // keeps the audio-clock pacing intact regardless).
        if !AppSettings.captureVideo {
            FileLogger.log("CaptureEngine.start: screen-video disabled in Settings — audio only")
        } else {
        do {
            try? FileManager.default.removeItem(at: videoURL)
            let writer = try AVAssetWriter(url: videoURL, fileType: .mov)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height,
                AVVideoCompressionPropertiesKey: [
                    // Average ~1.5 Mbps. Screen content is mostly static so
                    // the encoder dips well below this most of the time.
                    AVVideoAverageBitRateKey: 1_500_000,
                    AVVideoExpectedSourceFrameRateKey: 15,
                    // I-frame every 4s at 15fps. Lets the user scrub the
                    // recorded video in the Library without long waits to
                    // the next keyframe.
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
            }
            if writer.startWriting() {
                self.videoWriter = writer
                self.videoInput = input
                self.videoSessionStarted = false
                self.videoFramesAppended = 0
                FileLogger.log("CaptureEngine.start: AVAssetWriter armed (HEVC, \(config.width)x\(config.height), 15fps, 1.5 Mbps)")
            } else {
                FileLogger.log("CaptureEngine.start: AVAssetWriter.startWriting failed: \(writer.error?.localizedDescription ?? "?"). Continuing without video.")
            }
        } catch {
            FileLogger.log("CaptureEngine.start: AVAssetWriter init failed: \(error). Continuing without video.")
        }
        }   // end if AppSettings.captureVideo

        // 4. SCStream for SCREEN (video) + a SECONDARY system-audio
        //    track. The Core Audio process tap below is still the
        //    primary system-audio source (it captures VPIO/WebRTC call
        //    audio the SCStream mix misses). But the tap is silent when
        //    the output route is Bluetooth — exactly when many users
        //    record (AirPods). SCStream's audio tap captures the mix in
        //    that case, so we keep `capturesAudio = true` and mirror its
        //    `.audio` output into a SEPARATE system_sck.wav. The tap
        //    path is untouched; TranscriptionPipeline prefers the tap
        //    and only falls back to system_sck.wav when the tap track is
        //    provably silent. Net: no regression, BT recordings saved.
        config.capturesAudio = true
        // The 2026-05-20 diagnostic agent matrix-proved that
        // `excludesCurrentProcessAudio = true` + an active Core-Audio
        // process tap deterministically zeros every PCM sample SCStream
        // delivers (rms 0.00 across 6+ recordings, regardless of BT
        // route). Apple docs say the property defaults to false, but
        // empirically the deployed builds behaved like true — pinning
        // it false explicitly restores the SCK audio path (m4 rms 0.072
        // vs m5 0.000 in the isolated CLI matrix at /tmp/sck-test).
        // The TranscriptionPipeline's voiced-energy chooser keeps SCK
        // out of the way on non-BT runs (tap still wins on energy), so
        // SCK now finally pulls its weight as the BT-output fallback
        // it was always meant to be. Side-effect: SCK will capture
        // Corder's own UI chimes; harmless because SCK only "wins" on
        // BT-SCO calls where Corder isn't making noise anyway.
        config.excludesCurrentProcessAudio = false
        let activeStream = SCStream(filter: filter, configuration: config, delegate: self)
        try activeStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        do {
            try activeStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            self.sckSystemURL = sckSystemURL
            self.sckAudioFile = nil
            self.sckFramesWritten = 0
            self.loggedFirstSCKBuffer = false
            FileLogger.log("CaptureEngine.start: SCStream configured (screen + secondary system audio → system_sck.wav)")
        } catch {
            // Non-fatal: the process tap is still the primary path. We
            // just lose the Bluetooth-output safety net for this run.
            self.sckSystemURL = nil
            FileLogger.log("CaptureEngine.start: SCStream .audio output registration failed: \(error). Continuing with process tap only.")
        }
        do {
            try await activeStream.startCapture()
            FileLogger.log("CaptureEngine.start: SCStream.startCapture OK (screen)")
        } catch {
            FileLogger.log("CaptureEngine.start: SCStream.startCapture FAILED: \(error). Continuing — audio tap + mic still record; no video.")
        }
        self.stream = activeStream

        // 5. Microphone via AVAudioEngine.installTap on the default input.
        //    This is the only path now (no more SCStream.microphone) — see
        //    the comment on `capturesAudio` above for why.
        self.micURL = micURL
        self.micFile = nil
        self.micFramesWritten = 0
        let engine = AVAudioEngine()
        // If the user has picked a specific input device in Settings,
        // bind the engine's input AUHAL to that device BEFORE asking
        // for the format — `outputFormat(forBus:)` queries the unit's
        // currently bound device, so the order matters. When no UID
        // is saved (fresh install / "System default" choice / device
        // unplugged), we leave AVAudioEngine on the system default —
        // identical to the pre-feature behaviour.
        if let chosenUID = AppSettings.micDeviceUID {
            if let resolvedID = AudioInputDevices.apply(uid: chosenUID, to: engine) {
                FileLogger.log("CaptureEngine.start: mic device set to UID=\(chosenUID) (AudioDeviceID=\(resolvedID))")
            } else {
                FileLogger.log("CaptureEngine.start: saved mic UID=\(chosenUID) not found / apply failed — falling back to system default")
            }
        }
        let inputNode = engine.inputNode
        // Acoustic echo cancellation. Route the mic through macOS Voice
        // Processing so the far end's voice coming OUT of the speakers is
        // cancelled out of the mic — the same AEC Discord/Zoom run on their
        // own mic streams. Without it, recording on speakers (no headphones)
        // double-captures the remote (clean via the system tap + bleed via
        // the mic), and the playback mix sums both → audible echo. Must be
        // set BEFORE reading the node format / installing the tap. Best-
        // effort: if Voice Processing can't enable (rare hardware / older
        // device), fall back to the raw mic so a recording never fails over
        // an enhancement.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            FileLogger.log("CaptureEngine.start: mic Voice Processing (AEC) enabled")
        } catch {
            FileLogger.log("CaptureEngine.start: Voice Processing unavailable (\(error)) — raw mic, no AEC")
        }
        // Read the format AFTER enabling VP — the voice-processing unit can
        // hand back a different sample rate / channel count than the bare
        // device, and the tap + file must match the node's actual output.
        let inputFormat = inputNode.outputFormat(forBus: 0)
        FileLogger.log("CaptureEngine.start: mic via AVAudioEngine; format \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        // Mic init can throw (AVAudioFile open with a zero/invalid input
        // format, or engine.start when another app holds the input device —
        // Discord/Telegram). By here the SCStream is ALREADY live, so a bare
        // throw would leave it capturing forever with nothing to stop it (the
        // privacy indicator stuck on, the device leaked). Tear the partial
        // capture down before rethrowing so the recording fails cleanly.
        do {
            let micFile = try AVAudioFile(
                forWriting: micURL,
                settings: inputFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            self.micFile = micFile
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.micFramesWritten &+= Int64(buffer.frameLength)
                try? self.micFile?.write(from: buffer)
                // Push raw peak to the level meter — the floating HUD
                // panel observes it to draw the live mic bar.
                RecordingLevelMeter.shared.ingestMic(buffer: buffer)
            }
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
        } catch {
            FileLogger.log("CaptureEngine.start: mic init failed (\(error)) — tearing down the already-armed SCStream to avoid a leaked live capture")
            try? activeStream.removeStreamOutput(self, type: .screen)
            try? activeStream.removeStreamOutput(self, type: .audio)
            try? await activeStream.stopCapture()
            self.stream = nil
            self.sckSystemURL = nil
            inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            self.micFile = nil
            throw error
        }

        // 6. system.wav via the Core Audio process tap. Opened lazily
        //    on the first tap buffer (we take the format from the tap).
        //    Tap failure is non-fatal: mic still records, the meeting
        //    just won't have the remote side (same outcome as the old
        //    SCStream silent-audio case, but now it's the rare path).
        self.systemURL = systemURL
        self.systemAudioFile = nil
        self.systemAudioFormat = nil
        self.systemFramesWritten = 0
        self.loggedFirstSystemBuffer = false
        systemTap.onAudio = { [weak self] pcm in
            // IOProc queue. Feed the level meter here (it hops to main
            // internally + is cheap), then hand the buffer to the
            // main-actor writer — same pattern the old SCStream audio
            // path used. AVAudioFile.write off a serial source is fine.
            RecordingLevelMeter.shared.ingestSystem(pcm: pcm)
            Task { @MainActor [weak self] in
                self?.writeSystemAudioPCM(pcm)
            }
        }
        do {
            try systemTap.start()
        } catch {
            FileLogger.log("CaptureEngine.start: system audio tap failed: \(error.localizedDescription). Recording mic-only.")
        }

        // 7. Mark recording state
        self.isRecording = true
        self.startedAt = Date()
        self.meetingId = meetingId
        self.videoURL = videoURL
        self.micURL = micURL

        FileLogger.log("CaptureEngine.start: recording state armed")

        // If a stop() arrived while we were warming up, honour it now —
        // otherwise the just-armed capture would run forever with nothing
        // ever calling stop() (the user already asked to stop / the Mac
        // went to sleep mid-start).
        if stopRequestedDuringStart {
            FileLogger.log("CaptureEngine.start: stop was requested during warm-up — tearing down immediately")
            delegate?.captureEngine(self, didStartMeeting: meetingId)
            await stop()
            return
        }

        delegate?.captureEngine(self, didStartMeeting: meetingId)
    }

    func stop() async {
        // Called mid-warm-up: defer the real teardown to start()'s tail
        // (the stream/tap/files aren't fully armed yet to tear down safely).
        if starting, !isRecording {
            FileLogger.log("CaptureEngine.stop: arrived during start warm-up — deferring to start() tail")
            stopRequestedDuringStart = true
            return
        }
        guard isRecording, let id = meetingId else { return }
        // Latch teardown BEFORE the first await so any tap/SCK buffer
        // whose main-actor Task is already queued (or fires during the
        // async stopCapture) drops instead of reopening a truncated
        // file. See `tearingDown`.
        tearingDown = true
        FileLogger.log("CaptureEngine.stop: meetingId=\(id)")

        // Stop SCStream. Order matters: detach our outputs FIRST,
        // then stopCapture, then drop the reference. Without the
        // explicit removeStreamOutput calls, macOS keeps the
        // System-Audio-Recording privacy indicator (purple dot in
        // Control Center) lit indefinitely after stop — the captured
        // session is "completed" but the registered handlers count
        // as live consumers of system audio in TCC's view.
        if let stream = stream {
            try? stream.removeStreamOutput(self, type: .screen)
            if sckSystemURL != nil {
                try? stream.removeStreamOutput(self, type: .audio)
            }
            do { try await stream.stopCapture(); FileLogger.log("CaptureEngine.stop: SCStream stopped") }
            catch { FileLogger.log("CaptureEngine.stop: SCStream.stopCapture error: \(error)") }
        }
        stream = nil

        // Stop the system-audio process tap and tear down its private
        // aggregate device. Done before closing systemAudioFile so no
        // in-flight IOProc callback writes after the file is nil'd.
        systemTap.stop()

        // Stop microphone — removeTap before stop, then reset() so
        // the engine fully relinquishes its grip on the input device
        // (otherwise the orange mic indicator can also linger).
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine?.reset()
        audioEngine = nil
        micFile = nil
        FileLogger.log("CaptureEngine.stop: mic frames captured = \(micFramesWritten)")
        FileLogger.log("CaptureEngine.stop: system frames captured = \(systemFramesWritten) (BT/SCO scenario shows 0 here)")

        // Close system audio file so it's safe to read for transcription.
        systemAudioFile = nil
        systemAudioFormat = nil

        // Close the secondary SCStream-audio file (Bluetooth-output
        // backup). Logged separately so the log shows which of the two
        // system tracks actually carried signal this session.
        FileLogger.log("CaptureEngine.stop: SCStream-audio frames captured = \(sckFramesWritten) (system_sck.wav; backup for BT-output runs)")
        sckAudioFile = nil
        sckSystemURL = nil

        // Finalise the video writer if we have one. finishWriting is async
        // and can take a moment to flush the trailer; we wait for it so
        // the .mov is fully written by the time stop() returns and the
        // Dropbox archive task picks the file up.
        if let writer = videoWriter, writer.status == .writing {
            videoInput?.markAsFinished()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    FileLogger.log("CaptureEngine.stop: video.mov finalised, frames=\(self.videoFramesAppended), status=\(writer.status.rawValue)")
                    cont.resume()
                }
            }
        } else if let writer = videoWriter {
            FileLogger.log("CaptureEngine.stop: skipping video finalise; writer status=\(writer.status.rawValue)")
        }
        videoWriter = nil
        videoInput = nil
        videoSessionStarted = false

        isRecording = false
        FileLogger.log("CaptureEngine.stop: complete")
        delegate?.captureEngine(self, didStopMeeting: id)

        meetingId = nil
        startedAt = nil
        videoURL = nil
        micURL = nil
        systemURL = nil
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit also emits "no-pixel" sample buffers (status =
            // .idle, .blank, .suspended) when the screen content hasn't
            // changed. We only want frames with actual image data.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let first = attachments.first,
               let statusRaw = first[SCStreamFrameInfo.status as CFString] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw),
               status != .complete {
                return
            }
            Task { @MainActor [weak self] in
                self?.writeVideo(sampleBuffer)
            }
        case .audio:
            // Secondary system-audio backup (see sckSystemURL doc). The
            // CMSampleBuffer is CF-retained by the closure capture, so
            // it stays valid across the main-actor hop.
            Task { @MainActor [weak self] in
                self?.writeSCKAudio(sampleBuffer)
            }
        default:
            break
        }
    }

    @MainActor
    private func writeVideo(_ buffer: CMSampleBuffer) {
        guard let writer = videoWriter, let input = videoInput else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                FileLogger.log("CaptureEngine.writeVideo: writer failed: \(writer.error?.localizedDescription ?? "?")")
                videoWriter = nil
                videoInput = nil
            }
            return
        }
        if !videoSessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            writer.startSession(atSourceTime: pts)
            videoSessionStarted = true
            FileLogger.log("CaptureEngine.writeVideo: session started at \(pts.seconds)s")
        }
        // Drop frames silently when the encoder is backed up. Better a
        // skipped frame than blocking SCStream's delivery queue.
        guard input.isReadyForMoreMediaData else { return }
        if input.append(buffer) {
            videoFramesAppended &+= 1
        }
    }

    /// Tap-buffer sink, hopped to the main actor (mirrors the old
    /// SCStream `.audio` → writeSystemAudio path). The tap's IOProc is a
    /// single serial queue, so even with the hop the buffers stay
    /// ordered.
    @MainActor
    private func writeSystemAudioPCM(_ pcm: AVAudioPCMBuffer) {
        guard let url = systemURL, let format = systemTap.format else { return }
        if systemAudioFile == nil {
            // nil + tearing down = file was already closed by stop().
            // Reopening here truncates the finished recording — drop.
            guard !tearingDown else { return }
            do {
                let file = try AVAudioFile(forWriting: url,
                                           settings: format.settings,
                                           commonFormat: format.commonFormat,
                                           interleaved: format.isInterleaved)
                self.systemAudioFile = file
                self.systemAudioFormat = format
                FileLogger.log("CaptureEngine: opened system.wav (\(format.sampleRate) Hz, \(format.channelCount) ch, via process tap)")
            } catch {
                FileLogger.log("CaptureEngine: failed to open system.wav: \(error)")
                return
            }
        }
        guard let file = systemAudioFile else { return }
        if !loggedFirstSystemBuffer {
            loggedFirstSystemBuffer = true
            FileLogger.log("CaptureEngine: first system audio buffer arrived (frames=\(pcm.frameLength))")
        }
        do {
            try file.write(from: pcm)
            systemFramesWritten &+= Int64(pcm.frameLength)
        } catch {
            FileLogger.log("CaptureEngine: system.wav write error: \(error)")
        }
    }

    /// SCStream `.audio` sink → system_sck.wav (Bluetooth-output backup
    /// for the process tap). Mirrors writeSystemAudioPCM but takes the
    /// format from the sample buffer (SCStream picks 48 k stereo float)
    /// and copies via a retained block buffer. Intentionally does NOT
    /// touch RecordingLevelMeter — see the sckSystemURL doc comment.
    @MainActor
    private func writeSCKAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let url = sckSystemURL else { return }
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let format = AVAudioFormat(streamDescription: asbdPtr) else { return }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        pcm.frameLength = AVAudioFrameCount(numSamples)

        // Fill the PCM buffer's AudioBufferList from the sample buffer.
        // The retained block buffer is held until this function returns,
        // which keeps the memory the ABL points at valid for write().
        let abl = pcm.mutableAudioBufferList
        let ablSize = MemoryLayout<AudioBufferList>.size
            + (Int(abl.pointee.mNumberBuffers) - 1) * MemoryLayout<AudioBuffer>.size
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, blockBuffer != nil else {
            if !loggedFirstSCKBuffer {
                FileLogger.log("CaptureEngine: SCK audio buffer-list extraction failed (\(status))")
            }
            return
        }

        if sckAudioFile == nil {
            // Same teardown guard as the tap path — a late SCK buffer
            // must not re-create (truncate) system_sck.wav after stop.
            guard !tearingDown else { return }
            do {
                let file = try AVAudioFile(forWriting: url,
                                           settings: format.settings,
                                           commonFormat: format.commonFormat,
                                           interleaved: format.isInterleaved)
                self.sckAudioFile = file
                FileLogger.log("CaptureEngine: opened system_sck.wav (\(format.sampleRate) Hz, \(format.channelCount) ch, via SCStream .audio)")
            } catch {
                FileLogger.log("CaptureEngine: failed to open system_sck.wav: \(error)")
                return
            }
        }
        guard let file = sckAudioFile else { return }
        if !loggedFirstSCKBuffer {
            loggedFirstSCKBuffer = true
            FileLogger.log("CaptureEngine: first SCStream-audio buffer arrived (frames=\(numSamples))")
        }
        do {
            try file.write(from: pcm)
            sckFramesWritten &+= Int64(numSamples)
        } catch {
            FileLogger.log("CaptureEngine: system_sck.wav write error: \(error)")
        }
    }
}

// MARK: - SCStreamDelegate

extension CaptureEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.captureEngine(self, didFailWithError: error)
        }
    }
}
