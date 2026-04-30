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

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.3mpq.corder.scstream", qos: .userInitiated)

    // Asset writer state — accessed from outputQueue
    private var writerState = WriterState()

    // Microphone via AVAudioEngine — runs on its own thread
    private var audioEngine: AVAudioEngine?
    private var micFile: AVAudioFile?

    func start(meetingId: String, source: CaptureSource) async throws {
        guard !isRecording else { throw CaptureError.alreadyRecording }

        let dir = AppPaths.recordingDir(for: meetingId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let videoURL = dir.appendingPathComponent("video.mov")
        let micURL = dir.appendingPathComponent("mic.wav")

        // Remove any leftovers from a previous failed run
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: micURL)

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

        // 2. Configuration: source size + system audio
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(CGFloat(captureWidth) * scale)
        config.height = Int(CGFloat(captureHeight) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 fps cap
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        // 3. AVAssetWriter for video.mov (video + system audio)
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) { writer.add(audioInput) }

        guard writer.startWriting() else {
            throw CaptureError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        writerState = WriterState(writer: writer, video: videoInput, audio: audioInput)

        // 4. SCStream
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

        try await scStream.startCapture()
        self.stream = scStream

        // 5. Microphone via AVAudioEngine — written to mic.wav as float32 PCM
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let micFile = try AVAudioFile(
            forWriting: micURL,
            settings: inputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            try? self?.micFile?.write(from: buffer)
        }
        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        self.micFile = micFile

        // 6. Mark recording state
        self.isRecording = true
        self.startedAt = Date()
        self.meetingId = meetingId
        self.videoURL = videoURL
        self.micURL = micURL

        delegate?.captureEngine(self, didStartMeeting: meetingId)
    }

    func stop() async {
        guard isRecording, let id = meetingId else { return }

        // Stop SCStream
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Stop microphone
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micFile = nil

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
                    writer.finishWriting { cont.resume() }
                } else {
                    cont.resume()
                }
            }
        }

        isRecording = false
        delegate?.captureEngine(self, didStopMeeting: id)

        meetingId = nil
        startedAt = nil
        videoURL = nil
        micURL = nil
    }

    // MARK: - Internal state

    private struct WriterState {
        var writer: AVAssetWriter?
        var video: AVAssetWriterInput?
        var audio: AVAssetWriterInput?
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
        guard let writer = writerState.writer,
              writer.status == .writing else { return }

        if !writerState.sessionStarted {
            writer.startSession(atSourceTime: pts)
            writerState.sessionStarted = true
        }

        switch type {
        case .screen:
            if let input = writerState.video, input.isReadyForMoreMediaData {
                input.append(buffer)
            }
        case .audio:
            if let input = writerState.audio, input.isReadyForMoreMediaData {
                input.append(buffer)
            }
        case .microphone:
            break // not used; mic comes from AVAudioEngine
        @unknown default:
            break
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
