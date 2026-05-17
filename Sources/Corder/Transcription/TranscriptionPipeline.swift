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
    /// Monotonic per-meeting generation. A newer `enqueue` bumps it so a
    /// task that was waiting for a cancelled predecessor can tell it has
    /// been superseded and bow out instead of starting a redundant run.
    private var taskGen: [String: Int] = [:]

    @discardableResult
    func enqueue(meetingId: String) -> Task<Void, Never> {
        // Double-clicking Re-transcribe used to spawn a SECOND task while
        // the first was still unwinding its cancellation. Both ran
        // `transcribe()` concurrently and raced on the meeting row — the
        // cancelled one wrote `.failed` over the winner's `.ready`. Fix:
        // cancel the predecessor, then make the new task WAIT for it to
        // fully unwind before touching the DB, so there is only ever one
        // writer per meeting.
        let previous = activeTasks[meetingId]
        previous?.cancel()
        let gen = (taskGen[meetingId] ?? 0) + 1
        taskGen[meetingId] = gen
        let task = Task { @MainActor [weak self] in
            await previous?.value          // let the cancelled run finish
            guard let self else { return }
            // A still-newer enqueue may have superseded us while we
            // waited on `previous` — don't start a stale run.
            guard self.taskGen[meetingId] == gen else {
                FileLogger.log("enqueue: superseded before start for \(meetingId)")
                return
            }
            await self.transcribe(meetingId: meetingId)
            if self.taskGen[meetingId] == gen { self.activeTasks[meetingId] = nil }
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
            // system.wav is no longer guaranteed: the Core Audio process
            // tap only creates it once it actually delivers a buffer, so
            // a call with no remote audio (or a solo / in-person test)
            // leaves just mic.wav on disk. Treat that as "in-person":
            // diarize the mic instead of crashing into the legacy
            // audio.wav path (which doesn't exist → hard "Transcription
            // failed").
            let micOnly = micExists && !systemExists

            // Produce the PLAYBACK mix (audio.wav = mic + system, 16 kHz
            // mono). The audio route serves audio.wav and only falls back
            // to mic.wav when it's absent — and nothing was generating it,
            // so playback was mic-only: the user heard themselves but
            // never the far end (the remote side lives in system.wav,
            // which was captured and transcribed but never blended into
            // anything playable). Best-effort + idempotent: skip if it
            // already exists (recordings are immutable post-capture; this
            // also avoids clobbering a Dropbox-hydrated legacy mix).
            if micExists, !FileManager.default.fileExists(atPath: mixURL.path) {
                do {
                    try await AudioMixer.produceWhisperInput(
                        systemURL: systemExists ? systemURL : nil,
                        micURL: micURL,
                        outputURL: mixURL)
                    FileLogger.log("transcribe(): produced playback mix audio.wav (mic\(systemExists ? "+system" : " only")) for \(meetingId)")
                } catch {
                    FileLogger.log("transcribe(): playback mix failed (\(error)) — playback falls back to mic.wav for \(meetingId)")
                }
            }

            // Decide call-vs-in-person ONCE, here, so the cache key and
            // the transcription branch agree. system.wav counts as
            // silent if it doesn't exist, or exists but VAD finds no
            // speech. `detect` → nil on read error: be conservative and
            // treat that as "might be a call" (not silent), so we don't
            // wrongly bake the speaker hint into a real call's cache.
            let systemSilent: Bool
            if !systemExists {
                systemSilent = true
            } else {
                let vad = VoiceActivityDetector.detect(audioURL: systemURL)
                systemSilent = (vad?.isEmpty == true)
            }
            // In-person = there's a mic but no usable remote track. This
            // is the ONLY path that feeds the clarify headcount into the
            // Gemini prompt, so it's the only cache key that must carry
            // the count.
            let inPerson = micExists && systemSilent

            try Task.checkCancellation()

            // 2. Cache check. Both legacy single-stream and new
            //    dual-track shapes round-trip through CachedTranscript.
            //    Hash key for dual-track is "md5(mic.wav)+md5(system.wav)";
            //    for legacy it's md5(audio.wav). The two key spaces
            //    can't collide so a single column carries both.
            let cacheKey: String
            if inPerson {
                // The expected-speaker hint is baked into the Gemini
                // prompt for the in-person path, so a different clarify
                // count produces genuinely different raw turns — it MUST
                // be part of the cache key. This covers BOTH mic-only
                // and "system.wav exists but is silent": picking "3"
                // after "2" was a no-op before because a silent-system
                // meeting still keyed on the plain dual hash and hit the
                // stale cached turns.
                // v2: diarize-first (FluidAudio decides WHO, Gemini
                // .single decides WHAT). The speaker count is now a hard
                // clustering constraint, not a Gemini prompt hint, so the
                // raw output differs from any v1 cache — the prefix bump
                // forces a clean re-transcribe instead of replaying stale
                // Gemini-diarized turns.
                let mh = (try? Self.md5OfFile(at: micURL)) ?? ""
                let ex = meeting.expectedOtherSpeakers.map(String.init) ?? "nil"
                cacheKey = "inperson:v2:\(ex):\(mh)"
            } else if canDualTrack {
                // v2 + the other-speaker count: system.wav is now
                // diarized on-device with numSpeakers = expectedOther,
                // so the count affects raw output and must key the cache.
                let mh = (try? Self.md5OfFile(at: micURL)) ?? ""
                let sh = (try? Self.md5OfFile(at: systemURL)) ?? ""
                let ex = meeting.expectedOtherSpeakers.map(String.init) ?? "nil"
                cacheKey = "dual:v2:\(ex):\(mh):\(sh)"
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
            } else if canDualTrack || micOnly {
                // call-vs-in-person was already decided above
                // (`systemSilent`, reused here so the cache key and the
                // path can't disagree):
                //  • real call  → mic = you (.single), system = others
                //  • in-person  → everyone on the mic, diarize it
                if !systemSilent {
                    // Real call. mic.wav is you (single, no diarization
                    // needed — it's one person by construction).
                    // system.wav is the remote side: diarize-first
                    // (FluidAudio decides WHO with a hard speaker count,
                    // Gemini .single decides WHAT). The remote count is
                    // expectedOtherSpeakers exactly — "you" are on mic,
                    // not in system.wav.
                    FileLogger.log("transcribe(): dual-track — mic .single + system diarize-first")
                    do {
                        async let micPart = GeminiTranscriber.transcribe(audioURL: micURL, mode: .single)
                        async let sysPart = diarizeFirst(
                            wavURL: systemURL,
                            numSpeakers: meeting.expectedOtherSpeakers,
                            singlePass: false,
                            meetingId: meetingId)
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
                    // In-person: everyone (incl. the device owner) is on
                    // the one mic. Diarize-first over mic.wav — FluidAudio
                    // gives globally-stable labels with the room headcount
                    // as a hard constraint (total = expectedOtherSpeakers
                    // + 1, since the clarify banner stores total−1). No
                    // dedicated "you" track, so every turn goes through
                    // the "other" bucket and mapInPersonTurns numbers
                    // them Speaker 1, 2, ….
                    let why = micOnly ? "no system.wav (mic-only)" : "system.wav has no speech"
                    let roomSize = meeting.expectedOtherSpeakers.map { $0 + 1 }
                    FileLogger.log("transcribe(): \(why) — in-person diarize-first on mic.wav (rooms=\(roomSize.map(String.init) ?? "auto"))")
                    usingDualTrack = true   // map via mapDualTrackTurns
                    otherTurns = try await diarizeFirst(
                        wavURL: micURL,
                        numSpeakers: roomSize,
                        singlePass: true,
                        meetingId: meetingId)
                    userTurns = []
                    FileLogger.log("transcribe(): in-person done — \(otherTurns.count) turns from mic.wav")
                }
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

            // 2.5. Empty-recording short-circuit: when both tracks
            //      came back with zero turns (the VAD pre-pass found
            //      <500 ms of speech in each, or the mic was muted
            //      and the system stream was silent), there's nothing
            //      to map / boost / archive to Dropbox. Flip the row
            //      straight into the 7-day archive bin so the user
            //      doesn't see an empty session in their library —
            //      it'll auto-purge after 7 days like any other
            //      archived meeting.
            let hasAnyContent = usingDualTrack
                ? (!userTurns.isEmpty || !otherTurns.isEmpty)
                : !legacyTurns.isEmpty
            if !hasAnyContent {
                FileLogger.log("transcribe(): no speech detected — auto-archiving \(meetingId)")
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                var silent = meeting
                silent.status = .ready
                silent.transcribedAt = now
                silent.archivedAt = now
                try? repo.updateMeeting(silent)
                // Best-effort: drop the local audio dir too — there's
                // nothing of value in it. Dropbox archive is skipped
                // by virtue of returning before the upload branch.
                try? FileManager.default.removeItem(at: AppPaths.recordingDir(for: meetingId))
                return
            }

            // 3. Map turns → speakers + segments.
            let chosenUserLabel: String?
            if usingDualTrack {
                try mapDualTrackTurns(meetingId: meetingId, meeting: meeting,
                                      userTurns: userTurns, otherTurns: otherTurns,
                                      inPerson: inPerson,
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

            // 3.5. Auto-title: one cheap text-only Gemini call from the
            //      fresh transcript. Best-effort + idempotent — only when
            //      it's actually ready, has content, and isn't titled
            //      yet, so a re-transcribe of an already-named meeting
            //      doesn't re-bill or churn the name. Targeted write so
            //      it can't clobber status.
            if meeting.status == .ready,
               (meeting.title?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                let segs = (try? repo.segments(forMeeting: meetingId)) ?? []
                let spks = (try? repo.speakers(forMeeting: meetingId)) ?? []
                if !segs.isEmpty {
                    let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)
                    if let title = await GeminiTitler.generate(transcript: text) {
                        try? repo.setTitle(meetingId: meetingId, title: title)
                        FileLogger.log("transcribe(): titled \(meetingId) → \"\(title)\"")
                    }
                }
            }

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

                        // All local recordings stay on disk after Dropbox
                        // upload: mic.wav + system.wav for dual-track
                        // retranscribe, audio.wav for playback (the only
                        // file with BOTH speakers on one timeline), and
                        // video.mov for the screen preview in the Library.
                        // The Dropbox copy is just a cold-store backup —
                        // the UI never has to hydrate it just to render
                        // the most recent meetings. `purgeStaleOriginals`
                        // sweeps older recordings at launch.
                        FileLogger.log("dropbox: archive done for \(mid); originals kept locally for playback")
                    } catch {
                        FileLogger.log("dropbox: archive failed for \(mid): \(error)")
                    }
                }
            }

        } catch is CancellationError {
            FileLogger.log("transcribe(): cancelled for \(meetingId)")
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // A superseded re-transcribe cancels the in-flight Gemini
            // upload; URLSession surfaces that as URLError(-999), which
            // is NOT a Swift CancellationError. Treat it as a
            // cancellation — NOT a failure — so it never writes `.failed`
            // over the successful run that replaced it.
            FileLogger.log("transcribe(): cancelled (URLError -999) for \(meetingId)")
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
                                   inPerson: Bool = false,
                                   repo: MeetingRepository) throws {
        try? repo.clearTranscript(meetingId: meetingId)

        // ── In-person: everyone (incl. the device owner) is on the one
        //    mic, so there is NO dedicated "you" track. The call-path
        //    collapse model is wrong here: picking "2" sets
        //    expectedOtherSpeakers==1 which the call path reads as
        //    "collapse every label into ONE other" → the whole room
        //    becomes a single speaker (the bug the user kept hitting).
        //    For in-person the clarify answer is the TOTAL headcount
        //    (= expectedOtherSpeakers + 1). We keep that many distinct
        //    speakers, ranked by speaking time, and fold only the
        //    SURPLUS Gemini labels into the busiest ones. Never
        //    collapse to 1 unless the user explicitly said "Just me".
        if inPerson {
            try mapInPersonTurns(meetingId: meetingId, meeting: meeting,
                                 turns: otherTurns, repo: repo)
            return
        }

        let userSpeakerId = "\(meetingId)-you"
        let collapseAll = (meeting.expectedOtherSpeakers == 0)
        // "User said there's exactly 1 other person on the call" — fold
        // every Gemini label inside system.wav into a single "Speaker 2"
        // bucket. This is the common case for auto-detected 1:1 calls,
        // and it's also the right answer when the clarify banner pill
        // "2 people" is clicked. Without this collapse, Gemini's
        // over-counting (5 labels on a 12-minute call with one
        // interlocutor) would leak straight through.
        let collapseOthers = (meeting.expectedOtherSpeakers == 1)
        // Only persist the user speaker when they'll actually own
        // segments — either they spoke (userTurns non-empty) or
        // `collapseAll` will land every other-turn on the user. The
        // previous unconditional insert left a ghost "Speaker 1" row
        // for dual-track recordings where the mic was silent — that
        // row inflated `speakers.length` and skewed the clarify banner
        // to a higher pill than the actual speaker count.
        let userHasContent = collapseAll || !userTurns.isEmpty
        if userHasContent {
            try repo.insertSpeaker(Speaker(id: userSpeakerId, meetingId: meetingId,
                                           label: "Speaker 1", customName: "you", colorHex: "#3b82f6"))
        }

        // Each distinct label inside system.wav maps to one "other" id —
        // unless `collapseOthers` is on, in which case every label gets
        // folded into a single bucket.
        let othersLabelOffset = userHasContent ? 2 : 1
        let singleOtherSpeakerId = "\(meetingId)-other-0"
        var otherSpeakerIds: [String: String] = [:]
        if collapseAll {
            // no "other" rows — everything lands on the user
        } else if collapseOthers {
            try repo.insertSpeaker(Speaker(id: singleOtherSpeakerId, meetingId: meetingId,
                                           label: "Speaker \(othersLabelOffset)", customName: nil,
                                           colorHex: otherColorHex(index: 0)))
            // Map every distinct Gemini label onto the single bucket id.
            for label in Set(otherTurns.map { $0.speakerLabel }) {
                otherSpeakerIds[label] = singleOtherSpeakerId
            }
        } else {
            // When the user-speaker is present, others start at "Speaker 2"
            // (the user is Speaker 1). When the mic track had no detectable
            // speech and we skipped the user-speaker entirely, start
            // numbering at "Speaker 1" so the transcript doesn't show
            // a gap (Speaker 2, Speaker 3, … with no Speaker 1).
            let otherLabels = Array(Set(otherTurns.map { $0.speakerLabel })).sorted()
            for (i, label) in otherLabels.enumerated() {
                let id = "\(meetingId)-other-\(i)"
                otherSpeakerIds[label] = id
                try repo.insertSpeaker(Speaker(id: id, meetingId: meetingId,
                                               label: "Speaker \(i + othersLabelOffset)", customName: nil,
                                               colorHex: otherColorHex(index: i)))
            }
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

    /// In-person mapping. Everyone — including the device owner — was on
    /// the single mic, so there is NO dedicated "you" track and the
    /// call-path collapse model (Speaker 1 = you, fold the rest) does
    /// not apply. `turns` is Gemini's diarized output over mic.wav.
    ///
    /// The clarify banner asks "how many OTHER people", so the answer is
    /// stored as `expectedOtherSpeakers = total − 1`. Room size therefore
    /// = expectedOtherSpeakers + 1.
    ///
    ///   • expectedOtherSpeakers == 0  → user said "just me": collapse
    ///     every Gemini label into one speaker.
    ///   • expectedOtherSpeakers == nil → unspecified: trust Gemini's
    ///     diarization labels exactly as they came back.
    ///   • expectedOtherSpeakers >= 1  → keep the N busiest Gemini labels
    ///     (by total speaking time, N = room size) as distinct speakers
    ///     and fold every surplus label into the single busiest one.
    ///     Gemini reliably OVER-counts on a shared room mic (cross-talk,
    ///     echo, brief background voices), so trimming to N is what makes
    ///     picking "3" actually yield 3. It's a cap, not a floor: when
    ///     Gemini under-counts we keep what it gave (we can't invent a
    ///     voice) and we NEVER collapse to 1 here — that was the bug
    ///     where picking "2"/"3" showed 1/2.
    private func mapInPersonTurns(meetingId: String, meeting: Meeting,
                                  turns: [GeminiTranscriber.Turn],
                                  repo: MeetingRepository) throws {
        try? repo.clearTranscript(meetingId: meetingId)

        // Per-label totals drive both the keep/merge ranking (by
        // speaking time) and the display order (by first appearance,
        // so the transcript reads top-to-bottom in speaking order).
        var durationByLabel: [String: Int64] = [:]
        var firstSeenByLabel: [String: Int64] = [:]
        for t in turns {
            durationByLabel[t.speakerLabel, default: 0] += max(0, t.endMs - t.startMs)
            let prev = firstSeenByLabel[t.speakerLabel]
            if prev == nil || t.startMs < prev! {
                firstSeenByLabel[t.speakerLabel] = t.startMs
            }
        }
        let distinctLabels = Array(durationByLabel.keys)
        let expected = meeting.expectedOtherSpeakers

        // gemini label → canonical kept label; keptLabels is the
        // display-ordered set of survivors that get a Speaker row.
        var labelRemap: [String: String] = [:]
        let keptLabels: [String]

        if expected == 0 {
            // "Just me" — fold everything onto one speaker.
            let sink = distinctLabels.first ?? "Speaker 1"
            for l in distinctLabels { labelRemap[l] = sink }
            keptLabels = distinctLabels.isEmpty ? [] : [sink]
        } else if expected == nil {
            // Unspecified — trust Gemini's diarization verbatim.
            for l in distinctLabels { labelRemap[l] = l }
            keptLabels = distinctLabels.sorted {
                (firstSeenByLabel[$0] ?? .max) < (firstSeenByLabel[$1] ?? .max)
            }
        } else {
            let roomSize = max(1, (expected ?? 0) + 1)
            let byDuration = distinctLabels.sorted {
                (durationByLabel[$0] ?? 0) > (durationByLabel[$1] ?? 0)
            }
            let survivors = Set(byDuration.prefix(roomSize))
            let busiest = byDuration.first ?? (distinctLabels.first ?? "Speaker 1")
            for l in distinctLabels {
                labelRemap[l] = survivors.contains(l) ? l : busiest
            }
            keptLabels = Array(survivors).sorted {
                (firstSeenByLabel[$0] ?? .max) < (firstSeenByLabel[$1] ?? .max)
            }
        }

        // One Speaker row per kept label. No "you" — in-person has no
        // audio basis to single out the device owner, so they're just
        // Speaker 1..N in speaking order.
        var speakerIdByLabel: [String: String] = [:]
        for (i, label) in keptLabels.enumerated() {
            let id = "\(meetingId)-spk-\(i)"
            speakerIdByLabel[label] = id
            try repo.insertSpeaker(Speaker(id: id, meetingId: meetingId,
                                           label: "Speaker \(i + 1)", customName: nil,
                                           colorHex: otherColorHex(index: i)))
        }
        let fallbackId = keptLabels.first.flatMap { speakerIdByLabel[$0] }

        let sorted = turns.sorted { $0.startMs < $1.startMs }
        var stored = 0
        for t in sorted {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !isHallucination(text) else {
                FileLogger.log("mapInPerson: dropping hallucination: \(text)")
                continue
            }
            let canonical = labelRemap[t.speakerLabel]
            guard let sid = canonical.flatMap({ speakerIdByLabel[$0] }) ?? fallbackId
            else { continue }
            try repo.insertSegment(Segment(
                meetingId: meetingId,
                speakerId: sid,
                startMs: t.startMs,
                endMs: t.endMs,
                text: text
            ))
            stored += 1
        }

        var m = meeting
        m.status = .ready
        m.transcribedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try repo.updateMeeting(m)
        FileLogger.log("mapInPerson: stored \(stored) segs, kept \(keptLabels.count) speakers (expectedOther=\(expected.map(String.init) ?? "nil"), distinct=\(distinctLabels.count)) for \(meetingId)")
    }

    /// Diarize-first transcription of one track. FluidAudio decides WHO
    /// (globally-stable labels, the known speaker count enforced as a
    /// hard clustering constraint), Gemini `.single` decides WHAT
    /// (verbatim text + accurate timestamps, no LLM speaker-counting).
    /// The two run in parallel; ASR turns are then re-labeled by
    /// temporal overlap with the diarization timeline.
    ///
    /// Fallback: if on-device diarization is unavailable (models not yet
    /// downloaded on a first-ever offline run, no speech, Core ML
    /// error), we drop back to Gemini's own `.diarize` so a meeting
    /// never hard-fails worse than the pre-FluidAudio behaviour. A
    /// Gemini ASR/quota/network error is a real failure and propagates.
    private func diarizeFirst(wavURL: URL,
                              numSpeakers: Int?,
                              singlePass: Bool,
                              meetingId: String) async throws -> [GeminiTranscriber.Turn] {
        // ASR is ALWAYS chunked (singlePass:false). singlePass existed
        // only to keep Gemini's own diarization labels consistent across
        // chunk boundaries — but FluidAudio owns the labels now, so the
        // `.single` ASR pass doesn't care. Chunking is what keeps a long
        // in-person recording (e.g. 7 min → one 374 s call) from
        // timing out mid-generate and hard-failing the whole meeting
        // (the "Transcription failed" the user kept hitting). singlePass
        // is still honoured for the no-FluidAudio `.diarize` fallback.
        async let asrTask = GeminiTranscriber.transcribe(
            audioURL: wavURL, mode: .single, singlePass: false)

        var diarSegs: [DiarizedSegment] = []
        do {
            diarSegs = try await SpeakerDiarizer.shared.diarize(
                wavURL: wavURL, numSpeakers: numSpeakers)
        } catch {
            FileLogger.log("diarizeFirst: on-device diarization unavailable (\(error)) — Gemini .diarize fallback")
        }

        if diarSegs.isEmpty {
            // No usable diarization → discard the .single ASR and let
            // Gemini both transcribe AND label in one call (old path).
            do {
                return try await GeminiTranscriber.transcribe(
                    audioURL: wavURL, mode: .diarize,
                    singlePass: singlePass, expectedSpeakers: numSpeakers)
            } catch let err as GeminiTranscriber.GError {
                TranscriptionErrors.record(meetingId: meetingId,
                                           message: err.localizedDescription)
                throw err
            }
        }

        let asrTurns: [GeminiTranscriber.Turn]
        do {
            asrTurns = try await asrTask
        } catch let err as GeminiTranscriber.GError {
            TranscriptionErrors.record(meetingId: meetingId,
                                       message: err.localizedDescription)
            throw err
        }
        let relabeled = Self.relabel(asr: asrTurns, using: diarSegs)
        FileLogger.log("diarizeFirst: \(wavURL.lastPathComponent) — \(asrTurns.count) ASR turns relabeled across \(Set(diarSegs.map(\.speakerId)).count) on-device speakers")
        return relabeled
    }

    /// Assign each ASR text turn the diarized speaker it overlaps most
    /// in time. ASR and diarization are on the SAME original timeline
    /// (GeminiTranscriber projects its VAD-compressed timestamps back to
    /// the input file's frame; FluidAudio sees the same file), so a
    /// plain interval-overlap match is correct. A turn with no overlap
    /// (ASR segment inside a stretch the diarizer dropped) takes the
    /// nearest segment by start time so it still gets a stable label.
    static func relabel(asr: [GeminiTranscriber.Turn],
                        using diar: [DiarizedSegment]) -> [GeminiTranscriber.Turn] {
        guard !diar.isEmpty else { return asr }
        return asr.map { turn in
            var best = ""
            var bestOverlap: Int64 = 0
            for d in diar {
                let lo = max(turn.startMs, d.startMs)
                let hi = min(turn.endMs, d.endMs)
                let ov = hi - lo
                if ov > bestOverlap { bestOverlap = ov; best = d.speakerId }
            }
            if best.isEmpty {
                best = diar.min(by: {
                    abs($0.startMs - turn.startMs) < abs($1.startMs - turn.startMs)
                })?.speakerId ?? "Speaker 1"
            }
            return GeminiTranscriber.Turn(speakerLabel: best,
                                          startMs: turn.startMs,
                                          endMs: turn.endMs,
                                          text: turn.text)
        }
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

    /// Backfill auto-titles for recordings made before the title feature
    /// (or whose title generation failed). Runs once at launch, in the
    /// background, sequentially with a small gap so we don't burst the
    /// Gemini API. Best-effort: each failure is skipped, not retried.
    static func backfillTitles(repo: MeetingRepository) {
        Task.detached(priority: .utility) {
            let ids = (try? repo.meetingIdsNeedingTitle()) ?? []
            guard !ids.isEmpty else { return }
            FileLogger.log("startup: backfilling titles for \(ids.count) untitled meetings")
            for id in ids {
                let segs = (try? repo.segments(forMeeting: id)) ?? []
                guard !segs.isEmpty else { continue }
                let spks = (try? repo.speakers(forMeeting: id)) ?? []
                let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)
                if let title = await GeminiTitler.generate(transcript: text) {
                    try? repo.setTitle(meetingId: id, title: title)
                    FileLogger.log("startup: titled \(id) → \"\(title)\"")
                }
                // Be polite to the API between meetings.
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            FileLogger.log("startup: title backfill done")
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
