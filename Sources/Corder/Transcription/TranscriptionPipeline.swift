import Foundation
import WhisperKit

/// Orchestrates: mix audio → run WhisperKit → diarize per segment → write to DB.
@MainActor
final class TranscriptionPipeline {
    static let shared = TranscriptionPipeline()
    private init() {}

    private var whisper: WhisperKit?

    /// `large-v3` — ~1.5 GB, multilingual, top-of-line accuracy. We previously
    /// retreated to `medium` because long recordings would hang, but the real
    /// fix is chunking: with `.vad` chunking strategy WhisperKit splits the
    /// audio on voice-activity boundaries and processes each chunk in isolation,
    /// so length stops being a problem.
    private let modelName = "large-v3"

    /// Kick off WhisperKit init in the background at app launch so the model
    /// finishes downloading and warming up before the user records anything.
    func prewarm() {
        guard whisper == nil else { return }
        FileLogger.log("TranscriptionPipeline.prewarm: starting WhisperKit '\(modelName)' download/warm-up…")
        Task { @MainActor in
            do {
                whisper = try await WhisperKit(WhisperKitConfig(model: modelName, verbose: false))
                FileLogger.log("TranscriptionPipeline.prewarm: WhisperKit ready")
            } catch {
                FileLogger.log("TranscriptionPipeline.prewarm: WhisperKit init failed: \(error)")
            }
        }
        // Diarization models in parallel — first meeting otherwise pays the
        // ~30 MB FluidAudio download.
        Task.detached {
            do {
                _ = try await Diarizer.warmUp()
                FileLogger.log("TranscriptionPipeline.prewarm: FluidAudio diarizer ready")
            } catch {
                FileLogger.log("TranscriptionPipeline.prewarm: FluidAudio warm-up failed: \(error)")
            }
        }
    }

