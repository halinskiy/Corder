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

    // System audio captured by SCStream is mirrored into a standalone .wav so
    // transcription does not depend on AVAssetWriter finalising the .mov.
    private var systemAudioFile: AVAudioFile?
    private var systemAudioFormat: AVAudioFormat?
    // Diagnostic counter for SCStream's `.audio` output. If this stays at
    // 0 across a recording, ScreenCaptureKit didn't deliver a single
    // system-audio buffer — typically reproducible when output is on
    // Bluetooth headphones (SCO mode), which is exactly the broken
    // scenario users hit on Meet/Zoom calls.
    private var systemFramesWritten: Int64 = 0
    private var loggedFirstSystemBuffer = false

    func start(meetingId: String, source: CaptureSource) async throws {
        FileLogger.log("CaptureEngine.start: meetingId=\(meetingId) source=\(source)")
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
        FileLogger.log("CaptureEngine.start: dir=\(dir.path)")

        // Remove any leftovers from a previous failed run
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

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

        // 4. SCStream — try with audio first, retry without on failure.
        // "Stream failed to start audio" happens with some Bluetooth/AirPods
        // setups. We'd rather have a recording with mic-only than a hard fail.
        var activeStream = SCStream(filter: filter, configuration: config, delegate: self)
        try activeStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try activeStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        FileLogger.log("CaptureEngine.start: SCStream configured (capturesAudio=\(config.capturesAudio))")

        do {
            try await activeStream.startCapture()
            FileLogger.log("CaptureEngine.start: SCStream.startCapture OK (with audio)")
        } catch {
            FileLogger.log("CaptureEngine.start: SCStream startCapture FAILED with audio: \(error). Retrying without system audio…")
            config.capturesAudio = false
            activeStream = SCStream(filter: filter, configuration: config, delegate: self)
            try activeStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await activeStream.startCapture()
            FileLogger.log("CaptureEngine.start: SCStream.startCapture OK (video-only fallback). system.wav will be empty — only mic will be transcribed.")
        }
        self.stream = activeStream

        // 5. Microphone via AVAudioEngine.installTap on the default input.
        //    This is the only path now (no more SCStream.microphone) — see
        //    the comment on `capturesAudio` above for why.
        self.micURL = micURL
        self.micFile = nil
        self.micFramesWritten = 0
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        FileLogger.log("CaptureEngine.start: mic via AVAudioEngine; format \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
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

        // 6. system.wav — opened lazily on first SCStream audio buffer (we need
        // the actual AudioStreamBasicDescription from the buffer to create the file).
        self.systemURL = systemURL
        self.systemAudioFile = nil
        self.systemAudioFormat = nil
        self.systemFramesWritten = 0
        self.loggedFirstSystemBuffer = false

        // 7. Mark recording state
        self.isRecording = true
        self.startedAt = Date()
        self.meetingId = meetingId
        self.videoURL = videoURL
        self.micURL = micURL

        FileLogger.log("CaptureEngine.start: recording state armed")
        delegate?.captureEngine(self, didStartMeeting: meetingId)
    }

    func stop() async {
        guard isRecording, let id = meetingId else { return }
        FileLogger.log("CaptureEngine.stop: meetingId=\(id)")

        // Stop SCStream. Order matters: detach our outputs FIRST,
        // then stopCapture, then drop the reference. Without the
        // explicit removeStreamOutput calls, macOS keeps the
        // System-Audio-Recording privacy indicator (purple dot in
        // Control Center) lit indefinitely after stop — the captured
        // session is "completed" but the registered handlers count
        // as live consumers of system audio in TCC's view.
        if let stream = stream {
            try? stream.removeStreamOutput(self, type: .audio)
            try? stream.removeStreamOutput(self, type: .screen)
            do { try await stream.stopCapture(); FileLogger.log("CaptureEngine.stop: SCStream stopped") }
            catch { FileLogger.log("CaptureEngine.stop: SCStream.stopCapture error: \(error)") }
        }
        stream = nil

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
        case .audio:
            // Feed the level meter from the audio thread directly —
            // peak() doesn't touch the main actor, so the floating HUD
            // gets system-audio movement without waiting on the same
            // hop the file write needs.
            RecordingLevelMeter.shared.ingestSystem(sample: sampleBuffer)
            Task { @MainActor [weak self] in
                self?.writeSystemAudio(sampleBuffer)
            }
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

    @MainActor
    private func writeSystemAudio(_ buffer: CMSampleBuffer) {
        guard let url = systemURL else { return }
        // Lazy-open the file using the format from the first buffer we see.
        if systemAudioFile == nil {
            guard let formatDesc = CMSampleBufferGetFormatDescription(buffer),
                  var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
                  let format = AVAudioFormat(streamDescription: &asbd) else { return }
            do {
                let file = try AVAudioFile(forWriting: url,
                                           settings: format.settings,
                                           commonFormat: format.commonFormat,
                                           interleaved: format.isInterleaved)
                self.systemAudioFile = file
                self.systemAudioFormat = format
                FileLogger.log("CaptureEngine: opened system.wav (\(format.sampleRate) Hz, \(format.channelCount) ch)")
            } catch {
                FileLogger.log("CaptureEngine: failed to open system.wav: \(error)")
                return
            }
        }
        guard let format = systemAudioFormat,
              let file = systemAudioFile else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else {
            FileLogger.log("CaptureEngine: CMSampleBufferCopy returned \(status)")
            return
        }
        if !loggedFirstSystemBuffer {
            loggedFirstSystemBuffer = true
            FileLogger.log("CaptureEngine: first system audio buffer arrived (frames=\(frames))")
        }
        do {
            try file.write(from: pcm)
            systemFramesWritten &+= Int64(frames)
        } catch {
            FileLogger.log("CaptureEngine: system.wav write error: \(error)")
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
