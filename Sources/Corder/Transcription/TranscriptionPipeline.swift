import Foundation
import CryptoKit

/// Drives the post-recording pipeline: mix audio → Gemini transcribe →
/// channel-gate "user" identification → DB writes → optional auto-Boost
/// + Dropbox archive.
///
/// This used to fork between Gemini (cloud) and WhisperKit (local). The
/// local path was retired in v0.7 — running 1.5 GB of CoreML on every
/// install was bloating the bundle and the quality vs Gemini Flash on
/// Russian + English mixed audio was just worse. The cloud path is now
/// the only path.
@MainActor
final class TranscriptionPipeline {
    static let shared = TranscriptionPipeline()
    private init() {}

    /// In-flight tasks keyed by meetingId. Lets the UI cancel a running
    /// pipeline (Stop transcription button → POST /cancel-transcription
    /// → cancel(meetingId:)). The HTTP-level upload to Gemini isn't itself
    /// cancellation-aware, but `Task.cancel()` propagates between stages
    /// so the meeting flips to .failed promptly even if the upload keeps
    /// running for a few more seconds in the background.
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// No-op kept for backwards compatibility with `AppDelegate`.
    /// Whisper used to need a 1.5 GB cold-start download; Gemini Flash is
    /// stateless on our side, so there's nothing to warm up any more.
    func prewarm() {
        FileLogger.log("TranscriptionPipeline.prewarm: no-op (cloud-only)")
    }

    /// Schedule a transcription as a tracked Task so it can be cancelled
    /// later. Replaces direct `await transcribe(meetingId:)` call sites.
    @discardableResult
    func enqueue(meetingId: String) -> Task<Void, Never> {
        if let existing = activeTasks[meetingId] {
            existing.cancel()
        }
        let task = Task { @MainActor [weak self] in
            await self?.transcribe(meetingId: meetingId)
            self?.activeTasks[meetingId] = nil
        }
        activeTasks[meetingId] = task
        return task
    }

    /// Cancel a running transcription. Marks the meeting as `.failed` so
    /// the UI flips out of the loader state immediately; the underlying
    /// Task is cancelled, but Gemini upload may run for a few more
    /// seconds — we ignore its eventual result via `catch is
    /// CancellationError` in `transcribe()`.
    func cancel(meetingId: String) {
        guard let task = activeTasks[meetingId] else {
            FileLogger.log("cancel(): no active task for \(meetingId)")
            return
        }
        FileLogger.log("cancel(): cancelling transcription for \(meetingId)")
        task.cancel()
        activeTasks[meetingId] = nil
        let repo = AppContext.shared.repo
        if var meeting = (try? repo.meeting(id: meetingId)) {
            meeting.status = .failed
            try? repo.updateMeeting(meeting)
        }
    }