    func transcribe(meetingId: String) async {
        FileLogger.log("transcribe(): START for \(meetingId)")
        let repo = AppContext.shared.repo
        guard var meeting = (try? repo.meeting(id: meetingId)) else {
            FileLogger.log("transcribe(): meeting \(meetingId) not found in DB")
            return
        }

        // Clear any prior transcript rows so retranscribe is idempotent.
        try? repo.clearTranscript(meetingId: meetingId)

        meeting.status = .transcribing
        try? repo.updateMeeting(meeting)

        do {
            // 1. Build the 16 kHz mono mix that whisper consumes.
            let dir = AppPaths.recordingDir(for: meetingId)
            let micURL = URL(fileURLWithPath: meeting.audioPath) // mic.wav
            let systemURL = dir.appendingPathComponent("system.wav")
            let mixURL = dir.appendingPathComponent("audio.wav")

            // If this meeting was archived and its local sources are gone,
            // pull the mixed audio.wav back from Dropbox so Whisper has
            // something to chew on (retranscribe scenario).
            if !FileManager.default.fileExists(atPath: micURL.path),
               !FileManager.default.fileExists(atPath: mixURL.path),
               let remote = meeting.dropboxAudioPath {
                FileLogger.log("transcribe(): local audio missing, downloading mix from Dropbox \(remote)")
                try await DropboxService.shared.download(remotePath: remote, to: mixURL)
            }

            // Skip mixing if the mix is already on disk (e.g. just downloaded).
            if !FileManager.default.fileExists(atPath: mixURL.path) {
                FileLogger.log("transcribe(): mixing system=system.wav mic=\(micURL.lastPathComponent) → \(mixURL.lastPathComponent)")
                try await AudioMixer.produceWhisperInput(systemURL: systemURL, micURL: micURL, outputURL: mixURL)
            }
            FileLogger.log("transcribe(): mix produced, size=\(((try? FileManager.default.attributesOfItem(atPath: mixURL.path)[.size]) as? NSNumber)?.intValue ?? -1)")

            // 2. Lazy-init WhisperKit. First call downloads the model from HuggingFace.
            if whisper == nil {
                FileLogger.log("transcribe(): loading WhisperKit '\(modelName)' (first run downloads ~150 MB)…")
                whisper = try await WhisperKit(WhisperKitConfig(model: modelName, verbose: true))
                FileLogger.log("transcribe(): WhisperKit ready")
            }
            guard let pipe = whisper else { return }

            // 3. Transcribe with explicit language hint and VAD chunking. The
            // chunking is what lets `large-v3` handle 4-minute+ recordings
            // without hanging — the audio is split on natural pauses and each
            // chunk decoded independently. We bias to Russian, large-v3 is
            // multilingual so English passages still come through correctly.
            let decodeOptions = DecodingOptions(
                verbose: true,
                task: .transcribe,
                language: "ru",
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                chunkingStrategy: .vad
            )
            FileLogger.log("transcribe(): calling pipe.transcribe with language=ru, vad chunking …")
            let results = try await pipe.transcribe(audioPath: mixURL.path, decodeOptions: decodeOptions)
            FileLogger.log("transcribe(): pipe returned \(results.count) result(s)")
            // results: [TranscriptionResult] — we get one per chunk, segments concatenated.
            let segments = results.flatMap { $0.segments }

            // 4. Diarize each segment. Channel-gate (mic vs system RMS) splits
            //    user from remote, and FluidAudio runs only on the remote
            //    stream so the user's voice is never in the clustering pool.
            let segmentsForDiar = segments.map { (start: Double($0.start), end: Double($0.end)) }
            var decisions: [Diarizer.Decision] = []
            do {
                decisions = try await Diarizer.decide(segments: segmentsForDiar,
                                                      userPath: micURL,
                                                      otherPath: systemURL)
            } catch {
                FileLogger.log("transcribe(): diarizer failed: \(error). Falling back to single-speaker assignment.")
            }
            FileLogger.log("transcribe(): diarizer returned \(decisions.count) decisions, unique speakers=\(Set(decisions.map { $0.speakerKey }).count)")

            // 5. Build speakers on-the-fly from the unique speaker keys we saw.
            //    "user" is fixed; "other-N" become Speaker 2, 3, …
            let userSpeakerId = "\(meetingId)-you"
            try repo.insertSpeaker(Speaker(id: userSpeakerId, meetingId: meetingId,
                                           label: "Speaker 1", customName: "you", colorHex: "#3b82f6"))

            // Pre-create rows for every distinct other-N we observed so the
            // sidebar's speaker_count is accurate even before any segment loops.
            var otherSpeakerIds: [String: String] = [:]
            let otherKeys = decisions.map { $0.speakerKey }.filter { $0 != "user" }
            let uniqueOtherKeys = Array(Set(otherKeys)).sorted() // "other-0", "other-1", …
            for (i, key) in uniqueOtherKeys.enumerated() {
                let id = "\(meetingId)-\(key)"
                otherSpeakerIds[key] = id
                let label = "Speaker \(i + 2)"
                try repo.insertSpeaker(Speaker(id: id, meetingId: meetingId,
                                               label: label, customName: nil,
                                               colorHex: otherColorHex(index: i)))
            }

            for (idx, seg) in segments.enumerated() {
                let key = idx < decisions.count ? decisions[idx].speakerKey : "other-0"
                let speakerId: String
                if key == "user" {
                    speakerId = userSpeakerId
                } else if let id = otherSpeakerIds[key] {
                    speakerId = id
                } else {
                    // Defensive: unseen key, drop into the first "other" bucket.
                    speakerId = otherSpeakerIds[uniqueOtherKeys.first ?? "other-0"] ?? userSpeakerId
                }
                let text = stripWhisperTokens(seg.text)
                guard !text.isEmpty else { continue }
                guard !isHallucination(text) else {
                    FileLogger.log("transcribe(): dropping Whisper hallucination: \(text)")
                    continue
                }
                try repo.insertSegment(Segment(
                    id: nil,
                    meetingId: meetingId,
                    speakerId: speakerId,
                    startMs: Int64(seg.start * 1000),
                    endMs: Int64(seg.end * 1000),
                    text: text,
                    wordsJson: nil,
                    textBoost: nil
                ))
            }

            meeting.status = .ready
            meeting.transcribedAt = Int64(Date().timeIntervalSince1970 * 1000)
            try repo.updateMeeting(meeting)
            FileLogger.log("Corder: transcribed \(segments.count) segments for meeting \(meetingId)")

            // Archive video + mixed audio to Dropbox in the background, then
            // delete local files. We hold the local copies until upload succeeds
            // so the user can scrub and copy in the meantime.
            if DropboxService.shared.isConfigured {
                let mid = meetingId
                let videoURL = URL(fileURLWithPath: meeting.videoPath)
                let mixCopy = mixURL
                let micCopy = micURL
                let systemCopy = systemURL
                let repoRef = repo
                Task.detached {
                    do {
                        let root = try await DropboxService.shared.remoteRoot()
                        let videoRemote = "\(root)/\(mid)/video.mov"
                        let audioRemote = "\(root)/\(mid)/audio.wav"

                        FileLogger.log("dropbox: uploading video for \(mid)…")
                        let v: String
                        if FileManager.default.fileExists(atPath: videoURL.path) {
                            v = try await DropboxService.shared.upload(localFile: videoURL, remotePath: videoRemote)
                        } else {
                            // Already archived in a previous run — keep the existing remote path.
                            v = videoRemote
                        }
                        FileLogger.log("dropbox: video at \(v)")

                        FileLogger.log("dropbox: uploading audio for \(mid)…")
                        let a: String
                        if FileManager.default.fileExists(atPath: mixCopy.path) {
                            a = try await DropboxService.shared.upload(localFile: mixCopy, remotePath: audioRemote)
                        } else {
                            a = audioRemote
                        }
                        FileLogger.log("dropbox: audio at \(a)")

                        try repoRef.setDropboxArchive(
                            meetingId: mid,
                            videoPath: v,
                            audioPath: a,
                            uploadedAt: Int64(Date().timeIntervalSince1970 * 1000)
                        )

                        // Delete local copies — user asked for cloud-only storage.
                        for url in [videoURL, mixCopy, micCopy, systemCopy] {
                            try? FileManager.default.removeItem(at: url)
                        }
                        FileLogger.log("dropbox: local files cleaned for \(mid)")
                    } catch {
                        FileLogger.log("dropbox: archive failed for \(mid): \(error)")
                    }
                }
            }

            // If global Boost mode is on, auto-polish every segment via Gemini.
            // Fire-and-forget — the UI polls /api/meetings/:id and renders
            // text_boost as soon as it lands per-segment.
            if BoostMode.isEnabled {
                let repoRef = repo
                let mid = meetingId
                FileLogger.log("transcribe(): boost mode ON — auto-running Gemini for \(mid)")
                Task.detached {
                    do {
                        let segs = try repoRef.segments(forMeeting: mid)
                        let pairs: [(id: Int64, text: String)] = segs.compactMap {
                            guard let sid = $0.id else { return nil }
                            return (id: sid, text: $0.text)
                        }
                        guard !pairs.isEmpty else { return }
                        let map = try await BoostService.boostSegments(pairs)
                        for (sid, polished) in map {
                            try? repoRef.setSegmentBoost(segmentId: sid, text: polished)
                        }
                        FileLogger.log("transcribe(): auto-boost done for \(mid), \(map.count)/\(pairs.count) polished")
                    } catch {
                        FileLogger.log("transcribe(): auto-boost failed for \(mid): \(error)")
                    }
                }
            }
        } catch {
            FileLogger.log("Corder transcription error: \(error)")
            meeting.status = .failed
            try? repo.updateMeeting(meeting)
        }
    }

