import AppKit
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

protocol CaptureEngineDelegate: AnyObject {
    @MainActor func captureEngine(_ engine: CaptureEngine, didStartMeeting id: String)
    @MainActor func captureEngine(_ engine: CaptureEngine, didStopMeeting id: String)
    @MainActor func captureEngine(_ engine: CaptureEngine, didFailWithError error: Error)
}

enum CaptureError: Error, LocalizedError {
    case alreadyRecording
    case noDisplay
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Already recording"
        case .noDisplay: return "No displays available"
        case .writerFailed(let msg): return "AVAssetWriter failed: \(msg)"
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

    // Asset writer state — accessed from outputQueue
    private var writerState = WriterState()

    // Microphone via AVAudioEngine — runs on its own thread
    private var audioEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    // Diagnostic: how many sample frames the tap actually delivered. If this
    // stays at 0 across a recording, AVAudioEngine isn't getting any audio
    // (mic disabled / device race with Telegram / etc.).
    private var micFramesWritten: Int64 = 0

    // System audio captured by SCStream is mirrored into a standalone .wav so
    // transcription does not depend on AVAssetWriter finalising the .mov.
    private var systemAudioFile: AVAudioFile?
    private var systemAudioFormat: AVAudioFormat?

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
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // ScreenCaptureKit microphone capture (macOS 15+). Routes through the
        // same shared system tap as the rest of SCStream, so it doesn't fight
        // with apps like Telegram for exclusive mic access — which silently
        // killed the AVAudioEngine path during voice-message recording.
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }

        // 3. AVAssetWriter is intentionally NOT created.
        // Empirically AVAssetWriter on this macOS build chokes on every
        // configuration we tried (BGRA→YUV, mov/mp4, AAC/PCM/no audio):
        // it flips to .failed within ~1 s with -11800 / -16122 even for a
        // plain video-only mp4. The recording's source of truth is the
        // separately-written system.wav + mic.wav (Whisper → transcript,
        // Dropbox → archive). Video would be a nice-to-have but not worth
        // a brittle, half-working .mov that leaves zero-byte files behind.
        // The frontend treats absence of video as "audio-only" and falls
        // back to the parallel <audio> element.
        writerState = WriterState()

        // 4. SCStream — try with audio first, retry without on failure.
        // "Stream failed to start audio" happens with some Bluetooth/AirPods
        // setups. We'd rather have a recording with mic-only than a hard fail.
        var activeStream = SCStream(filter: filter, configuration: config, delegate: self)
        try activeStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try activeStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        if #available(macOS 15.0, *), config.captureMicrophone {
            try activeStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        }
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

        // 5. Microphone:
        //    * Primary path on macOS 15+ — SCStream's `.microphone` output,
        //      already wired above. mic.wav is opened lazily in writeMicAudio
        //      from the first sample's actual ASBD (no race with other apps).
        //    * Legacy path on macOS 13/14 — AVAudioEngine.installTap. Falls
        //      back to lossy default-input behaviour but keeps older systems
        //      working.
        self.micURL = micURL
        self.micFile = nil
        self.micFramesWritten = 0
        if #available(macOS 15.0, *), config.captureMicrophone {
            FileLogger.log("CaptureEngine.start: mic via SCStream (macOS 15+)")
        } else {
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
            }
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
        }

        // 6. system.wav — opened lazily on first SCStream audio buffer (we need
        // the actual AudioStreamBasicDescription from the buffer to create the file).
        self.systemURL = systemURL
        self.systemAudioFile = nil
        self.systemAudioFormat = nil

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

        // Stop SCStream
        if let stream = stream {
            do { try await stream.stopCapture(); FileLogger.log("CaptureEngine.stop: SCStream stopped") }
            catch { FileLogger.log("CaptureEngine.stop: SCStream.stopCapture error: \(error)") }
        }
        stream = nil

        // Stop microphone
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micFile = nil
        FileLogger.log("CaptureEngine.stop: mic frames captured = \(micFramesWritten)")

        // Close system audio file so it's safe to read for transcription.
        systemAudioFile = nil
        systemAudioFormat = nil

        // Finalize asset writer
        let writer = writerState.writer
        let videoInput = writerState.video
        let audioInput = writerState.audio
        writerState = WriterState()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            outputQueue.async {
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                if let writer = writer {
                    writer.finishWriting {
                        FileLogger.log("CaptureEngine.stop: AVAssetWriter finishWriting completed (status=\(writer.status.rawValue))")
                        if let err = writer.error {
                            FileLogger.log("CaptureEngine.stop: AVAssetWriter error: \(err)")
                        }
                        cont.resume()
                    }
                } else {
                    cont.resume()
                }
            }
        }

        isRecording = false
        FileLogger.log("CaptureEngine.stop: complete")
        delegate?.captureEngine(self, didStopMeeting: id)

        meetingId = nil
        startedAt = nil
        videoURL = nil
        micURL = nil
        systemURL = nil
    }

    // MARK: - Internal state

    private struct WriterState {
        var writer: AVAssetWriter?
        var video: AVAssetWriterInput?
        var audio: AVAssetWriterInput?
        var failureLogged: Bool = false
        var sessionStartedPts: CMTime?
        var firstVideoFormatLogged: Bool = false
        var firstAudioFormatLogged: Bool = false
        var sessionStarted: Bool = false
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        Task { @MainActor [weak self] in
            self?.handleSample(sampleBuffer, type: type, pts: pts)
        }
    }

    @MainActor
    private func handleSample(_ buffer: CMSampleBuffer, type: SCStreamOutputType, pts: CMTime) {
        // 1. Audio is mirrored to standalone .wav files unconditionally —
        //    the .mov writer is best-effort, but system.wav + mic.wav are
        //    what the transcription pipeline actually consumes, so they must
        //    keep going even if AVAssetWriter fails.
        if type == .audio {
            writeSystemAudio(buffer)
        }
        if #available(macOS 15.0, *), type == .microphone {
            writeMicAudio(buffer)
        }

        // 2. Forward to AVAssetWriter only if it's still healthy.
        guard let writer = writerState.writer else { return }
        if writer.status == .failed {
            // Log once and stop trying — the .mov is dead, but transcription
            // continues from system.wav + mic.wav so the meeting still works.
            if !writerState.failureLogged {
                writerState.failureLogged = true
                FileLogger.log("CaptureEngine: writer.status=failed (logged once); error=\(writer.error?.localizedDescription ?? "nil")")
            }
            return
        }
        guard writer.status == .writing else { return }

        // AVAssetWriter requires sessionStart to coincide with the first VIDEO
        // sample's PTS. If we start the session on an early audio sample,
        // subsequent video samples can carry a PTS *before* the session start
        // and the writer flips to .failed silently with -11800/-16122. So we
        // buffer audio until the first .screen sample arrives.
        if !writerState.sessionStarted {
            guard type == .screen else { return }
            writer.startSession(atSourceTime: pts)
            writerState.sessionStarted = true
            writerState.sessionStartedPts = pts
            FileLogger.log("CaptureEngine: AVAssetWriter session started at pts=\(pts.seconds)")
        }

        // Drop any audio sample whose PTS is earlier than the video session
        // start — those late buffers are exactly what flips the writer to
        // .failed with -16122 (kAudioCodecAudioFormatErr-like behaviour from
        // AAC encoder when fed out-of-order timestamps).
        if type == .audio, let start = writerState.sessionStartedPts, pts < start {
            return
        }

        switch type {
        case .screen:
            if !writerState.firstVideoFormatLogged {
                writerState.firstVideoFormatLogged = true
                if let fd = CMSampleBufferGetFormatDescription(buffer) {
                    let dims = CMVideoFormatDescriptionGetDimensions(fd)
                    FileLogger.log("CaptureEngine: first video sample \(dims.width)x\(dims.height) pts=\(pts.seconds)")
                }
            }
            if let input = writerState.video, input.isReadyForMoreMediaData {
                input.append(buffer)
            }
        case .audio:
            if !writerState.firstAudioFormatLogged {
                writerState.firstAudioFormatLogged = true
                if let fd = CMSampleBufferGetFormatDescription(buffer),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    FileLogger.log("CaptureEngine: first audio sample sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags) pts=\(pts.seconds)")
                }
            }
            if let input = writerState.audio, input.isReadyForMoreMediaData {
                input.append(buffer)
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    @MainActor
    private func writeMicAudio(_ buffer: CMSampleBuffer) {
        guard let url = micURL else { return }
        if micFile == nil {
            guard let formatDesc = CMSampleBufferGetFormatDescription(buffer),
                  var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
                  let format = AVAudioFormat(streamDescription: &asbd) else { return }
            do {
                let file = try AVAudioFile(forWriting: url,
                                           settings: format.settings,
                                           commonFormat: format.commonFormat,
                                           interleaved: format.isInterleaved)
                self.micFile = file
                FileLogger.log("CaptureEngine: opened mic.wav via SCStream (\(format.sampleRate) Hz, \(format.channelCount) ch)")
            } catch {
                FileLogger.log("CaptureEngine: failed to open mic.wav: \(error)")
                return
            }
        }
        guard let file = micFile,
              let formatDesc = CMSampleBufferGetFormatDescription(buffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else {
            FileLogger.log("CaptureEngine: mic CMSampleBufferCopy returned \(status)")
            return
        }
        do {
            try file.write(from: pcm)
            micFramesWritten &+= Int64(frames)
        } catch {
            FileLogger.log("CaptureEngine: mic.wav write error: \(error)")
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
        do { try file.write(from: pcm) }
        catch { FileLogger.log("CaptureEngine: system.wav write error: \(error)") }
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
