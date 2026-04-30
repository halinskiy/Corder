import Foundation
import WhisperKit

/// Orchestrates: mix audio → run WhisperKit → diarize per segment → write to DB.
@MainActor
final class TranscriptionPipeline {
    static let shared = TranscriptionPipeline()
    private init() {}

    private var whisper: WhisperKit?

    /// Default Whisper model. `base` downloads ~150 MB on first use, fast on Apple Silicon.
    /// Bigger options: `small`, `medium`, `large-v3-turbo`. Configurable later.
    private let modelName = "base"

    func transcribe(meetingId: String) async {
        let repo = AppContext.shared.repo
        guard var meeting = (try? repo.meeting(id: meetingId)) else { return }

        meeting.status = .transcribing
        try? repo.updateMeeting(meeting)

        do {
            // 1. Build the 16 kHz mono mix that whisper consumes.
            let dir = AppPaths.recordingDir(for: meetingId)
            let videoURL = URL(fileURLWithPath: meeting.videoPath)
            let micURL = URL(fileURLWithPath: meeting.audioPath) // currently mic.wav
            let mixURL = dir.appendingPathComponent("audio.wav")

            try await AudioMixer.produceWhisperInput(videoURL: videoURL, micURL: micURL, outputURL: mixURL)

            // 2. Lazy-init WhisperKit. First call downloads the model from HuggingFace.
            if whisper == nil {
                NSLog("Corder: loading WhisperKit '\(modelName)' (first run downloads ~150 MB)…")
                whisper = try await WhisperKit(WhisperKitConfig(model: modelName, verbose: false))
            }
            guard let pipe = whisper else { return }

            // 3. Transcribe.
            let results = try await pipe.transcribe(audioPath: mixURL.path)
            // results: [TranscriptionResult] — we get one per chunk, segments concatenated.
            let segments = results.flatMap { $0.segments }

            // 4. Diarize each segment.
            let segmentsForDiar = segments.map { (start: Double($0.start), end: Double($0.end)) }
            let decisions = (try? Diarizer.decide(segments: segmentsForDiar,
                                                  userPath: micURL,
                                                  otherPath: mixURL)) ?? []

            // 5. Persist speakers + segments. Two speakers max in this MVP.
            let userSpeakerId = "\(meetingId)-you"
            let otherSpeakerId = "\(meetingId)-other"
            try repo.insertSpeaker(Speaker(id: userSpeakerId, meetingId: meetingId,
                                           label: "Speaker 1", customName: "you", colorHex: "#3b82f6"))
            try repo.insertSpeaker(Speaker(id: otherSpeakerId, meetingId: meetingId,
                                           label: "Speaker 2", customName: nil, colorHex: "#a855f7"))

            for (idx, seg) in segments.enumerated() {
                let isUser = idx < decisions.count ? decisions[idx].isUser : false
                let speakerId = isUser ? userSpeakerId : otherSpeakerId
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try repo.insertSegment(Segment(
                    id: nil,
                    meetingId: meetingId,
                    speakerId: speakerId,
                    startMs: Int64(seg.start * 1000),
                    endMs: Int64(seg.end * 1000),
                    text: text,
                    wordsJson: nil
                ))
            }

            meeting.status = .ready
            meeting.transcribedAt = Int64(Date().timeIntervalSince1970 * 1000)
            try repo.updateMeeting(meeting)
            NSLog("Corder: transcribed \(segments.count) segments for meeting \(meetingId)")
        } catch {
            NSLog("Corder transcription error: \(error)")
            meeting.status = .failed
            try? repo.updateMeeting(meeting)
        }
    }
}