    /// Distinct hues for the "other" speakers. We deliberately pick high-contrast
    /// colours that read well on the white library background.
    private func otherColorHex(index: Int) -> String {
        let palette = ["#a855f7", "#d97706", "#1d4ed8", "#0d9488", "#be123c"]
        return palette[index % palette.count]
    }

    /// Whisper hallucinates stock YouTube-subtitle phrases on silent or noisy
    /// segments — the multilingual model was trained on a lot of subtitle data.
    /// "Субтитры сделал DimaTorzok", "Продолжение следует…", "Спасибо за
    /// просмотр!" etc. all show up reliably on long silences. We drop any
    /// segment whose normalised text matches one of these known phrases.
    private static let hallucinationPatterns: [String] = [
        "субтитры сделал dimatorzok",
        "субтитры подготовил dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры подобрал dimatorzok",
        "субтитры от dimatorzok",
        "продолжение следует",
        "спасибо за просмотр",
        "спасибо за внимание",
        "не забудьте подписаться",
        "подписывайтесь на канал",
        "ставьте лайк",
    ]

    /// Wipes hallucinated segments from previously-transcribed meetings so the
    /// user doesn't have to re-run Whisper just to see them disappear. Called
    /// once at app launch from AppDelegate.
    static func purgeKnownHallucinations(repo: MeetingRepository) {
        do {
            let segs = try repo.allSegments()
            let pipeline = TranscriptionPipeline.shared
            let badIds = segs.compactMap { s -> Int64? in
                guard let id = s.id else { return nil }
                return pipeline.isHallucination(s.text) ? id : nil
            }
            if !badIds.isEmpty {
                try repo.deleteSegments(ids: badIds)
                FileLogger.log("startup: purged \(badIds.count) hallucinated segments from existing transcripts")
            }
        } catch {
            FileLogger.log("startup: purgeKnownHallucinations failed: \(error)")
        }
    }

    private func isHallucination(_ text: String) -> Bool {
        // Normalise: lowercase, drop non-alphanumeric so "...!" / extra spaces /
        // leading dashes don't sneak past the match.
        let lower = text.lowercased()
        let stripped = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let normalised = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        for pat in Self.hallucinationPatterns {
            if normalised.contains(pat) { return true }
        }
        return false
    }

    /// Whisper segment text contains special tokens like `<|startoftranscript|>`,
    /// `<|en|>`, `<|transcribe|>`, `<|0.00|>` (timestamps). Strip them so the
    /// stored transcript is plain readable text.
    private func stripWhisperTokens(_ raw: String) -> String {
        var s = raw
        // Remove anything in <|...|> form.
        if let regex = try? NSRegularExpression(pattern: "<\\|[^|>]*\\|>") {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