    func transcribe(meetingId: String) async {
        FileLogger.log("transcribe(): START for \(meetingId)")
        let repo = AppContext.shared.repo
        guard var meeting = (try? repo.meeting(id: meetingId)) else {
            FileLogger.log("transcribe(): meeting \(meetingId) not found in DB")
            return
        }

        // Idempotent re-runs: clear any prior segments and stale errors.
        try? repo.clearTranscript(meetingId: meetingId)
        TranscriptionErrors.clear(meetingId: meetingId)

        meeting.status = .transcribing
        try? repo.updateMeeting(meeting)

        do {
            // 1. Locate raw recording files. Dual-track path needs both
            //    mic.wav and system.wav. Fallback to the legacy mix
            //    (audio.wav) only when we can't get them — typically an
            //    older recording that was already Dropbox-archived
            //    before this code shipped.
            let dir = AppPaths.recordingDir(for: meetingId)
            let micURL = URL(fileURLWithPath: meeting.audioPath)
            let systemURL = dir.appendingPathComponent("system.wav")
            let mixURL = dir.appendingPathComponent("audio.wav")

            let micExists = FileManager.default.fileExists(atPath: micURL.path)
            let systemExists = FileManager.default.fileExists(atPath: systemURL.path)
            let canDualTrack = micExists && systemExists

            try Task.checkCancellation()

            // 2. Cache check. Both legacy single-stream and new
            //    dual-track shapes round-trip through CachedTranscript.
            //    Hash key for dual-track is "md5(mic.wav)+md5(system.wav)";
            //    for legacy it's md5(audio.wav). The two key spaces
            //    can't collide so a single column carries both.
            let cacheKey: String
            if canDualTrack {
                let mh = (try? Self.md5OfFile(at: micURL)) ?? ""
                let sh = (try? Self.md5OfFile(at: systemURL)) ?? ""
                cacheKey = "dual:\(mh):\(sh)"
            } else {
                if !FileManager.default.fileExists(atPath: mixURL.path),
                   let remote = meeting.dropboxAudioPath {
                    FileLogger.log("transcribe(): legacy fallback — pulling mix from Dropbox \(remote)")
                    try await DropboxService.shared.download(remotePath: remote, to: mixURL)
                }
                cacheKey = "mix:" + ((try? Self.md5OfFile(at: mixURL)) ?? "")
            }

            var userTurns: [GeminiTranscriber.Turn] = []
            var otherTurns: [GeminiTranscriber.Turn] = []
            var legacyTurns: [GeminiTranscriber.Turn] = []
            var cachedUserLabel: String? = nil
            var cacheHit = false
            var usingDualTrack = canDualTrack

            if let cachedJSON = meeting.geminiRawTurns,
               let storedHash = meeting.audioHash,
               !storedHash.isEmpty,
               storedHash == cacheKey,
               let data = cachedJSON.data(using: .utf8),
               let bundle = try? JSONDecoder().decode(CachedTranscript.self, from: data) {
                if bundle.isDualTrack {
                    userTurns = bundle.userTurns ?? []
                    otherTurns = bundle.otherTurns ?? []
                    cacheHit = !userTurns.isEmpty || !otherTurns.isEmpty
                    usingDualTrack = true
                } else if let legacy = bundle.turns, !legacy.isEmpty {
                    legacyTurns = legacy
                    cachedUserLabel = bundle.userLabel
                    cacheHit = true
                    usingDualTrack = false
                }
            }

            if cacheHit {
                if usingDualTrack {
                    FileLogger.log("transcribe(): cache hit — \(userTurns.count) user turns + \(otherTurns.count) other turns, skipping Gemini API")
                } else {
                    FileLogger.log("transcribe(): cache hit — \(legacyTurns.count) legacy turns, skipping Gemini API")
                }
            } else if canDualTrack {
                FileLogger.log("transcribe(): dual-track — transcribing mic.wav + system.wav in parallel")
                do {
                    async let micPart = GeminiTranscriber.transcribe(audioURL: micURL, mode: .single)
                    async let sysPart = GeminiTranscriber.transcribe(audioURL: systemURL, mode: .diarize)
                    let (u, o) = try await (micPart, sysPart)
                    userTurns = u
                    otherTurns = o
                } catch let err as GeminiTranscriber.GError {
                    TranscriptionErrors.record(meetingId: meetingId,
                                               message: err.localizedDescription)
                    throw err
                }
                FileLogger.log("transcribe(): dual-track done — \(userTurns.count) user / \(otherTurns.count) other")
            } else {
                FileLogger.log("transcribe(): legacy single-stream (no mic+system on disk) — falling back to mix")
                do {
                    legacyTurns = try await GeminiTranscriber.transcribe(audioURL: mixURL, mode: .diarize)
                } catch let err as GeminiTranscriber.GError {
                    TranscriptionErrors.record(meetingId: meetingId,
                                               message: err.localizedDescription)
                    throw err
                }
            }

            try Task.checkCancellation()

            // 3. Map turns → speakers + segments.
            let chosenUserLabel: String?
            if usingDualTrack {
                try mapDualTrackTurns(meetingId: meetingId, meeting: meeting,
                                      userTurns: userTurns, otherTurns: otherTurns,
                                      repo: repo)
                chosenUserLabel = nil    // not relevant in dual-track
            } else {
                chosenUserLabel = try mapTurnsToSpeakers(
                    meetingId: meetingId, meeting: meeting,
                    turns: legacyTurns, micURL: micURL, systemURL: systemURL,
                    forcedUserLabel: cachedUserLabel,
                    repo: repo
                )
            }

            // Persist cache only after a successful map. Use the
            // targeted setRawTurnsCache helper rather than updateMeeting:
            // the local `meeting` copy still has status=.transcribing
            // (set above on line 80) while mapping just flipped the DB
            // to .ready, and round-tripping the stale local copy through
            // updateMeeting would silently revert that.
            if !cacheHit {
                let bundle: CachedTranscript
                if usingDualTrack {
                    bundle = CachedTranscript(userLabel: nil, turns: nil,
                                              userTurns: userTurns, otherTurns: otherTurns)
                } else {
                    bundle = CachedTranscript(userLabel: chosenUserLabel, turns: legacyTurns,
                                              userTurns: nil, otherTurns: nil)
                }
                if let raw = try? JSONEncoder().encode(bundle),
                   let json = String(data: raw, encoding: .utf8) {
                    try? repo.setRawTurnsCache(meetingId: meetingId,
                                               geminiRawTurns: json,
                                               audioHash: cacheKey)
                    FileLogger.log("transcribe(): cached \(usingDualTrack ? "dual-track" : "legacy") turns + audio_hash")
                }
            }

            // 3. Refetch (status is now .ready, transcribedAt set) for the
            //    archive + boost branches below.
            guard let updated = try? repo.meeting(id: meetingId) else { return }
            meeting = updated

            // 4. Optional Dropbox archive.
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

                        // Keep mic.wav + system.wav locally so we can
                        // re-transcribe with the upcoming dual-track
                        // pipeline (one Gemini call per source instead
                        // of a single mix → way cleaner speaker
                        // assignment, mirrors how Granola does it). Only
                        // the mix and the .mov get cleaned.
                        for url in [videoURL, mixCopy] {
                            try? FileManager.default.removeItem(at: url)
                        }
                        FileLogger.log("dropbox: video + mix cleaned for \(mid); mic.wav/system.wav kept for dual-track retranscribe")
                    } catch {
                        FileLogger.log("dropbox: archive failed for \(mid): \(error)")
                    }
                }
            }

            // 5. Optional Boost — fire-and-forget per-segment polish via
            //    Gemini 2.5 Pro. The UI polls /api/meetings/:id and renders
            //    text_boost as soon as it lands per segment.
            if BoostMode.isEnabled {
                let repoRef = repo
                let mid = meetingId
                FileLogger.log("transcribe(): boost mode ON — auto-running Gemini Pro for \(mid)")
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
        } catch is CancellationError {
            FileLogger.log("transcribe(): cancelled for \(meetingId)")
        } catch {
            FileLogger.log("Corder transcription error: \(error)")
            meeting.status = .failed
            try? repo.updateMeeting(meeting)
        }
    }

    /// Map a [Turn] list (either freshly transcribed by Gemini or pulled
    /// from the cache) onto our speaker model and persist segments.
    /// Speakers are wiped and rewritten on every call — this is what
    /// makes the "clarify count → re-map without billing" path possible.
    /// Returns the chosen `userLabel` so the caller can persist it for
    /// future cache-hit re-maps (after Dropbox archival the channel-gate
    /// has no audio to compare with).
    @discardableResult
    private func mapTurnsToSpeakers(meetingId: String, meeting: Meeting,
                                    turns: [GeminiTranscriber.Turn],
                                    micURL: URL, systemURL: URL,
                                    forcedUserLabel: String? = nil,
                                    repo: MeetingRepository) throws -> String? {
        // Wipe any previous speakers/segments we might have written for
        // this meeting before. clearTranscript was called once at the
        // start of transcribe(); for cache-hit re-maps we still need to
        // clear here because no fresh transcription was done.
        try? repo.clearTranscript(meetingId: meetingId)

        // Pick userLabel. If the caller already knows it (cache hit), use
        // that and skip the channel-gate. Otherwise compare mic.wav vs
        // system.wav RMS per segment to figure out which Gemini label
        // belongs to the local user.
        let userLabel: String?
        if let forced = forcedUserLabel, !forced.isEmpty {
            userLabel = forced
        } else {
            let segs = turns.map { (start: Double($0.startMs) / 1000.0,
                                    end:   Double($0.endMs)   / 1000.0) }
            let userVote = (try? Diarizer.userMicDominance(segments: segs,
                                                           userPath: micURL,
                                                           otherPath: systemURL))
                ?? Array(repeating: false, count: turns.count)

            var userScore: [String: Double] = [:]
            for (i, turn) in turns.enumerated() {
                guard i < userVote.count, userVote[i] else { continue }
                userScore[turn.speakerLabel, default: 0] += Double(turn.endMs - turn.startMs) / 1000.0
            }
            // The label with the largest cumulative "user-dominant" duration
            // becomes the user — but only if it actually crosses some threshold.
            // Otherwise (cloud-only call where the mic was muted) nobody is.
            userLabel = userScore.filter { $0.value >= 1.5 }
                .max(by: { $0.value < $1.value })?.key
        }

        if meeting.expectedOtherSpeakers == 0 {
            FileLogger.log("mapTurns: expected_other_speakers=0, collapsing all turns onto user")
        }

        let userSpeakerId = "\(meetingId)-you"
        try repo.insertSpeaker(Speaker(id: userSpeakerId, meetingId: meetingId,
                                       label: "Speaker 1", customName: "you", colorHex: "#3b82f6"))

        let collapseAll = (meeting.expectedOtherSpeakers == 0)
        let otherLabels = collapseAll
            ? []
            : Array(Set(turns.map { $0.speakerLabel }).filter { $0 != userLabel }).sorted()
        var otherSpeakerIds: [String: String] = [:]
        for (i, label) in otherLabels.enumerated() {
            let id = "\(meetingId)-other-\(i)"
            otherSpeakerIds[label] = id
            try repo.insertSpeaker(Speaker(id: id, meetingId: meetingId,
                                           label: "Speaker \(i + 2)", customName: nil,
                                           colorHex: otherColorHex(index: i)))
        }

        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !isHallucination(text) else {
                FileLogger.log("mapTurns: dropping hallucination: \(text)")
                continue
            }
            let speakerId: String
            if collapseAll || turn.speakerLabel == userLabel {
                speakerId = userSpeakerId
            } else if let id = otherSpeakerIds[turn.speakerLabel] {
                speakerId = id
            } else {
                speakerId = userSpeakerId
            }
            try repo.insertSegment(Segment(
                meetingId: meetingId,
                speakerId: speakerId,
                startMs: turn.startMs,
                endMs: turn.endMs,
                text: text
            ))
        }

        var m = meeting
        m.status = .ready
        m.transcribedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try repo.updateMeeting(m)
        FileLogger.log("mapTurns: stored \(turns.count) turns for \(meetingId), userLabel=\(userLabel ?? "nil")")
        return userLabel
    }

    /// Dual-track mapping. `userTurns` are mic.wav (always "you"),
    /// `otherTurns` are system.wav (diarized 1+ remote speakers, labeled
    /// "Speaker 1" etc within that single track).
    ///
    /// Speaker assignment here is architecturally clean — no channel-gate
    /// guesswork — because each input was a single source. The
    /// `expectedOtherSpeakers == 0` ("Just me") clarify still works:
    /// we just drop everything from system.wav onto the user.
    private func mapDualTrackTurns(meetingId: String, meeting: Meeting,
                                   userTurns: [GeminiTranscriber.Turn],
                                   otherTurns: [GeminiTranscriber.Turn],
                                   repo: MeetingRepository) throws {
        try? repo.clearTranscript(meetingId: meetingId)

        let userSpeakerId = "\(meetingId)-you"
        try repo.insertSpeaker(Speaker(id: userSpeakerId, meetingId: meetingId,
                                       label: "Speaker 1", customName: "you", colorHex: "#3b82f6"))

        let collapseAll = (meeting.expectedOtherSpeakers == 0)
        // Each distinct label inside system.wav maps to one "other" id.
        let otherLabels = collapseAll
            ? []
            : Array(Set(otherTurns.map { $0.speakerLabel })).sorted()
        var otherSpeakerIds: [String: String] = [:]
        for (i, label) in otherLabels.enumerated() {
            let id = "\(meetingId)-other-\(i)"
            otherSpeakerIds[label] = id
            try repo.insertSpeaker(Speaker(id: id, meetingId: meetingId,
                                           label: "Speaker \(i + 2)", customName: nil,
                                           colorHex: otherColorHex(index: i)))
        }

        // Merge both lists by start_ms so the transcript reads in the
        // correct chronological order — even when user and remote
        // overlap, we still want them in the right slot.
        struct Item { let speakerId: String; let turn: GeminiTranscriber.Turn }
        var items: [Item] = []
        items.reserveCapacity(userTurns.count + otherTurns.count)
        for t in userTurns { items.append(Item(speakerId: userSpeakerId, turn: t)) }
        for t in otherTurns {
            let sid: String
            if collapseAll {
                sid = userSpeakerId
            } else {
                sid = otherSpeakerIds[t.speakerLabel] ?? userSpeakerId
            }
            items.append(Item(speakerId: sid, turn: t))
        }
        items.sort { $0.turn.startMs < $1.turn.startMs }

        for item in items {
            let text = item.turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !isHallucination(text) else {
                FileLogger.log("mapDual: dropping hallucination: \(text)")
                continue
            }
            try repo.insertSegment(Segment(
                meetingId: meetingId,
                speakerId: item.speakerId,
                startMs: item.turn.startMs,
                endMs: item.turn.endMs,
                text: text
            ))
        }

        var m = meeting
        m.status = .ready
        m.transcribedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try repo.updateMeeting(m)
        FileLogger.log("mapDual: stored \(items.count) items (user=\(userTurns.count), other=\(otherTurns.count)) for \(meetingId)")
    }

    /// On-disk shape of the raw-transcription cache.
    ///
    /// Two formats live in the wild:
    ///   - Legacy single-stream (`turns` + `userLabel`): the old mix→
    ///     Gemini→channel-gate path. We still decode these so existing
    ///     records keep re-mapping for free.
    ///   - Dual-track (`userTurns` + `otherTurns`): mic.wav and
    ///     system.wav transcribed separately. `userTurns` are always
    ///     "you" by definition; `otherTurns` are diarized over remote
    ///     side (Speaker 1, Speaker 2…). No channel-gate guesswork.
    ///
    /// `JSONDecoder` ignores unknown keys and tolerates missing optional
    /// ones, so a single struct handles both formats at decode time.
    private struct CachedTranscript: Codable {
        // Legacy — single-stream output.
        let userLabel: String?
        let turns: [GeminiTranscriber.Turn]?
        // Dual-track — separately transcribed mic + system.
        let userTurns: [GeminiTranscriber.Turn]?
        let otherTurns: [GeminiTranscriber.Turn]?

        var isDualTrack: Bool { userTurns != nil || otherTurns != nil }
    }

    /// Distinct hues for the "other" speakers. Picked for high contrast
    /// against the white library background.
    private func otherColorHex(index: Int) -> String {
        let palette = ["#a855f7", "#d97706", "#1d4ed8", "#0d9488", "#be123c"]
        return palette[index % palette.count]
    }

    /// Streamed MD5 of a file. Used as the cache key for raw Gemini turns:
    /// if the audio.wav we're about to transcribe matches a previous one
    /// byte-for-byte, we re-use the cached [Turn] list instead of paying
    /// for another Gemini round-trip.
    static func md5OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = handle.readData(ofLength: 1 << 20)  // 1 MB
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Subtitle-style hallucinations the Whisper era left behind. Gemini
    /// doesn't generate these natively, but old Whisper transcripts in the
    /// DB still contain them — `purgeKnownHallucinations` clears those at
    /// launch, and this filter blocks any that slip through new pipelines.
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

    /// One-time scrub at app launch — sweeps known hallucinated lines out
    /// of the existing transcripts so users don't have to re-run anything.
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
}
