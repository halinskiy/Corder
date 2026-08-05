import Foundation
import CryptoKit
import AVFoundation

/// Drives the post-recording pipeline: mix audio → Gemini transcribe →
/// channel-gate "user" identification → DB writes → optional auto-Boost
/// + Dropbox archive.
///
/// This used to fork between Gemini (cloud) and WhisperKit (local). The
/// local path was retired in v0.7, running 1.5 GB of CoreML on every
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

    /// Runtime override of the user-picked provider. Set at the top
    /// of `transcribe()` to either honour the user setting or, if
    /// the monthly Advanced cap is exhausted, downshift to local.
    /// Everything downstream that needs to branch on provider reads
    /// `currentProvider`, which falls back to the user setting if
    /// nothing is active (e.g. prewarm-time reads at launch).
    private var activeProvider: TranscriptionProvider?
    private var currentProvider: TranscriptionProvider {
        activeProvider ?? AppSettings.transcriptionProvider
    }

    /// True when the cloud provider can serve this transcribe call
    /// either via the Cloudflare Worker proxy (any signed-in user
    /// whose `app_metadata.tier` clears the Worker's check) OR via
    /// a legacy on-disk key file. Returning false here pushes the
    /// pipeline into the local-Whisper fallback before we even try
    /// the API call, so the user never sees a meeting `.failed` with
    /// `noKey` for a provider they can't configure themselves.
    private func cloudKeyAvailable(for provider: TranscriptionProvider) -> Bool {
        // Cloud providers go through the Cloudflare Worker proxy with
        // the user's Supabase JWT, no local key is consulted any
        // more. The legacy `~/.config/corder/{openai,gemini}_key`
        // fallback was removed in 0.13.29 to keep the .app from ever
        // depending on a user-side API secret. A signed-out user can
        // only use whisperLocal.
        switch provider {
        case .whisper, .gemini, .groq:
            return SupabaseClientHolder.shared.auth.currentSession != nil
        case .whisperLocal:
            return true
        }
    }

    /// Called once at app launch. When the active provider is
    /// `.whisperLocal` (the Free-tier default) and the picked variant
    /// isn't on disk yet, kick off a background pre-fetch so the first
    /// recording transcribes without a 3-5 min cold-start download.
    /// Other providers (Gemini, cloud Whisper) are stateless on our
    /// side, nothing to warm up.
    func prewarm() {
        guard LocalWhisperTranscriber.isAvailable() else {
            FileLogger.log("TranscriptionPipeline.prewarm: WhisperKit unavailable on this arch, skip")
            return
        }

        // Cloud-provider users (Pro/Max) transcribe in the cloud and DON'T
        // pre-stage an on-device model. We used to background-download the
        // ~1.5 GB offline-fallback net here so a mid-call connection drop
        // could finish locally, but on a slow Mac that fetch + the one-time
        // ANE compile ran hot for up to 25 min right after a user upgraded,
        // and (because the compile lights the global "preparing" flag) it
        // surfaced on the paid user's finished cloud transcript as a bogus
        // "Preparing model…" banner. A paid user should just see their cloud
        // result. So: no eager staging for cloud users (product decision,
        // 2026-08-03). The connection-drop safety net still works IF a model
        // is already on disk (a user who was Free before, or picked local):
        // `WhisperTranscriber.localChunkFallback` gates on `isModelDownloaded`
        // and simply skips the offline rescue when nothing is staged (the
        // meeting fails on the network error and retries in the cloud), it
        // never triggers a surprise mid-transcribe download.
        guard AppSettings.transcriptionProvider == .whisperLocal else {
            FileLogger.log("TranscriptionPipeline.prewarm: cloud user, no on-device pre-stage")
            return
        }

        let variant = AppSettings.whisperLocalVariant
        if LocalWhisperTranscriber.isModelDownloaded(variant) {
            FileLogger.log("TranscriptionPipeline.prewarm: \(variant.rawValue) already on disk, skip")
            return
        }
        FileLogger.log("TranscriptionPipeline.prewarm: pre-fetching \(variant.rawValue) in background")
        Task { @MainActor in
            do {
                try await LocalWhisperTranscriber.downloadOnly(variant)
                FileLogger.log("TranscriptionPipeline.prewarm: \(variant.rawValue) ready")
            } catch {
                FileLogger.log("TranscriptionPipeline.prewarm: \(variant.rawValue) download failed, \(error)")
            }
        }
    }

    /// Schedule a transcription as a tracked Task so it can be cancelled
    /// later. Replaces direct `await transcribe(meetingId:)` call sites.
    /// Monotonic per-meeting generation. A newer `enqueue` bumps it so a
    /// task that was waiting for a cancelled predecessor can tell it has
    /// been superseded and bow out instead of starting a redundant run.
    private var taskGen: [String: Int] = [:]

    @discardableResult
    /// `forceFresh` bypasses the raw-turns cache so the run re-fetches ASR and
    /// re-runs the LLM polish from scratch — used by the MANUAL Re-transcribe so
    /// pipeline/prompt improvements actually reach an existing recording (a plain
    /// cache-hit re-transcribe only re-derives timing off the cached, already-
    /// polished text). Launch recovery / network retry keep the cache (default).
    func enqueue(meetingId: String, forceFresh: Bool = false) -> Task<Void, Never> {
        // Double-clicking Re-transcribe used to spawn a SECOND task while
        // the first was still unwinding its cancellation. Both ran
        // `transcribe()` concurrently and raced on the meeting row, the
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
            // waited on `previous`, don't start a stale run.
            guard self.taskGen[meetingId] == gen else {
                FileLogger.log("enqueue: superseded before start for \(meetingId)")
                return
            }
            await self.transcribe(meetingId: meetingId, forceFresh: forceFresh)
            if self.taskGen[meetingId] == gen { self.activeTasks[meetingId] = nil }
        }
        activeTasks[meetingId] = task
        return task
    }

    /// Cancel a running transcription. Marks the meeting as `.failed` so
    /// the UI flips out of the loader state immediately; the underlying
    /// Task is cancelled, but Gemini upload may run for a few more
    /// seconds, we ignore its eventual result via `catch is
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

    func transcribe(meetingId: String, forceFresh: Bool = false) async {
        FileLogger.log("transcribe(): START for \(meetingId)\(forceFresh ? " (forceFresh: re-fetch ASR + re-polish)" : "")")
        // Reset the runtime provider override no matter how this
        // returns, exception, cancel, or normal completion, so a
        // following transcribe() always begins by re-evaluating the
        // user setting + cap.
        defer { activeProvider = nil }
        // Real progress bar: start at 0 (a fresh run / re-transcribe begins
        // empty, no leftover full value to animate backward from) and always
        // clear on exit so a finished row stops reporting.
        TranscriptionProgressStore.begin(meetingId: meetingId)
        defer { TranscriptionProgressStore.clear(meetingId: meetingId) }

        // Watchdog: a HANG detector, NOT a hard time cap. A cold first-run can
        // legitimately spend 15-25 min downloading (~1.5 GB) + paying the
        // one-time ANE/GPU compile (especially the ≤8 GB generous-GPU-budget
        // path), and a long meeting then takes real wall-time to transcribe
        // none of that is a hang. A flat 45-min-from-entry cap would kill those
        // legitimately-slow first runs. So we fire ONLY after 45 CONTIGUOUS
        // minutes with NO forward progress: the idle timer resets whenever the
        // on-device model is actively loading (download bytes or the silent
        // compile) OR the transcription fraction advances. Decoupled from this
        // task's own cancellability so even a wedged uncancellable call still
        // flips the DB status and unblocks the polling Library UI.
        let watchdog = Task.detached {
            let variant = AppSettings.whisperLocalVariant
            var idleMin = 0
            var lastFrac = -1.0
            while idleMin < 45 {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { return }
                let loading = LocalWhisperTranscriber.currentProgress(variant) != nil
                    || LocalWhisperTranscriber.isPreparing(variant)
                let frac = TranscriptionProgressStore.read(meetingId: meetingId) ?? 0
                if loading || frac > lastFrac {
                    idleMin = 0
                    lastFrac = frac
                } else {
                    idleMin += 1
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                let repo = AppContext.shared.repo
                if let m = try? repo.meeting(id: meetingId), m.status == .transcribing {
                    FileLogger.log("transcribe(): WATCHDOG, \(meetingId) no forward progress for 45 min, marking failed")
                    TranscriptionErrors.record(meetingId: meetingId,
                                               message: "Transcription took too long and was stopped. Please try again.")
                    try? repo.setStatus(meetingId: meetingId, status: .failed)
                }
            }
        }
        defer { watchdog.cancel() }

        let repo = AppContext.shared.repo
        guard var meeting = (try? repo.meeting(id: meetingId)) else {
            FileLogger.log("transcribe(): meeting \(meetingId) not found in DB")
            return
        }

        // Idempotent re-runs: clear stale errors. We do NOT clear the
        // prior transcript here, keeping it means an interrupted /
        // failed re-transcribe leaves the previous (already-paid-for)
        // result readable instead of wiping it. The mapping step clears +
        // re-inserts atomically once a run actually produces turns, so
        // success still fully replaces the old segments.
        TranscriptionErrors.clear(meetingId: meetingId)
        // Count this attempt. Reset to 0 once we reach `.ready` below so
        // a row only burns its retry budget on consecutive failures; the
        // launch auto-retry skips rows that exhausted it.
        try? repo.incrementTranscribeAttempts(meetingId: meetingId)

        meeting.status = .transcribing
        // Stamp the attempt-start FRESH on every run, not just when nil. Each
        // transcribe() call is one attempt; a row that failed (or whose
        // on-device model was wiped and is now re-downloading) gets re-enqueued
        // by launch recovery / the retry loop, and a stale timestamp made the
        // TranscribingBanner show a huge elapsed (e.g. 84:15 for a 23s clip that
        // had only just restarted after an app update). The explicit
        // re-transcribe route also nils it for instant UI reset, but that path
        // doesn't cover recovery/retry, so the single source of truth is here.
        meeting.transcribingStartedAt = Int64(Date().timeIntervalSince1970 * 1000)

        // Resolve which provider this transcribe call ACTUALLY uses.
        // If the user picked an "advanced" (cloud) model AND the
        // monthly cap has already been hit, silently fall back to
        // on-device Whisper for this run instead of charging the
        // user beyond their plan. We don't mutate `AppSettings`
        // (the user's preference is intact for next month), the
        // helper just stashes the runtime choice so every read
        // inside this method goes through `currentProvider`.
        let userPick = AppSettings.transcriptionProvider
        var effective = userPick
        if userPick.usageClass == "advanced" {
            // No API key on disk for the chosen cloud provider →
            // every call would `throw .noKey`. Fall back to local
            // (if WhisperKit is available on this arch). Logs and
            // moves on rather than failing the meeting.
            if !cloudKeyAvailable(for: userPick), LocalWhisperTranscriber.isAvailable() {
                FileLogger.log("transcribe(): no API key for \(userPick), falling back to whisperLocal for this run")
                effective = .whisperLocal
            } else if let limit = AppSettings.userTier.advancedMonthlyLimitSeconds {
                let cal = Calendar(identifier: .gregorian)
                let now = Date()
                let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
                let sinceMs = Int64(monthStart.timeIntervalSince1970 * 1000)
                let bucket = (try? repo.usageSecondsByClass(sinceMs: sinceMs)) ?? [:]
                let simAdv = Int64(UserDefaults.standard.integer(forKey: "Corder.set.simAdvancedUsedSeconds"))
                let usedAdv = (bucket["advanced"] ?? 0) + simAdv
                if usedAdv >= Int64(limit) {
                    if LocalWhisperTranscriber.isAvailable() {
                        FileLogger.log("transcribe(): advanced cap reached (\(usedAdv)s used, limit \(limit)s), falling back to whisperLocal for this run")
                        effective = .whisperLocal
                    } else {
                        // Intel: no on-device fallback. Do NOT silently keep
                        // going on cloud, the SERVER cap is fail-open on a D1
                        // read error (returns 0 used), so an over-cap Intel
                        // user during a metering outage could leak unlimited
                        // paid cloud. Refuse the run with a cap message.
                        FileLogger.log("transcribe(): advanced cap reached on Intel (\(usedAdv)s/\(limit)s, no on-device fallback), refusing cloud for this run")
                        TranscriptionErrors.record(meetingId: meetingId,
                                                   message: "Monthly cloud limit reached. Upgrade your plan or wait for next month.")
                        try? repo.setStatus(meetingId: meetingId, status: .failed)
                        return
                    }
                }
            }
        }
        self.activeProvider = effective

        // Tag the row with the usage class for the EFFECTIVE
        // provider (so cap-fallback runs credit the local bucket,
        // not the cap'd advanced one). The Dashboard Usage bars
        // and the /api/usage aggregator key off this.
        meeting.transcriptionClass = effective.usageClass
        // Persist via a TARGETED update, not `updateMeeting(meeting)`: the
        // full struct still carries the pre-increment `transcribe_attempts`
        // and a full write would revert the bump from line ~226, wiping the
        // retry budget (always-failing rows would re-bill cloud every run).
        try? repo.setTranscribeStart(meetingId: meetingId,
                                     status: meeting.status,
                                     transcribingStartedAt: meeting.transcribingStartedAt,
                                     transcriptionClass: meeting.transcriptionClass ?? effective.usageClass)

        do {
            // 1. Locate raw recording files. Dual-track path needs both
            //    mic.wav and system.wav. Fallback to the legacy mix
            //    (audio.wav) only when we can't get them, typically an
            //    older recording that was already Dropbox-archived
            //    before this code shipped.
            let dir = AppPaths.recordingDir(for: meetingId)
            let micURL = URL(fileURLWithPath: meeting.audioPath)
            // System track has TWO possible sources, with opposite
            // failure modes:
            //  • system.wav    , Core Audio process tap. Captures
            //    real-call/VPIO audio, but is SILENT when the output
            //    route is Bluetooth (AirPods / BT headset).
            //  • system_sck.wav, ScreenCaptureKit audio. Survives BT
            //    output, but is silent on VPIO calls.
            // Choose between the two system tracks by ACTUAL speech
            // energy, not a binary "tap fully silent" gate. The old gate
            // only swapped to SCK when the tap had ZERO voiced windows
            // but on a Bluetooth output route the Core-Audio tap records
            // a faint, attenuated bleed (not true silence), so the gate
            // never tripped and the user got the garbled tap while the
            // clean SCK backup was thrown away. Now: on a BT route (flag
            // persisted at record time) the SCK track is authoritative
            // whenever it has real speech; otherwise SCK wins only when
            // it has materially MORE voiced speech than the tap, so a
            // real VPIO call (SCK digitally silent) still keeps the tap.
            // Near-tie / read-error → tap (historical default, never
            // regresses a good non-BT capture).
            let tapSystemURL = dir.appendingPathComponent("system.wav")
            let sckSystemURL = dir.appendingPathComponent("system_sck.wav")
            // Run the track chooser OFF the main actor: `voicedEnergy` does a
            // full-file decode of both system tracks, and transcribe() is
            // @MainActor, so on a long meeting this would stall the popover /
            // HUD. The decision logic is unchanged, only the heavy decode
            // moves off-main (mirrors the auto-transcribe-OFF chooser in
            // RecordingController). Returns just the chosen URL (Sendable).
            let btAtStart = meeting.outputBluetoothAtStart ?? false
            let systemURL: URL = await Task.detached {
                let tapExists = FileManager.default.fileExists(atPath: tapSystemURL.path)
                let sckExists = FileManager.default.fileExists(atPath: sckSystemURL.path)
                guard sckExists else { return tapSystemURL }
                guard tapExists else {
                    FileLogger.log("transcribe(): no tap system.wav, using system_sck.wav")
                    return sckSystemURL
                }
                guard let tap = VoiceActivityDetector.voicedEnergy(audioURL: tapSystemURL),
                      let sck = VoiceActivityDetector.voicedEnergy(audioURL: sckSystemURL)
                else { return tapSystemURL }
                let sckHasSpeech = sck.voicedMs >= 1500
                if btAtStart && sckHasSpeech {
                    FileLogger.log("transcribe(): BT output at record start → system_sck.wav (tap voiced=\(tap.voicedMs)ms rms=\(tap.meanRMS) | sck voiced=\(sck.voicedMs)ms rms=\(sck.meanRMS))")
                    return sckSystemURL
                }
                if sckHasSpeech && sck.voicedMs >= max(tap.voicedMs, 1) * 3 / 2 + 500 {
                    FileLogger.log("transcribe(): system_sck.wav dominates (\(sck.voicedMs)ms vs tap \(tap.voicedMs)ms) → using it")
                    return sckSystemURL
                }
                return tapSystemURL
            }.value
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
            // to mic.wav when it's absent, and nothing was generating it,
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
                    FileLogger.log("transcribe(): playback mix failed (\(error)), playback falls back to mic.wav for \(meetingId)")
                }
            }

            // Decide call-vs-in-person ONCE, here, so the cache key and
            // the transcription branch agree. system.wav counts as
            // silent if it doesn't exist, or exists but VAD finds no
            // speech. `detect` → nil on read error: be conservative and
            // treat that as "might be a call" (not silent), so we don't
            // wrongly bake the speaker hint into a real call's cache.
            let systemSilent: Bool
            var systemVadSegs = -1   // -1 = file absent; -2 = VAD read error
            if !systemExists {
                systemSilent = true
            } else {
                // Off-main, `detect` is another full-file decode (see chooser).
                let vad = await Task.detached { VoiceActivityDetector.detect(audioURL: systemURL) }.value
                systemVadSegs = vad?.count ?? -2
                systemSilent = (vad?.isEmpty == true)
            }
            // In-person = there's a mic but no usable remote track. This
            // is the ONLY path that feeds the clarify headcount into the
            // Gemini prompt, so it's the only cache key that must carry
            // the count.
            let inPerson = micExists && systemSilent

            // DIAGNOSTIC SUMMARY, one self-contained line so a Send-Report log
            // tail ALWAYS carries the capture/routing decision, with no need to
            // ask the user to dig. This is the signature for the "2 people → 1
            // speaker" class: bt=false + systemSilent=true + fork=in-person means
            // the far end reached only the mic via speaker bleed and got
            // collapsed; bt=true means a Bluetooth route genuinely lost it. Keep
            // this line cheap (no extra decode, it reuses values already
            // computed above) and present on EVERY transcribe.
            FileLogger.log("DIAG capture: meeting=\(meetingId) bt=\(meeting.outputBluetoothAtStart) micExists=\(micExists) systemExists=\(systemExists) systemSilent=\(systemSilent) systemVadSegs=\(systemVadSegs) fork=\(inPerson ? "in-person/mic-only" : "call/dual-track") provider=\(currentProvider.rawValue)")

            try Task.checkCancellation()

            // 2. Cache check. Both legacy single-stream and new
            //    dual-track shapes round-trip through CachedTranscript.
            //    Hash key for dual-track is "md5(mic.wav)+md5(system.wav)";
            //    for legacy it's md5(audio.wav). The two key spaces
            //    can't collide so a single column carries both.
            // Provider tag bakes into the cache key so flipping
            // Gemini ↔ Whisper never replays the other model's raw
            // turns. Stage 1 uses two prefixes, gemini-default
            // (unprefixed, preserves every existing cache hit) and
            // `whisper:v2:` for the new path. v2 = post-LLM-cleanup
            // (gpt-4o-mini polish for punctuation / capitalisation /
            // obvious typos); v1 records were raw whisper-1 output
            // and aren't replayable here, the prefix bump forces a
            // re-transcribe through the new polish stage.
            let providerTag: String = {
                switch currentProvider {
                case .gemini:        return ""
                case .whisper:       return "whisper:v2:"
                case .groq:
                    // Groq Whisper-large-v3-turbo. Distinct prefix from
                    // .whisper so a flip between OpenAI and Groq never
                    // replays the other backend's output (the models
                    // are close but not identical, large-v3 vs large-v2,
                    // and we don't run the gpt-4o-mini polish step
                    // on Groq, so the cleaned text differs as well).
                    return "groq:v1:"
                case .whisperLocal:
                    // Local Whisper keeps its own cache namespace so a
                    // flip between cloud and local never replays the
                    // other model's raw text. The VARIANT is part of the
                    // namespace too, Turbo and Small produce different raw
                    // turns, and without this a switch between them would
                    // replay the other model's transcript (a cache hit on
                    // the wrong model). v1 = first ship of the local provider.
                    return "whisper-local:v1:\(AppSettings.whisperLocalVariant.rawValue):"
                }
            }()
            let cacheKey: String
            // False when any source-WAV MD5 came back empty (a transient
            // read failure). Without this, the key degenerates to a shared
            // `…:` value and two meetings that both hit a read error collide,
            // one meeting's transcript replayed for another. When unusable
            // we neither read nor write the whole-meeting cache for this run.
            var cacheUsable = true
            if inPerson {
                // The expected-speaker hint is baked into the Gemini
                // prompt for the in-person path, so a different clarify
                // count produces genuinely different raw turns, it MUST
                // be part of the cache key. This covers BOTH mic-only
                // and "system.wav exists but is silent": picking "3"
                // after "2" was a no-op before because a silent-system
                // meeting still keyed on the plain dual hash and hit the
                // stale cached turns.
                // v2: diarize-first (FluidAudio decides WHO, Gemini
                // .single decides WHAT). The speaker count is now a hard
                // clustering constraint, not a Gemini prompt hint, so the
                // raw output differs from any v1 cache, the prefix bump
                // forces a clean re-transcribe instead of replaying stale
                // Gemini-diarized turns.
                let mh = (try? Self.md5OfFile(at: micURL)) ?? ""
                if mh.isEmpty { cacheUsable = false }
                let ex = meeting.expectedOtherSpeakers.map(String.init) ?? "nil"
                // v3: truncated Gemini chunks now force a split instead
                // of salvaging a partial, so the raw turn set (and its
                // timestamps) differ from any v2 cache.
                // v10: the system-track chooser may now select a
                // different raw audio source than the old "tap silent"
                // gate did, so any v9-cached turns can be stale, bump
                // to force a clean re-transcribe.
                cacheKey = "\(providerTag)inperson:v10:\(ex):\(mh)"
            } else if canDualTrack {
                // v2 + the other-speaker count: system.wav is now
                // diarized on-device with numSpeakers = expectedOther,
                // so the count affects raw output and must key the cache.
                let mh = (try? Self.md5OfFile(at: micURL)) ?? ""
                let sh = (try? Self.md5OfFile(at: systemURL)) ?? ""
                if mh.isEmpty || sh.isEmpty { cacheUsable = false }
                let ex = meeting.expectedOtherSpeakers.map(String.init) ?? "nil"
                // v11: mic.wav now passes through EchoSuppressor (far-end
                // bleed removed) before ASR when on speakers, the raw mic
                // text changes, so the key must bust the v10 cache once.
                // v12: a late-starting system.wav is now left-padded with
                // leading silence at capture time so mic/system share frame 0
                // (fixes the far-end overlaying the user's voice). The system
                // bytes change, so bust once more.
                cacheKey = "\(providerTag)dual:v12:\(ex):\(mh):\(sh)"
            } else {
                if !FileManager.default.fileExists(atPath: mixURL.path),
                   let remote = meeting.dropboxAudioPath {
                    FileLogger.log("transcribe(): legacy fallback, pulling mix from Dropbox \(remote)")
                    try await DropboxService.shared.download(remotePath: remote, to: mixURL)
                }
                let mxh = (try? Self.md5OfFile(at: mixURL)) ?? ""
                if mxh.isEmpty { cacheUsable = false }
                cacheKey = "\(providerTag)mix:" + mxh
            }

            // RAW Gemini text turns (the only thing a Gemini call buys).
            // WHEN/WHO is re-derived on-device from these every run, so a
            // cached raw set means timing can be fixed/iterated with ZERO
            // Gemini calls, and any cached meeting recovers for free.
            var rawUserTurns: [GeminiTranscriber.Turn] = []
            var rawOtherTurns: [GeminiTranscriber.Turn] = []
            var legacyTurns: [GeminiTranscriber.Turn] = []
            // Last-derived finals from cache: only used as a no-regression
            // fallback when the source wavs are gone so on-device
            // re-derivation is impossible.
            var cachedFinalUser: [GeminiTranscriber.Turn] = []
            var cachedFinalOther: [GeminiTranscriber.Turn] = []
            var cachedUserLabel: String? = nil
            var haveRaw = false                 // raw cached → no Gemini
            var usingDualTrack = canDualTrack

            if cacheUsable, !forceFresh,
               let cachedJSON = meeting.geminiRawTurns,
               let storedHash = meeting.audioHash,
               !storedHash.isEmpty,
               storedHash == cacheKey,
               let data = cachedJSON.data(using: .utf8),
               let bundle = try? JSONDecoder().decode(CachedTranscript.self, from: data) {
                if bundle.isDualTrack {
                    // New records carry rawUser/rawOther explicitly. Older
                    // v9 records only stored the FINAL (timed) turns, but
                    // relabel/alignByTokens never touch `.text`, so those
                    // finals' text+order ARE the raw Gemini turns. Either
                    // way the cached times are discarded: we re-derive
                    // WHEN/WHO on-device below.
                    rawUserTurns  = bundle.rawUserTurns  ?? bundle.userTurns  ?? []
                    rawOtherTurns = bundle.rawOtherTurns ?? bundle.otherTurns ?? []
                    cachedFinalUser  = bundle.userTurns  ?? []
                    cachedFinalOther = bundle.otherTurns ?? []
                    haveRaw = !rawUserTurns.isEmpty || !rawOtherTurns.isEmpty
                    usingDualTrack = true
                } else if let legacy = bundle.turns, !legacy.isEmpty {
                    legacyTurns = legacy
                    cachedUserLabel = bundle.userLabel
                    haveRaw = true
                    usingDualTrack = false
                }
            }

            if haveRaw {
                FileLogger.log("transcribe(): cache hit (raw turns), re-deriving timing on-device, no Gemini")
            } else if canDualTrack || micOnly {
                // call-vs-in-person decided above via `systemSilent`.
                if !systemSilent {
                    // Real call. mic.wav = you, system.wav = remote. Only
                    // the .single TEXT is fetched here (WHAT) via the active
                    // provider (Whisper / Groq / local Whisper, NOT Gemini
                    // unless explicitly overridden); WHEN/WHO is the
                    // on-device re-derive step below.
                    FileLogger.log("transcribe(): dual-track, \(currentProvider.rawValue) .single on mic + system (raw text only)")
                    // Speaker-bleed suppression. On speakers the far-end
                    // leaks into mic.wav and gets transcribed as the user
                    // (cross-language, even translated). Run the offline echo
                    // suppressor with system.wav as the clean reference and
                    // transcribe the CLEANED mic. Self-gating: returns nil on
                    // a headphone/BT recording (no acoustic coupling) → we
                    // fall back to the raw mic, so this is a no-op there.
                    let aecTempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("corder-aec-\(meetingId).wav")
                    let micTranscribeURL = EchoSuppressor.suppress(micURL: micURL, systemURL: systemURL, outURL: aecTempURL) ?? micURL
                    defer { if micTranscribeURL != micURL { try? FileManager.default.removeItem(at: aecTempURL) } }
                    // Per-track language tallies: WhisperTranscriber records
                    // the language Whisper detected for EACH chunk into these,
                    // so we can spot per-chunk drift (far-end chunks misheard
                    // as English and translated) and force-correct just the
                    // affected track below.
                    let micTally = WhisperTranscriber.LanguageTally()
                    let sysTally = WhisperTranscriber.LanguageTally()
                    do {
                        // Combine the two concurrent tracks' real per-window
                        // progress into one 0…0.9 fraction (last 10% is the
                        // diarization/mapping stage below). Monotonic.
                        let agg = ProgressAggregator(meetingId: meetingId)
                        async let micPart = WhisperTranscriber.$languageTally.withValue(micTally) {
                            try await geminiRawTurns(wavURL: micTranscribeURL, meetingId: meetingId,
                                                     onProgress: { agg.report(mic: $0) })
                        }
                        async let sysPart = WhisperTranscriber.$languageTally.withValue(sysTally) {
                            try await geminiRawTurns(wavURL: systemURL, meetingId: meetingId,
                                                     onProgress: { agg.report(sys: $0) })
                        }
                        let (u, o) = try await (micPart, sysPart)
                        rawUserTurns = u
                        rawOtherTurns = o
                    } catch let err as GeminiTranscriber.GError {
                        TranscriptionErrors.record(meetingId: meetingId,
                                                   message: err.localizedDescription)
                        throw err
                    }
                    // Whisper-only LLM polish stage. Punctuation /
                    // capitalisation / obvious-typo cleanup via
                    // gpt-4o-mini; same contract back (timestamps +
                    // speaker labels unchanged, only `.text` differs).
                    // Best-effort: a polish failure returns the raw
                    // turns, so this can never block the pipeline.
                    // Per-track polish keeps each speaker's lines in
                    // one numbered block, which matches what the model
                    // can actually reason about.
                    // LLM polish applies to both cloud and local Whisper,
                    // the polish stage only touches text and doesn't
                    // care where the raw turns came from.
                    // Language guard (Whisper/Groq only; Gemini transcribes
                    // in-language natively). Each chunk auto-detects its own
                    // language, so a BT-coded / quiet far-end can have a few
                    // chunks misheard as English, Whisper then TRANSLATES
                    // rather than transcribes them, and half the call comes
                    // back in the wrong language. Using the per-chunk language
                    // Whisper itself reported (reliable, unlike NL on Cyrillic)
                    // we take the meeting's majority language; any track whose
                    // OWN majority is that language yet also carries a minority
                    // of another (= drift) is re-transcribed forced to it. A
                    // track genuinely in another language (its majority differs)
                    // is left alone.
                    var meetingLang: String? = nil
                    if currentProvider != .gemini {
                        let meetingName = WhisperTranscriber.LanguageTally
                            .combinedDominantName(micTally, sysTally)
                        meetingLang = meetingName.flatMap(WhisperTranscriber.iso639)
                        FileLogger.log("transcribe(): meeting language '\(meetingName ?? "?")' → iso '\(meetingLang ?? "?")', mic \(micTally.snapshot().counts), sys \(sysTally.snapshot().counts)")
                        if let name = meetingName, let iso = meetingLang {
                            rawUserTurns = await rescueDriftedTrack(
                                turns: rawUserTurns, tally: micTally, meetingName: name,
                                forcedISO: iso, wavURL: micTranscribeURL, meetingId: meetingId)
                            rawOtherTurns = await rescueDriftedTrack(
                                turns: rawOtherTurns, tally: sysTally, meetingName: name,
                                forcedISO: iso, wavURL: systemURL, meetingId: meetingId)
                        }
                    }
                    // Fill voiced-but-untranscribed holes BEFORE polish so
                    // recovered text gets the same cleanup pass.
                    rawUserTurns = await recoverVoicedGaps(
                        turns: rawUserTurns, wavURL: micTranscribeURL,
                        referenceURL: systemURL,
                        meetingId: meetingId, languageISO: meetingLang)
                    rawOtherTurns = await recoverVoicedGaps(
                        turns: rawOtherTurns, wavURL: systemURL,
                        referenceURL: micTranscribeURL,
                        meetingId: meetingId, languageISO: meetingLang)
                    if currentProvider != .gemini {
                        // Give polish the DETECTED meeting language, not the
                        // English-only UI default, so it doesn't re-introduce
                        // the drift we just fixed at the ASR layer. Pinned
                        // setting still wins if the user set one.
                        let lang = AppSettings.transcriptionLanguage.nilIfEmpty ?? meetingLang ?? AppLanguage.current
                        // High-quality (gpt-4o) polish only on a MANUAL
                        // Re-transcribe (forceFresh); the first/auto pass uses
                        // the cheap model to keep the default path near-free.
                        rawUserTurns = await WhisperCleanup.polish(rawUserTurns, language: lang, highQuality: forceFresh)
                        rawOtherTurns = await WhisperCleanup.polish(rawOtherTurns, language: lang, highQuality: forceFresh)
                    }
                    usingDualTrack = true
                } else {
                    // In-person: everyone on the one mic. One Gemini
                    // .single pass over mic.wav for the text; the room
                    // headcount drives the on-device diarizer below.
                    let why = micOnly ? "no system.wav (mic-only)" : "system.wav has no speech"
                    FileLogger.log("transcribe(): \(why), in-person \(currentProvider.rawValue) .single on mic.wav (raw text only)")
                    usingDualTrack = true
                    rawOtherTurns = try await geminiRawTurns(wavURL: micURL, meetingId: meetingId)
                    rawUserTurns = []
                    rawOtherTurns = await recoverVoicedGaps(
                        turns: rawOtherTurns, wavURL: micURL,
                        meetingId: meetingId, languageISO: nil)
                    if currentProvider != .gemini {
                        let lang = AppSettings.transcriptionLanguage.nilIfEmpty ?? AppLanguage.current
                        rawOtherTurns = await WhisperCleanup.polish(
                            rawOtherTurns, language: lang, highQuality: forceFresh)
                    }
                }
            } else {
                FileLogger.log("transcribe(): legacy single-stream (no mic+system on disk), falling back to mix")
                switch currentProvider {
                case .gemini:
                    do {
                        legacyTurns = try await GeminiTranscriber.transcribe(audioURL: mixURL, mode: .diarize)
                    } catch let err as GeminiTranscriber.GError {
                        TranscriptionErrors.record(meetingId: meetingId,
                                                   message: err.localizedDescription)
                        throw err
                    }
                case .whisper:
                    do {
                        // Legacy mix is one merged stream, diarization
                        // labels come from the model itself
                        // (gpt-4o-transcribe-diarize).
                        let prompt = AppVocabulary.current.nilIfEmpty
                        legacyTurns = try await WhisperTranscriber.transcribe(
                            audioURL: mixURL, mode: .diarize, initialPrompt: prompt)
                    } catch let err as WhisperTranscriber.WhisperError {
                        TranscriptionErrors.record(meetingId: meetingId,
                                                   message: err.localizedDescription)
                        throw err
                    }
                    // LLM polish stage, same best-effort cleanup as
                    // the dual-track path. Legacy mix carries multiple
                    // speakers in one numbered block which the editor
                    // model handles fine (it's not asked to attribute,
                    // only to fix punctuation / typos line by line).
                    legacyTurns = await WhisperCleanup.polish(
                        legacyTurns,
                        language: AppSettings.transcriptionLanguage.nilIfEmpty ?? AppLanguage.current)
                case .groq:
                    // Groq Whisper-large-v3-turbo. Same .diarize mode
                    // call as OpenAI; backend swaps the proxy URL and
                    // model name. No polish stage, large-v3 punctuation
                    // is already cleaner than whisper-1's, and the cost
                    // savings disappear if we tack a gpt-4o-mini pass
                    // back on.
                    do {
                        let prompt = AppVocabulary.current.nilIfEmpty
                        legacyTurns = try await WhisperTranscriber.transcribe(
                            audioURL: mixURL, mode: .diarize,
                            initialPrompt: prompt, backend: .groq)
                    } catch let err as WhisperTranscriber.WhisperError {
                        TranscriptionErrors.record(meetingId: meetingId,
                                                   message: err.localizedDescription)
                        throw err
                    }
                case .whisperLocal:
                    // Local Whisper has no diarize mode, so the legacy mix
                    // case needs a cloud diarizer. Gemini is ADMIN-ONLY now
                    // (the hard provider lock), so only admins take the
                    // Gemini path; non-admins use Groq (paid) and Free
                    // which has no cloud at all, fails cleanly rather than
                    // ever reaching Gemini. Rare branch: only fires when the
                    // original wavs are gone and we transcribe a hydrated mix.
                    if AppSettings.isAdmin {
                        FileLogger.log("transcribe(): admin, whisperLocal + legacy mix → Gemini diarize")
                        do {
                            legacyTurns = try await GeminiTranscriber.transcribe(
                                audioURL: mixURL, mode: .diarize)
                        } catch let err as GeminiTranscriber.GError {
                            TranscriptionErrors.record(meetingId: meetingId, message: err.localizedDescription)
                            throw err
                        }
                    } else if AppSettings.userTier != .free {
                        FileLogger.log("transcribe(): whisperLocal + legacy mix → Groq diarize (Gemini is admin-only)")
                        do {
                            let prompt = AppVocabulary.current.nilIfEmpty
                            legacyTurns = try await WhisperTranscriber.transcribe(
                                audioURL: mixURL, mode: .diarize, initialPrompt: prompt, backend: .groq)
                        } catch let err as WhisperTranscriber.WhisperError {
                            TranscriptionErrors.record(meetingId: meetingId, message: err.localizedDescription)
                            throw err
                        }
                    } else {
                        FileLogger.log("transcribe(): whisperLocal + legacy mix on Free, no cloud diarizer available")
                        TranscriptionErrors.record(meetingId: meetingId,
                                                   message: "This archived recording needs a cloud model to separate speakers. Upgrade to Pro.")
                        throw WhisperTranscriber.WhisperError.tierRequired
                    }
                }
                usingDualTrack = false
            }

            try Task.checkCancellation()

            // Re-derive WHEN/WHO from the raw Gemini text using the
            // on-device forced-aligner + diarizer over the FULL
            // uncompressed wav. Free + deterministic, so it runs every
            // time, that's what lets the timing logic be fixed without
            // ever re-spending a Gemini call. Legacy single-stream keeps
            // Gemini's own diarization (no diarize-first), so it skips
            // this and uses legacyTurns as-is.
            var userTurns: [GeminiTranscriber.Turn] = []
            var otherTurns: [GeminiTranscriber.Turn] = []
            if usingDualTrack {
                let roomSize = meeting.expectedOtherSpeakers.map { $0 + 1 }
                // Immutable copy, captured by the parallel `async let`s
                // (a captured `var` is a Swift 6 concurrency error).
                // Gemini-diarize fallback is allowed ONLY on a fresh run, a
                // paid tier, AND an admin. Gemini is admin-only now (the
                // hard provider lock, normal users transcribe through Groq
                // or the on-device model, never Gemini). For a non-admin
                // whose on-device diarization yields nothing we keep the raw
                // local turns (their WhisperKit timing is reliable), exactly
                // as Free already does, never reach for Gemini.
                let geminiFallback = !haveRaw && AppSettings.userTier != .free && AppSettings.isAdmin
                // Fresh run with no Gemini fallback (Free): keep the raw ASR
                // turns (their own WhisperKit timing is reliable) instead of
                // dropping the track. Cache-hit re-derive keeps cached finals.
                let keepRaw = !haveRaw
                if systemSilent {
                    // In-person: every turn through the "other" bucket.
                    otherTurns = try await applyTiming(
                        rawTurns: rawOtherTurns, wavURL: micURL,
                        numSpeakers: roomSize, singlePass: true,
                        allowGeminiFallback: geminiFallback, keepRawIfNoDiar: keepRaw, meetingId: meetingId)
                    if otherTurns.isEmpty { otherTurns = cachedFinalOther }
                    userTurns = []
                } else {
                    // Immutable copies, the parallel `async let`s
                    // capture these (a captured `var` is a Swift 6
                    // concurrency error).
                    let rawU = rawUserTurns
                    let rawO = rawOtherTurns
                    let expectedOther = meeting.expectedOtherSpeakers
                    async let uT = applyTiming(
                        rawTurns: rawU, wavURL: micURL,
                        numSpeakers: 1, singlePass: false,
                        allowGeminiFallback: geminiFallback, keepRawIfNoDiar: keepRaw, meetingId: meetingId)
                    async let oT = applyTiming(
                        rawTurns: rawO, wavURL: systemURL,
                        numSpeakers: expectedOther, singlePass: false,
                        allowGeminiFallback: geminiFallback, keepRawIfNoDiar: keepRaw, meetingId: meetingId)
                    var (u, o) = try await (uT, oT)
                    if u.isEmpty { u = cachedFinalUser }
                    if o.isEmpty { o = cachedFinalOther }
                    // B, bleed suppression via a speaking-rate duration
                    // cap. numSpeakers:1 diarization of a mic that recorded
                    // the room (user on speakers) marks the whole call as
                    // "you", so the proportional time-placement stretches
                    // each short user utterance across the silence until the
                    // next one ("Нет" measured at 333 s on a 24-min meeting
                    // where the user actually spoke ~1 min). Clamp each user
                    // turn's duration to what its text could plausibly take.
                    userTurns = Self.capTurnDurations(u)
                    // Cap the OTHER (system / remote) turns too. Without it,
                    // the proportional time-placement stretches the far-end
                    // turns to fill silences and one speaker's timeline bar
                    // reads ~100% (e.g. other-0 covering the whole call when
                    // VAD found speech in only ~half of it). Same text-rate
                    // clamp, monotonic-shortening, no-op on tight turns.
                    otherTurns = Self.capTurnDurations(o)

                    // Cross-track dominance gate. Dual-track bleed makes both
                    // the mic and the system track look voiced at the same
                    // time, so each speaker's turns end up spread across the
                    // WHOLE recording and the timeline shows ~50% phantom
                    // overlap (the far-end as one solid 100% stripe). Keep
                    // each speaker's turns only where THEIR OWN track is the
                    // louder one. Computed once per track (100ms RMS), so
                    // it's cheap; a clean headphone recording is a near no-op.
                    // Off-main, frameRMS is a full-file decode per track.
                    let rms = await Task.detached { () -> ([Float], [Float])? in
                        guard let m = Self.frameRMS(micURL), let s = Self.frameRMS(systemURL) else { return nil }
                        return (m, s)
                    }.value
                    if let (micRMS, sysRMS) = rms {
                        let uBefore = userTurns.count
                        let oBefore = otherTurns.count
                        userTurns = Self.gateTurnsByDominance(userTurns, own: micRMS, rival: sysRMS)
                        otherTurns = Self.gateTurnsByDominance(otherTurns, own: sysRMS, rival: micRMS)
                        // Log the gate's effect, when far-end voice bleeds
                        // into the mic (user on speakers), the gate is what
                        // SHOULD strip the bleed turns. A report showing
                        // bleed text with "user N→N" (nothing dropped) means
                        // the gate didn't fire on that recording.
                        FileLogger.log("transcribe(): dominance gate, user \(uBefore)→\(userTurns.count), other \(oBefore)→\(otherTurns.count)")
                    } else {
                        FileLogger.log("transcribe(): dominance gate SKIPPED, frameRMS unreadable (no bleed suppression this run)")
                    }
                }
                FileLogger.log("transcribe(): timing re-derived, \(userTurns.count) user / \(otherTurns.count) other")
            }

            try Task.checkCancellation()

            // 2.5. Empty-recording short-circuit: when both tracks
            //      came back with zero turns (the VAD pre-pass found
            //      <500 ms of speech in each, or the mic was muted
            //      and the system stream was silent), there's nothing
            //      to map / boost / archive to Dropbox. Flip the row
            //      straight into the 7-day archive bin so the user
            //      doesn't see an empty session in their library
            //      it'll auto-purge after 7 days like any other
            //      archived meeting.
            let hasAnyContent = usingDualTrack
                ? (!userTurns.isEmpty || !otherTurns.isEmpty)
                : !legacyTurns.isEmpty
            if !hasAnyContent {
                FileLogger.log("transcribe(): no speech detected, auto-archiving \(meetingId)")
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                // Targeted writes (NOT full updateMeeting) so a pin/rename the
                // user did during the run survives the auto-archive.
                try? repo.setTranscribeFinished(meetingId: meetingId, status: .ready, transcribedAt: now)
                try? repo.setArchived(meetingId: meetingId, archivedAt: now)
                // Best-effort: drop the local audio dir too, there's
                // nothing of value in it. Dropbox archive is skipped
                // by virtue of returning before the upload branch.
                try? FileManager.default.removeItem(at: AppPaths.recordingDir(for: meetingId))
                return
            }

            // 3. Map turns → speakers + segments.
            let chosenUserLabel: String?
            // stampNow=false on a cache hit: don't refresh transcribedAt /
            // re-credit usage for a run that did no cloud work (see the
            // mappers). A fresh run (haveRaw=false) stamps as normal.
            if usingDualTrack {
                try mapDualTrackTurns(meetingId: meetingId, meeting: meeting,
                                      userTurns: userTurns, otherTurns: otherTurns,
                                      inPerson: inPerson,
                                      stampNow: !haveRaw,
                                      repo: repo)
                chosenUserLabel = nil    // not relevant in dual-track
            } else {
                chosenUserLabel = try mapTurnsToSpeakers(
                    meetingId: meetingId, meeting: meeting,
                    turns: legacyTurns, micURL: micURL, systemURL: systemURL,
                    forcedUserLabel: cachedUserLabel,
                    stampNow: !haveRaw,
                    repo: repo
                )
            }

            // Persist ALWAYS (not just on a miss): a cache HIT still
            // re-writes the bundle so old v9 records gain the explicit
            // raw* fields (migration) and the freshly re-derived finals
            // are kept as the no-audio fallback. Use the targeted
            // setRawTurnsCache helper rather than updateMeeting: the
            // local `meeting` copy still has status=.transcribing while
            // mapping just flipped the DB to .ready, and round-tripping
            // the stale local copy through updateMeeting would revert it.
            // Skip the cache write entirely when the key is degenerate
            // (empty source MD5), a cache keyed by a collision-prone value
            // is worse than no cache.
            if cacheUsable {
                let bundle: CachedTranscript
                if usingDualTrack {
                    bundle = CachedTranscript(userLabel: nil, turns: nil,
                                              userTurns: userTurns, otherTurns: otherTurns,
                                              rawUserTurns: rawUserTurns,
                                              rawOtherTurns: rawOtherTurns)
                } else {
                    bundle = CachedTranscript(userLabel: chosenUserLabel, turns: legacyTurns,
                                              userTurns: nil, otherTurns: nil,
                                              rawUserTurns: nil, rawOtherTurns: nil)
                }
                if let raw = try? JSONEncoder().encode(bundle),
                   let json = String(data: raw, encoding: .utf8) {
                    do {
                        try repo.setRawTurnsCache(meetingId: meetingId,
                                                  geminiRawTurns: json,
                                                  audioHash: cacheKey)
                        FileLogger.log("transcribe(): cached raw+final turns + audio_hash")
                    } catch {
                        // Surface the failure (was silently `try?`) so a
                        // disk-full / locked-DB write that strands the
                        // resume cache is at least visible in the log.
                        FileLogger.log("transcribe(): setRawTurnsCache FAILED (\(error)), meeting ready but cache not persisted")
                    }
                }
            } else {
                FileLogger.log("transcribe(): cache write skipped, degenerate key (source MD5 unreadable)")
            }

            // 3. Refetch (status is now .ready, transcribedAt set) for the
            //    archive + boost branches below.
            guard let updated = try? repo.meeting(id: meetingId) else { return }
            meeting = updated
            // Success, clear the attempt counter so a future failure gets
            // the full retry budget again.
            if meeting.status == .ready { try? repo.resetTranscribeAttempts(meetingId: meetingId) }

            // 3.5. Auto-title: one cheap text-only Gemini call from the
            //      fresh transcript. Best-effort + idempotent, only when
            //      it's actually ready, has content, and isn't titled
            //      yet, so a re-transcribe of an already-named meeting
            //      doesn't re-bill or churn the name. Targeted write so
            //      it can't clobber status.
            if AppSettings.autoTitle,
               meeting.status == .ready,
               (meeting.title?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                let segs = (try? repo.segments(forMeeting: meetingId)) ?? []
                let spks = (try? repo.speakers(forMeeting: meetingId)) ?? []
                if !segs.isEmpty {
                    let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)
                    if let title = await GeminiTitler.generate(transcript: text) {
                        try? repo.setTitle(meetingId: meetingId, title: title)
                        RecordingDirNaming.renameToTitled(repo: repo, meetingId: meetingId)
                        FileLogger.log("transcribe(): titled \(meetingId) → \"\(title)\"")
                    }
                }
            }

            // 3b. Optional auto-summary, run once per meeting after
            //     transcription finishes, only when the user opted in
            //     and the row doesn't already have a structured summary
            //     (handles re-transcribe + interrupted-app scenarios).
            //     Mirrors the auto-title invariant: bills once, can be
            //     re-triggered by clearing the cached summary.
            if AppSettings.autoSummary,
               meeting.status == .ready,
               (meeting.summary?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                let segs = (try? repo.segments(forMeeting: meetingId)) ?? []
                let spks = (try? repo.speakers(forMeeting: meetingId)) ?? []
                if !segs.isEmpty {
                    let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)
                    // Auto path is best-effort: a tier-gate (throws
                    // PaidFeatureError) or any failure just skips silently
                    // the on-demand route surfaces the upsell when the user
                    // opens the tab.
                    if let summary = try? await GeminiSummarizer.generate(transcript: text) {
                        try? repo.setSummary(meetingId: meetingId, summary: summary)
                        FileLogger.log("transcribe(): summarised \(meetingId) (\(summary.count) chars)")
                    }
                }
            }

            // 3c. Optional auto-chapters, Loom-style chapter markers
            //     for the new third tab. Same invariants as title /
            //     summary: bills once, can be re-triggered by clearing
            //     the cached `chapters` column. Feeds the model the
            //     per-segment start_ms so chapter timestamps can
            //     map cleanly to seek points.
            if AppSettings.autoChapters,
               meeting.status == .ready,
               (meeting.chapters?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                let segs = (try? repo.segments(forMeeting: meetingId)) ?? []
                if !segs.isEmpty {
                    let timed = segs.map { ($0.startMs, $0.text) }
                    if let chapters = try? await GeminiChapters.generate(timedLines: timed),
                       !chapters.isEmpty,
                       let data = try? JSONEncoder().encode(chapters),
                       let json = String(data: data, encoding: .utf8) {
                        try? repo.setChapters(meetingId: meetingId, chapters: json)
                        FileLogger.log("transcribe(): generated \(chapters.count) chapters for \(meetingId)")
                    }
                }
            }

            // 4. Dropbox archive, DISABLED. Legacy cloud-backup path,
            //    superseded by the (pending) R2 migration, same state as
            //    SupabaseSync's audio upload. It kept firing for configured
            //    accounts and failing on full ones (insufficient_space):
            //    log + bug-report noise for zero current benefit. Flip
            //    `dropboxArchiveEnabled` back to true when R2 backup ships.
            let dropboxArchiveEnabled = false
            if dropboxArchiveEnabled, DropboxService.shared.isConfigured {
                let mid = meetingId
                let videoURL = URL(fileURLWithPath: meeting.videoPath)
                let mixCopy = mixURL
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
                        // The Dropbox copy is just a cold-store backup
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
            // cancellation, NOT a failure, so it never writes `.failed`
            // over the successful run that replaced it.
            FileLogger.log("transcribe(): cancelled (URLError -999) for \(meetingId)")
        } catch {
            FileLogger.log("Corder transcription error: \(error)")
            // Targeted status flip, NOT updateMeeting(meeting). The local
            // copy is stale (pre-increment transcribe_attempts), and writing
            // the whole struct would revert the attempt counter, breaking the
            // retry budget (failedRetriableMeetingIds would never exclude a
            // permanently-failing row → unbounded paid re-transcribe loop).
            try? repo.setStatus(meetingId: meetingId, status: .failed)
            // Surface a Library-window toast for the failure. One
            // string for every failure mode on purpose, Костя's call:
            // no model-load vs network vs auth branching, no jargon.
            // Power users send the bug report (toolbar 🐞 button) and
            // we read the log; the user just needs to know "something
            // broke, ping us".
            let title = L.notif("transcribe_failed_title")
            LibraryWindow.shared.postToast(title: title, body: "", kind: "error")
        }
        // Post-transcribe Supabase sync: push speakers + segments
        // for cross-device read, and upload the playback mix +
        // raw tracks to Storage. All best-effort, the local
        // experience already works without any of this.
        await syncToSupabase(meetingId: meetingId)
    }

    /// Mirror this meeting's transcript + audio to Supabase.
    /// Idempotent, speakers/segments are wholesale-replaced server-
    /// side, recordings_meta upserts on `(meeting_id, kind)`. Safe
    /// to call repeatedly (e.g. after a re-transcribe).
    private func syncToSupabase(meetingId: String) async {
        let repo = await MainActor.run { AppContext.shared.repo }
        let speakers = (try? repo.speakers(forMeeting: meetingId)) ?? []
        let segments = (try? repo.segments(forMeeting: meetingId)) ?? []
        // Map local Speaker.id (string UUID) → fresh UUID we'll
        // push to the server, so segments can FK against the right
        // remote speaker row.
        var speakerUUIDs: [String: UUID] = [:]
        for s in speakers {
            speakerUUIDs[s.id] = UUID(uuidString: s.id) ?? UUID()
        }
        await MainActor.run {
            SupabaseSync.replaceSpeakersAndSegments(
                speakers: speakers,
                segments: segments,
                meetingId: meetingId,
                speakerIdByLocalId: speakerUUIDs)
        }
        // Audio upload. Mix is the playback file (always there once
        // transcribed); mic/system are the raw tracks (kept until
        // hard-delete). Each push is independent, a failure on one
        // doesn't block the others.
        let dir = AppPaths.recordingDir(for: meetingId)
        let mix = dir.appendingPathComponent("audio.wav")
        let mic = dir.appendingPathComponent("mic.wav")
        let sys = dir.appendingPathComponent("system.wav")
        let fm = FileManager.default
        if fm.fileExists(atPath: mix.path) {
            await SupabaseSync.uploadRecording(
                meetingId: meetingId, kind: "mix",
                fileURL: mix, durationMs: nil)
        }
        if fm.fileExists(atPath: mic.path) {
            await SupabaseSync.uploadRecording(
                meetingId: meetingId, kind: "mic",
                fileURL: mic, durationMs: nil)
        }
        if fm.fileExists(atPath: sys.path) {
            await SupabaseSync.uploadRecording(
                meetingId: meetingId, kind: "system",
                fileURL: sys, durationMs: nil)
        }
    }

    /// Map a [Turn] list (either freshly transcribed by Gemini or pulled
    /// from the cache) onto our speaker model and persist segments.
    /// Speakers are wiped and rewritten on every call, this is what
    /// makes the "clarify count → re-map without billing" path possible.
    /// Returns the chosen `userLabel` so the caller can persist it for
    /// future cache-hit re-maps (after Dropbox archival the channel-gate
    /// has no audio to compare with).
    @discardableResult
    private func mapTurnsToSpeakers(meetingId: String, meeting: Meeting,
                                    turns: [GeminiTranscriber.Turn],
                                    micURL: URL, systemURL: URL,
                                    forcedUserLabel: String? = nil,
                                    stampNow: Bool = true,
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
            // becomes the user, but only if it actually crosses some threshold.
            // Otherwise (cloud-only call where the mic was muted) nobody is.
            userLabel = userScore.filter { $0.value >= 1.5 }
                .max(by: { $0.value < $1.value })?.key
        }

        if meeting.expectedOtherSpeakers == 0 {
            FileLogger.log("mapTurns: expected_other_speakers=0, collapsing all turns onto user")
        }

        let userSpeakerId = "\(meetingId)-you"
        try repo.insertSpeaker(Speaker(id: userSpeakerId, meetingId: meetingId,
                                       label: "Speaker 1", customName: AppSettings.userName ?? "you", colorHex: "#3b82f6"))

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
            guard !Hallucinations.isHallucination(text) else {
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

        // Targeted write (NOT full updateMeeting): a transcribe can run for
        // minutes during which the user may pin / rename / set expected
        // speakers on the .transcribing row via other routes; a full-struct
        // write from the stale `meeting` snapshot would revert those edits.
        // Only refresh transcribedAt on a REAL run, a cache-hit re-map keeps
        // the original timestamp so an old meeting isn't pulled into the
        // current usage month and re-credited as if freshly transcribed.
        try repo.setTranscribeFinished(
            meetingId: meetingId, status: .ready,
            transcribedAt: stampNow ? Int64(Date().timeIntervalSince1970 * 1000) : nil)
        FileLogger.log("mapTurns: stored \(turns.count) turns for \(meetingId), userLabel=\(userLabel ?? "nil")")
        return userLabel
    }

    /// Dual-track mapping. `userTurns` are mic.wav (always "you"),
    /// `otherTurns` are system.wav (diarized 1+ remote speakers, labeled
    /// "Speaker 1" etc within that single track).
    ///
    /// Speaker assignment here is architecturally clean, no channel-gate
    /// guesswork, because each input was a single source. The
    /// `expectedOtherSpeakers == 0` ("Just me") clarify still works:
    /// we just drop everything from system.wav onto the user.
    /// Cross-track acoustic-echo filter. When the user records without
    /// headphones, whatever plays out the speakers (a call's far end, a
    /// video) is captured CLEAN by the Core-Audio process tap
    /// (`system.wav`) AND a second, degraded time by the microphone
    /// (`mic.wav`) as speaker→mic bleed. Both get transcribed, so every
    /// sentence appears twice, once as "Speaker 2", once as "you"
    /// the duplicated transcript the user hit while testing with a
    /// video. The tap is the true source; the mic copy is a delayed,
    /// lower-quality echo. So drop any mic turn whose words are largely
    /// contained in the system speech around the same time.
    ///
    /// Conservative by construction so it never fires in a real
    /// headphone meeting (where the mic has none of the system audio):
    /// only multi-word mic turns are judged, only against substantial
    /// nearby system speech, and only dropped at ≥66 % word coverage.
    /// Short backchannels ("да", "ну понятно") are always kept, so
    /// genuine overlapping conversation is unaffected.
    private static func echoFiltered(
        userTurns: [GeminiTranscriber.Turn],
        otherTurns: [GeminiTranscriber.Turn]
    ) -> [GeminiTranscriber.Turn] {
        guard !userTurns.isEmpty, !otherTurns.isEmpty else { return userTurns }

        func words(_ s: String) -> [String] {
            s.lowercased()
                .split { !CharacterSet.alphanumerics.contains($0.unicodeScalars.first!) }
                .map(String.init)
        }

        let others = otherTurns.map {
            (start: $0.startMs, end: $0.endMs, w: Set(words($0.text)))
        }
        // Generous slack: acoustic delay is tiny, but Gemini's turn
        // boundaries are coarse and the two tracks segment independently.
        let slackMs: Int64 = 4000

        var kept: [GeminiTranscriber.Turn] = []
        var dropped = 0
        for u in userTurns {
            let uw = Set(words(u.text))
            // Too short to attribute confidently → always keep.
            guard uw.count >= 5 else { kept.append(u); continue }

            var nearby = Set<String>()
            for o in others where u.startMs <= o.end + slackMs && o.start <= u.endMs + slackMs {
                nearby.formUnion(o.w)
            }
            guard nearby.count >= 5 else { kept.append(u); continue }

            let common = uw.filter { nearby.contains($0) }.count
            if Double(common) / Double(uw.count) >= 0.66 {
                dropped += 1
            } else {
                kept.append(u)
            }
        }
        if dropped > 0 {
            FileLogger.log("mapDual: echo-filter dropped \(dropped)/\(userTurns.count) mic turns (speaker→mic bleed of system audio)")
        }
        return kept
    }

    /// B, speaking-rate duration cap for the user (mic) track.
    /// numSpeakers:1 diarization of a mic that's recording the room (user
    /// on speakers) marks the whole call as "you", and the proportional
    /// time-placement then stretches each short user utterance across the
    /// silence until the next one ("Нет" measured at 333 s, "Или как-то…"
    /// at 447 s on a 24-min meeting where the user actually spoke ~1 min
    /// total). A human can't say 4 characters in 333 s, so we clamp each
    /// user turn's DURATION to what its text could plausibly take to
    /// speak, keeping the placed start.
    ///
    /// Safe by construction: monotonic-shortening only, it never
    /// lengthens a turn, never drops text, and leaves already-tight turns
    /// untouched, so a clean headphone meeting (timing already correct) is
    /// a no-op. On the real bleed recording this lands user coverage at
    /// 61 s, matching the independently measured "mic louder than far-end"
    /// voiced time, the cap converges on the acoustic ground truth.
    static func capTurnDurations(_ turns: [GeminiTranscriber.Turn]) -> [GeminiTranscriber.Turn] {
        guard !turns.isEmpty else { return turns }
        let msPerChar: Int64 = 120     // ~8 characters/second conversational speech
        let minMs: Int64 = 900         // a one-word turn still gets a visible ~0.9 s block
        var capped = 0
        let out = turns.map { t -> GeminiTranscriber.Turn in
            let dur = max(0, t.endMs - t.startMs)
            let cap = max(minMs, Int64(t.text.count) * msPerChar)
            guard dur > cap else { return t }
            capped += 1
            return GeminiTranscriber.Turn(speakerLabel: t.speakerLabel,
                                          startMs: t.startMs, endMs: t.startMs + cap, text: t.text)
        }
        if capped > 0 {
            let before = turns.reduce(Int64(0)) { $0 + max(0, $1.endMs - $1.startMs) } / 1000
            let after = out.reduce(Int64(0)) { $0 + max(0, $1.endMs - $1.startMs) } / 1000
            FileLogger.log("B/capTurns: capped \(capped)/\(turns.count) turns, coverage \(before)s → \(after)s")
        }
        return out
    }

    /// Per-100ms RMS of a WAV, mono-mixed, on a wall-clock grid (index i =
    /// [i*100ms, (i+1)*100ms)). Sample rate is normalised out, so the two
    /// dual-track files share one comparable time grid regardless of their
    /// individual rates. nil on read error.
    nonisolated static func frameRMS(_ url: URL, hopMs: Int = 100) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        guard sr > 0, file.length > 0 else { return [] }
        let total = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              (try? file.read(into: buf, frameCount: total)) != nil,
              let chans = buf.floatChannelData else { return nil }
        let frames = Int(buf.frameLength)
        let chCount = Int(format.channelCount)
        let hop = max(1, Int(Double(hopMs) * sr / 1000.0))
        var out: [Float] = []
        out.reserveCapacity(frames / hop + 1)
        var pos = 0
        while pos < frames {
            let end = min(pos + hop, frames)
            var sumSq: Float = 0
            for ch in 0..<chCount {
                let d = chans[ch]
                for i in pos..<end { sumSq += d[i] * d[i] }
            }
            out.append(sqrtf(sumSq / Float(max(1, (end - pos) * chCount))))
            pos += hop
        }
        return out
    }

    /// Cross-track dominance gate. Dual-track bleed (mic hears the far end
    /// and vice versa) makes BOTH tracks look "voiced" at the same time, so
    /// each speaker's turns get placed across ~the whole recording, the
    /// far-end timeline reads as one solid 100% stripe. We keep each turn
    /// only where ITS OWN track is louder than the rival, on a 100ms grid,
    /// after normalising each track by its own loud level (so a quieter
    /// recorded track isn't unfairly beaten everywhere). A turn with no
    /// own-dominant frame collapses to a point (text kept, no timeline
    /// block). Clean headphone meetings (no bleed) are a near no-op: the
    /// own track is the only one voiced in its turns. Returns turns clipped
    /// to [first dominant, last dominant] inside each original span.
    static func gateTurnsByDominance(_ turns: [GeminiTranscriber.Turn],
                                     own: [Float], rival: [Float],
                                     hopMs: Int = 100) -> [GeminiTranscriber.Turn] {
        guard !turns.isEmpty, !own.isEmpty else { return turns }
        // Reference level per track = 90th percentile of its non-trivial
        // frames, a robust proxy for that track's normal speech loudness.
        func ref(_ a: [Float]) -> Float {
            let v = a.filter { $0 > 0.003 }.sorted()
            if v.isEmpty { return 1 }
            let idx = min(v.count - 1, max(0, Int(Double(v.count) * 0.9)))
            return max(1e-4, v[idx])
        }
        let rOwn = ref(own), rRival = ref(rival)
        let floor: Float = 0.004
        // A turn whose own track is SILENT across its whole span (max RMS
        // below this) carries no real speech, it's a Whisper silence-
        // hallucination or pure far-end bleed, and must be DROPPED, not kept
        // as a phantom point. Sits above the dominance `floor` (0.004) so
        // genuinely quiet-but-real speech (which has peaks well above it) is
        // preserved. This is what stopped "Но это от моего микрофона" from
        // being invented onto a silent mic while a video played (measured
        // mic RMS ≈ 0.001 there vs system ≈ 0.025).
        let speechFloor: Float = 0.006
        func dominant(_ i: Int) -> Bool {
            let o = i < own.count ? own[i] : 0
            let r = i < rival.count ? rival[i] : 0
            return o >= floor && (o / rOwn) > (r / rRival)
        }
        var gated = 0, dropped = 0
        let out = turns.compactMap { t -> GeminiTranscriber.Turn? in
            let f0 = Int(t.startMs) / hopMs
            let f1 = max(f0, Int(t.endMs) / hopMs)
            var first = -1, last = -1
            var maxOwn: Float = 0
            var i = f0
            while i <= f1 {
                let o = i < own.count ? own[i] : 0
                if o > maxOwn { maxOwn = o }
                if dominant(i) { if first < 0 { first = i }; last = i }
                i += 1
            }
            guard first >= 0 else {
                // No own-dominant frame. If the own track is also silent over
                // the whole span, there's no real speech to attribute → drop
                // the turn (hallucination/bleed). Otherwise it's quiet real
                // speech beaten by a louder rival → keep the text as a point.
                if maxOwn < speechFloor { dropped += 1; return nil }
                gated += 1
                return GeminiTranscriber.Turn(speakerLabel: t.speakerLabel,
                                              startMs: t.startMs, endMs: t.startMs, text: t.text)
            }
            let ns = Int64(first * hopMs), ne = Int64((last + 1) * hopMs)
            let cs = max(t.startMs, min(ns, t.endMs))
            let ce = max(cs, min(ne, t.endMs))
            if cs != t.startMs || ce != t.endMs { gated += 1 }
            return GeminiTranscriber.Turn(speakerLabel: t.speakerLabel,
                                          startMs: cs, endMs: ce, text: t.text)
        }
        if gated > 0 || dropped > 0 {
            let before = turns.reduce(Int64(0)) { $0 + max(0, $1.endMs - $1.startMs) } / 1000
            let after = out.reduce(Int64(0)) { $0 + max(0, $1.endMs - $1.startMs) } / 1000
            FileLogger.log("dominanceGate: clipped \(gated)/\(turns.count) turns, dropped \(dropped) silent-track hallucinations, coverage \(before)s → \(after)s")
        }
        return out
    }

    private func mapDualTrackTurns(meetingId: String, meeting: Meeting,
                                   userTurns rawUserTurns: [GeminiTranscriber.Turn],
                                   otherTurns: [GeminiTranscriber.Turn],
                                   inPerson: Bool = false,
                                   stampNow: Bool = true,
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
                                 turns: otherTurns, stampNow: stampNow, repo: repo)
            return
        }

        // Strip speaker→mic echo BEFORE anything keys off the mic track.
        // If the whole mic was just bleed of the system audio this comes
        // back empty, so `userHasContent` is false and no ghost
        // "Speaker 1 / you" row is created (which would also skew the
        // clarify banner). The rest of the function is unchanged, it
        // just sees the cleaned mic turns under the same name.
        let userTurns = Self.echoFiltered(userTurns: rawUserTurns,
                                          otherTurns: otherTurns)

        let userSpeakerId = "\(meetingId)-you"
        let collapseAll = (meeting.expectedOtherSpeakers == 0)
        // "User said there's exactly 1 other person on the call", fold
        // every Gemini label inside system.wav into a single "Speaker 2"
        // bucket. This is the common case for auto-detected 1:1 calls,
        // and it's also the right answer when the clarify banner pill
        // "2 people" is clicked. Without this collapse, Gemini's
        // over-counting (5 labels on a 12-minute call with one
        // interlocutor) would leak straight through.
        let collapseOthers = (meeting.expectedOtherSpeakers == 1)
        // Only persist the user speaker when they'll actually own
        // segments, either they spoke (userTurns non-empty) or
        // `collapseAll` will land every other-turn on the user. The
        // previous unconditional insert left a ghost "Speaker 1" row
        // for dual-track recordings where the mic was silent, that
        // row inflated `speakers.length` and skewed the clarify banner
        // to a higher pill than the actual speaker count.
        let userHasContent = collapseAll || !userTurns.isEmpty
        if userHasContent {
            try repo.insertSpeaker(Speaker(id: userSpeakerId, meetingId: meetingId,
                                           label: "Speaker 1", customName: AppSettings.userName ?? "you", colorHex: "#3b82f6"))
        }

        // Each distinct label inside system.wav maps to one "other" id
        // unless `collapseOthers` is on, in which case every label gets
        // folded into a single bucket.
        let othersLabelOffset = userHasContent ? 2 : 1
        let singleOtherSpeakerId = "\(meetingId)-other-0"
        var otherSpeakerIds: [String: String] = [:]
        if collapseAll {
            // no "other" rows, everything lands on the user
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
        // correct chronological order, even when user and remote
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
            guard !Hallucinations.isHallucination(text) else {
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

        // Targeted write (NOT full updateMeeting) so concurrent pin / title /
        // expected-speaker edits made during the run aren't reverted from the
        // stale snapshot; cache-hit re-map keeps the original month.
        try repo.setTranscribeFinished(
            meetingId: meetingId, status: .ready,
            transcribedAt: stampNow ? Int64(Date().timeIntervalSince1970 * 1000) : nil)
        FileLogger.log("mapDual: stored \(items.count) items (user=\(userTurns.count), other=\(otherTurns.count)) for \(meetingId)")
    }

    /// In-person mapping. Everyone, including the device owner, was on
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
    ///     voice) and we NEVER collapse to 1 here, that was the bug
    ///     where picking "2"/"3" showed 1/2.
    private func mapInPersonTurns(meetingId: String, meeting: Meeting,
                                  turns: [GeminiTranscriber.Turn],
                                  stampNow: Bool = true,
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
            // "Just me", fold everything onto one speaker.
            let sink = distinctLabels.first ?? "Speaker 1"
            for l in distinctLabels { labelRemap[l] = sink }
            keptLabels = distinctLabels.isEmpty ? [] : [sink]
        } else if expected == nil {
            // Unspecified, trust Gemini's diarization verbatim.
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

        // One Speaker row per kept label. No "you", in-person has no
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
            guard !Hallucinations.isHallucination(text) else {
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

        // Targeted write (NOT full updateMeeting) so concurrent pin / title /
        // expected-speaker edits made during the run aren't reverted from the
        // stale snapshot; cache-hit re-map keeps the original month.
        try repo.setTranscribeFinished(
            meetingId: meetingId, status: .ready,
            transcribedAt: stampNow ? Int64(Date().timeIntervalSince1970 * 1000) : nil)
        FileLogger.log("mapInPerson: stored \(stored) segs, kept \(keptLabels.count) speakers (expectedOther=\(expected.map(String.init) ?? "nil"), distinct=\(distinctLabels.count)) for \(meetingId)")
    }

    /// Diarize-first transcription of one track. FluidAudio decides WHO
    /// (globally-stable labels, the known speaker count enforced as a
    /// hard clustering constraint), the cloud ASR provider decides WHAT
    /// (verbatim text + timestamps, no LLM speaker-counting). The two
    /// run in parallel; ASR turns are then re-labeled by temporal
    /// overlap with the diarization timeline.
    ///
    /// Provider routing: `.gemini` (default) sends `.single` to
    /// gemini-2.5-flash; `.whisper` sends `.single` to OpenAI
    /// gpt-4o-mini-transcribe. Both return `[GeminiTranscriber.Turn]`,
    /// so the rest of the pipeline is provider-agnostic.
    ///
    /// Fallback: if on-device diarization is unavailable (models not yet
    /// downloaded on a first-ever offline run, no speech, Core ML
    /// error), we drop back to Gemini's own `.diarize` so a meeting
    /// never hard-fails worse than the pre-FluidAudio behaviour. (We
    /// keep Gemini for this fallback regardless of provider: it's the
    /// only path that gives us speaker labels from the model itself,
    /// and it's a rare hit anyway. TODO once Whisper is the steady
    /// state: ship a Whisper-native diarize fallback via gpt-4o-
    /// transcribe-diarize.) An ASR/quota/network error from the active
    /// provider is a real failure and propagates.
    /// Shared "user picked a cloud provider but their tier doesn't
    /// cover it" recovery. Flips the persisted override back to `.auto`
    /// (which resolves to `.whisperLocal` on free), surfaces a single
    /// "Cloud needs Pro" line into TranscriptionErrors for the toast,
    /// and re-runs the same track through local Whisper for THIS call.
    /// On Intel where local Whisper isn't available we re-throw the
    /// tier error, there's nothing useful we can fall back to.
    private func fallbackToLocalAfterTierGate(wavURL: URL,
                                              meetingId: String) async throws -> [GeminiTranscriber.Turn] {
        FileLogger.log("Whisper tier-gate: cloud refused, falling back to whisperLocal for \(meetingId)")
        AppSettings.clearTranscriptionProviderOverride()
        TranscriptionErrors.record(meetingId: meetingId,
                                   message: "Cloud models need Pro or Max. Using local model.")
        guard LocalWhisperTranscriber.isAvailable() else {
            throw WhisperTranscriber.WhisperError.tierRequired
        }
        let variant = AppSettings.whisperLocalVariant
        try await LocalWhisperTranscriber.ensureModelReady(variant)
        let prompt = AppVocabulary.current.nilIfEmpty
        return try await LocalWhisperTranscriber.transcribe(
            audioURL: wavURL, mode: .single, variant: variant, initialPrompt: prompt)
    }

    /// Thread-safe combiner for the two concurrent tracks' real progress.
    /// Each track reports 0…1; we publish the average scaled to 0…0.9
    /// (the final 10% is the on-device diarize/map stage). Monotonic via
    /// the store's max-on-write. `@unchecked Sendable` is safe: all mutable
    /// state is guarded by the lock.
    private final class ProgressAggregator: @unchecked Sendable {
        private let lock = NSLock()
        private var micFrac = 0.0
        private var sysFrac = 0.0
        private let meetingId: String
        init(meetingId: String) { self.meetingId = meetingId }
        func report(mic f: Double) { publish { self.micFrac = max(self.micFrac, f) } }
        func report(sys f: Double) { publish { self.sysFrac = max(self.sysFrac, f) } }
        private func publish(_ mutate: () -> Void) {
            lock.lock(); mutate(); let c = (micFrac + sysFrac) / 2 * 0.9; lock.unlock()
            TranscriptionProgressStore.set(meetingId: meetingId, fraction: c)
        }
    }

    /// Re-transcribe a track forced to the meeting language when Whisper's own
    /// per-chunk detection shows the track is MOSTLY the meeting language but
    /// drifted on some chunks (misheard as another language and translated).
    /// A track whose own majority is a DIFFERENT language is genuinely in that
    /// language and is left untouched. Best-effort: any failure or empty
    /// re-pass keeps the original turns. The forced pass misses the resume
    /// cache (its key now carries the language), so it really re-runs ASR
    /// rather than replaying the wrong-language chunks.
    private func rescueDriftedTrack(
        turns: [GeminiTranscriber.Turn],
        tally: WhisperTranscriber.LanguageTally,
        meetingName: String,
        forcedISO: String,
        wavURL: URL,
        meetingId: String) async -> [GeminiTranscriber.Turn] {
        guard !turns.isEmpty else { return turns }
        let snapshot = tally.snapshot()
        // The track's own dominant must BE the meeting language (else it is
        // genuinely another language, don't clobber it) AND it must carry
        // some minority weight in a different language (the drift to fix).
        guard snapshot.dominantName == meetingName else { return turns }
        let hasDrift = snapshot.counts.contains { $0.key != meetingName && $0.value > 0 }
        guard hasDrift else { return turns }
        let drifted = snapshot.counts.filter { $0.key != meetingName }
            .map { "\($0.key)×\($0.value)" }.joined(separator: ",")
        FileLogger.log("transcribe(): \(wavURL.lastPathComponent) language drift (\(drifted)) vs meeting '\(meetingName)', re-transcribing forced to '\(forcedISO)'")
        let forced = try? await WhisperTranscriber.$languageOverride.withValue(forcedISO) {
            try await geminiRawTurns(wavURL: wavURL, meetingId: meetingId)
        }
        guard let forced, !forced.isEmpty else {
            FileLogger.log("transcribe(): \(wavURL.lastPathComponent) forced re-pass empty/failed, keeping original")
            return turns
        }
        FileLogger.log("transcribe(): \(wavURL.lastPathComponent) forced re-pass produced \(forced.count) turns in '\(forcedISO)'")
        return forced
    }

    /// Re-ASR stretches of clearly-voiced audio that came back with NO turns.
    ///
    /// Whisper occasionally skips a sizeable run of real speech mid-chunk:
    /// measured on a real call, 13 s of clear, mic-dominant speech returned
    /// zero turns — the audio WAS in the compressed upload (VAD passed it),
    /// the model just produced nothing for it (mumbled / disfluent speech
    /// makes this more likely). The VAD knows exactly where speech is, so
    /// any voiced stretch with >= 3.5 s of speech and no turn within 1 s is
    /// cut out of the wav and sent as its own tiny ASR request — a fresh,
    /// short context reliably transcribes what a long chunk skipped.
    /// Recovered turns are offset back onto the track's timeline and merged
    /// in. Additive-only: existing turns are never touched, hallucinated /
    /// empty recoveries are dropped, and any failure leaves the track
    /// exactly as it was. An all-empty track is left alone (that is the
    /// designed "silent track → no segments" outcome, not a gap).
    private func recoverVoicedGaps(turns: [GeminiTranscriber.Turn],
                                   wavURL: URL,
                                   referenceURL: URL? = nil,
                                   meetingId: String,
                                   languageISO: String?) async -> [GeminiTranscriber.Turn] {
        guard !turns.isEmpty else { return turns }
        // With a sibling track available, gate gap detection on cross-track
        // DOMINANCE, not plain VAD: on a mic track the far end's speaker
        // bleed is "voiced" too, and every bleed stretch Whisper (rightly)
        // ignored would read as a fake gap — measured 10 windows of which
        // only the truly-dominant ones held real skipped speech. Dominant
        // spans keep exactly the stretches where THIS track's speaker is
        // the one talking.
        let spans: [VoiceActivityDetector.SpeechSegment]?
        if let referenceURL, FileManager.default.fileExists(atPath: referenceURL.path) {
            spans = VoiceActivityDetector.dominanceMap(primaryURL: wavURL,
                                                       referenceURL: referenceURL)?.spans
        } else {
            spans = VoiceActivityDetector.detect(audioURL: wavURL)
        }
        guard let spans, let lastSpan = spans.last else { return turns }

        // 100 ms bitmap: voiced AND not within 1 s of any existing turn.
        let stepMs: Int64 = 100
        let n = Int(lastSpan.endMs / stepMs) + 1
        var uncovered = [Bool](repeating: false, count: n)
        for sp in spans {
            let lo = max(0, Int(sp.startMs / stepMs))
            let hi = min(n, Int(sp.endMs / stepMs))
            for k in lo..<hi { uncovered[k] = true }
        }
        for t in turns {
            let lo = max(0, Int((t.startMs - 1000) / stepMs))
            let hi = min(n, Int((t.endMs + 1000) / stepMs))
            guard hi > lo else { continue }
            for k in lo..<hi { uncovered[k] = false }
        }

        // Runs of uncovered speech; nearby runs (a breath apart) merge into
        // one window so we recover a whole skipped passage in one request.
        var windows: [(start: Int64, end: Int64, voicedMs: Int64)] = []
        var k = 0
        while k < n {
            guard uncovered[k] else { k += 1; continue }
            var j = k
            while j < n, uncovered[j] { j += 1 }
            let run = (start: Int64(k) * stepMs, end: Int64(j) * stepMs,
                       voicedMs: Int64(j - k) * stepMs)
            if let last = windows.last, run.start - last.end <= 2000 {
                windows[windows.count - 1] = (last.start, run.end, last.voicedMs + run.voicedMs)
            } else {
                windows.append(run)
            }
            k = j
        }
        windows = windows.filter { $0.voicedMs >= 3500 }
        guard !windows.isEmpty else { return turns }
        if windows.count > 6 {
            FileLogger.log("gap recovery: \(wavURL.lastPathComponent), \(windows.count) windows found, capping at 6")
            windows = Array(windows.prefix(6))
        }

        var out = turns
        var recoveredCount = 0
        for w in windows {
            let ws = max(0, w.start - 500)
            let we = w.end + 500
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("corder-gap-\(meetingId)-\(ws).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? VoiceActivityDetector.concatenateSpeech(
                audioURL: wavURL,
                segments: [.init(startMs: ws, endMs: we)],
                outURL: tmp)) != nil else { continue }
            let recovered: [GeminiTranscriber.Turn]?
            if let iso = languageISO, currentProvider != .gemini {
                // Force the meeting language: a 10-second mumble chunk is
                // exactly what per-chunk auto-detect mishears (and Whisper
                // then translates instead of transcribing).
                recovered = try? await WhisperTranscriber.$languageOverride.withValue(iso) {
                    try await self.geminiRawTurns(wavURL: tmp, meetingId: meetingId)
                }
            } else {
                recovered = try? await geminiRawTurns(wavURL: tmp, meetingId: meetingId)
            }
            guard let recovered, !recovered.isEmpty else { continue }
            for r in recovered {
                let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !Hallucinations.isHallucination(text) else { continue }
                let rs = min(we, ws + max(0, r.startMs))
                let re = min(we + 500, max(rs + 400, ws + r.endMs))
                out.append(GeminiTranscriber.Turn(speakerLabel: r.speakerLabel,
                                                  startMs: rs, endMs: re, text: text))
                recoveredCount += 1
            }
        }
        guard recoveredCount > 0 else {
            FileLogger.log("gap recovery: \(wavURL.lastPathComponent), \(windows.count) voiced-untranscribed windows, nothing recovered")
            return turns
        }
        out.sort { $0.startMs < $1.startMs }
        let totalVoiced = windows.reduce(Int64(0)) { $0 + $1.voicedMs }
        FileLogger.log("gap recovery: \(wavURL.lastPathComponent), recovered \(recoveredCount) turns from \(windows.count) windows (\(totalVoiced / 1000)s voiced audio ASR had skipped)")
        return out
    }

    private func geminiRawTurns(wavURL: URL,
                                meetingId: String,
                                onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [GeminiTranscriber.Turn] {
        switch currentProvider {
        case .gemini:
            do {
                return try await GeminiTranscriber.transcribe(
                    audioURL: wavURL, mode: .single, singlePass: false)
            } catch let err as GeminiTranscriber.GError {
                TranscriptionErrors.record(meetingId: meetingId,
                                           message: err.localizedDescription)
                throw err
            }
        case .whisper:
            do {
                // Initial prompt, same vocabulary lever the Gemini
                // path uses, just routed through Whisper's `prompt=`
                // parameter. Whisper biases recognition toward the
                // words in the prompt, which is exactly the right
                // thing for personal names + domain jargon (the
                // categories Whisper otherwise mishears most). 224
                // tokens is the documented cap; we send a string,
                // OpenAI tokenises and truncates.
                let prompt = AppVocabulary.current.nilIfEmpty
                // Pass the on-device model so a mid-run network drop is
                // recovered per-chunk locally instead of failing the
                // whole meeting (only when that model is already on disk).
                return try await WhisperTranscriber.transcribe(
                    audioURL: wavURL, mode: .single, initialPrompt: prompt,
                    localFallbackVariant: LocalWhisperTranscriber.fallbackVariant(),
                    onProgress: onProgress)
            } catch WhisperTranscriber.WhisperError.tierRequired {
                return try await fallbackToLocalAfterTierGate(
                    wavURL: wavURL, meetingId: meetingId)
            } catch let err as WhisperTranscriber.WhisperError {
                TranscriptionErrors.record(meetingId: meetingId,
                                           message: err.localizedDescription)
                throw err
            }
        case .groq:
            // Same single-pass call as OpenAI path; backend swap moves
            // the request to /transcribe/groq (worker proxies to
            // api.groq.com with the org key) and pins the model to
            // whisper-large-v3-turbo. Polish stage skipped on purpose.
            do {
                let prompt = AppVocabulary.current.nilIfEmpty
                return try await WhisperTranscriber.transcribe(
                    audioURL: wavURL, mode: .single,
                    initialPrompt: prompt, backend: .groq,
                    localFallbackVariant: LocalWhisperTranscriber.fallbackVariant(),
                    onProgress: onProgress)
            } catch WhisperTranscriber.WhisperError.tierRequired {
                return try await fallbackToLocalAfterTierGate(
                    wavURL: wavURL, meetingId: meetingId)
            } catch let err as WhisperTranscriber.WhisperError {
                TranscriptionErrors.record(meetingId: meetingId,
                                           message: err.localizedDescription)
                throw err
            }
        case .whisperLocal:
            // Apple-Silicon-only, gracefully fall back on Intel rather than
            // hard-failing the meeting. Gemini is ADMIN-ONLY now (the hard
            // provider lock), so only admins fall back to Gemini; non-admins
            // use Groq (paid), and Free, no cloud at all, hard-fails.
            guard LocalWhisperTranscriber.isAvailable() else {
                if AppSettings.isAdmin {
                    FileLogger.log("LocalWhisper: Intel + admin, falling back to Gemini for this track")
                    do {
                        return try await GeminiTranscriber.transcribe(
                            audioURL: wavURL, mode: .single, singlePass: false)
                    } catch let err as GeminiTranscriber.GError {
                        TranscriptionErrors.record(meetingId: meetingId, message: err.localizedDescription)
                        throw err
                    }
                } else if AppSettings.userTier != .free {
                    FileLogger.log("LocalWhisper: Intel, falling back to Groq for this track (Gemini is admin-only)")
                    do {
                        let prompt = AppVocabulary.current.nilIfEmpty
                        return try await WhisperTranscriber.transcribe(
                            audioURL: wavURL, mode: .single, initialPrompt: prompt, backend: .groq)
                    } catch let err as WhisperTranscriber.WhisperError {
                        TranscriptionErrors.record(meetingId: meetingId, message: err.localizedDescription)
                        throw err
                    }
                } else {
                    FileLogger.log("LocalWhisper: Intel + Free, no local model and no cloud allowed")
                    TranscriptionErrors.record(meetingId: meetingId,
                                               message: "The on-device model needs Apple Silicon. Upgrade to Pro for cloud transcription.")
                    throw WhisperTranscriber.WhisperError.tierRequired
                }
            }
            // FIRST-TRANSCRIPT RESCUE. The Turbo model is ~1.5 GB and is
            // prefetched at launch, so a user who records and transcribes
            // within the first minutes hits `ensureModelReady`, which then
            // BLOCKS on the in-flight prefetch. Measured on a real user
            // (0.15.44, launch day): he waited 4 minutes staring at
            // "Downloading model…" and cancelled — the first transcript, on
            // the first run, never arrived. So when the model isn't on disk
            // yet, don't wait for it: transcribe THIS track in the cloud and
            // let the download finish in the background. From the next
            // transcript on, the model is local and nothing leaves the Mac.
            //
            // Signed-in only: the Worker authenticates by JWT (and meters the
            // free monthly cloud budget), so a guest has no cloud to fall back
            // to and waits for the model exactly as before.
            let localVariant = AppSettings.whisperLocalVariant
            if !LocalWhisperTranscriber.isModelDownloaded(localVariant), AppSettings.isSignedIn {
                let pct = LocalWhisperTranscriber.currentProgress(localVariant).map { Int($0 * 100) }
                FileLogger.log("LocalWhisper: model still downloading (\(pct.map { "\($0)%" } ?? "queued")), transcribing this track in the cloud so the first transcript isn't blocked")
                do {
                    let prompt = AppVocabulary.current.nilIfEmpty
                    return try await WhisperTranscriber.transcribe(
                        audioURL: wavURL, mode: .single, initialPrompt: prompt,
                        backend: .groq, onProgress: onProgress)
                } catch {
                    // Cloud refused (over the free budget, no network, Worker
                    // down). Fall through to the local path and wait for the
                    // model — slow, but it still produces a transcript.
                    FileLogger.log("LocalWhisper: cloud bridge failed (\(error)), waiting for the on-device model instead")
                }
            }

            do {
                // Same vocabulary lever as cloud Whisper, but
                // LocalWhisperTranscriber tokenises the prompt itself
                // (WhisperKit takes token IDs, not raw text). Variant
                // is the user's picked size (turbo/small/base/tiny);
                // ensureModelReady downloads on demand if the picked
                // variant isn't on disk yet.
                let variant = localVariant
                try await LocalWhisperTranscriber.ensureModelReady(variant)
                let prompt = AppVocabulary.current.nilIfEmpty
                return try await LocalWhisperTranscriber.transcribe(
                    audioURL: wavURL, mode: .single, variant: variant,
                    initialPrompt: prompt, onProgress: onProgress)
            } catch let err as LocalWhisperTranscriber.LocalWhisperError {
                // Free cloud fallback (the audit's #1 safety net). The on-device
                // model couldn't run on THIS Mac, a slow/old/8 GB cold compile
                // that never landed, a corrupt bundle a re-download couldn't fix,
                // or an init failure. Rather than dead-end the user's first
                // transcript with a red "failed" card + upsell, fall back to Groq
                // cloud so they still get a transcript. Requires a JWT (signed
                // in): the Worker meters a small free monthly cloud budget. A
                // signed-out guest has no JWT, so we nudge them to sign in. Don't
                // pass a localFallbackVariant, local just failed, so a per-chunk
                // "recover locally" would loop straight back into the failure.
                guard err.isModelUnavailable else {
                    TranscriptionErrors.record(meetingId: meetingId, message: err.localizedDescription)
                    throw err
                }
                guard AppSettings.isSignedIn else {
                    TranscriptionErrors.record(meetingId: meetingId,
                        message: "Your Mac couldn't run the on-device model. Sign in to transcribe in the cloud.")
                    throw err
                }
                FileLogger.log("LocalWhisper: model unavailable on this Mac (\(err)), falling back to Groq cloud for this track")
                do {
                    let prompt = AppVocabulary.current.nilIfEmpty
                    let turns = try await WhisperTranscriber.transcribe(
                        audioURL: wavURL, mode: .single, initialPrompt: prompt,
                        backend: .groq, onProgress: onProgress)
                    TranscriptionErrors.record(meetingId: meetingId,
                        message: "Your Mac couldn't run the on-device model, so this was transcribed in the cloud.")
                    return turns
                } catch let cloudErr as WhisperTranscriber.WhisperError {
                    // Cloud also unavailable (over the free cloud budget, or the
                    // Worker refused). Surface the ORIGINAL local error, it's the
                    // actionable one (the model couldn't run on this Mac).
                    FileLogger.log("LocalWhisper: cloud fallback also failed (\(cloudErr)), failing with local error")
                    TranscriptionErrors.record(meetingId: meetingId, message: err.localizedDescription)
                    throw err
                }
            }
        }
    }

    /// The free, deterministic half: lay Gemini's raw text onto a real
    /// timeline using the on-device speaker diarizer over the FULL
    /// uncompressed wav. Re-runnable offline on every transcribe, that's
    /// what lets the timing logic be fixed/iterated without ever
    /// re-spending a Gemini call, and what recovers any cached meeting
    /// for free.
    ///
    /// Step 2: known-good PROPORTIONAL placement (`relabel`), the
    /// validated v8 behaviour the karaoke highlight tracks correctly.
    /// The on-device forced-aligner (`alignByTokens`) is being reworked
    /// (Step 3) and is intentionally not wired here yet.
    ///
    /// Returns `[]` when on-device diarization is unavailable and a
    /// Gemini fallback isn't allowed (cache-hit re-derive must stay
    /// offline), the caller then keeps the last-derived cached finals
    /// so timing never regresses. On a true miss (`allowGeminiFallback`)
    /// it falls back to a Gemini `.diarize` pass exactly like before.

    /// Correct raw ASR turns whose Whisper timestamps landed where this
    /// track is NOT the one speaking, using cross-track energy dominance.
    ///
    /// Why: the keep-raw branches below trust Whisper's own timestamps, but
    /// on a sparse track (a mic that mostly listened) the cloud ASR ran over
    /// a VAD-COMPRESSED file, and its per-segment stamps drift across the
    /// concatenation joints; the piecewise projection then lands a phrase in
    /// a stretch where only the OTHER side spoke, so the merged transcript
    /// interleaves the two sides wrongly (measured: 28 of 64 "you" turns).
    /// Plain VAD spans cannot verify placement — speaker bleed + the mic's
    /// own noise floor make ~43% of the timeline "voiced" (tried in 0.15.55,
    /// moved 0 turns); the discriminative signal is cross-track DOMINANCE
    /// (see `VoiceActivityDetector.dominanceMap`), the same test the
    /// diagnosis used. Three conservative, order-preserving passes, tuned
    /// on the real recording (bad placements 28 -> ~1):
    ///   1. CONFIRM: a turn >= 35% covered by dominant steps stays.
    ///   2. TRIM: a confirmed turn whose leading/trailing edge overhangs
    ///      the dominant region by > 600 ms is clipped to it — Whisper
    ///      routinely stretched a turn's start over the OTHER side's
    ///      preceding phrase, which flipped the merge order at
    ///      conversation starts.
    ///   3. RELOCATE: an unconfirmed turn moves to the nearest dominant
    ///      span inside its monotonic window (never before the previous
    ///      placed turn, never past the next confirmed turn's start).
    /// Text is never altered, order is never changed. Single-file
    /// recordings are left alone — no sibling to test dominance against.
    private static func snapTurnsToDominantSpans(_ turns: [GeminiTranscriber.Turn],
                                                 wavURL: URL,
                                                 label: String) -> [GeminiTranscriber.Turn] {
        let counterpartName: String
        switch wavURL.lastPathComponent {
        case "mic.wav": counterpartName = "system.wav"
        case "system.wav": counterpartName = "mic.wav"
        default: return turns
        }
        let counterpartURL = wavURL.deletingLastPathComponent()
            .appendingPathComponent(counterpartName)
        guard turns.count > 1,
              FileManager.default.fileExists(atPath: counterpartURL.path),
              let map = VoiceActivityDetector.dominanceMap(primaryURL: wavURL,
                                                           referenceURL: counterpartURL),
              !map.spans.isEmpty else { return turns }

        let winMs = VoiceActivityDetector.dominanceWindowMs
        var out = turns
        var confirmed = [Bool](repeating: false, count: out.count)
        var trimmedCount = 0

        // Pass 1+2: confirm by dominant coverage, then clip long silent
        // overhangs off a confirmed turn's edges.
        for i in out.indices {
            let t = out[i]
            guard map.fraction(startMs: t.startMs, endMs: t.endMs) >= 0.35 else { continue }
            confirmed[i] = true
            guard let edges = map.dominantEdges(startMs: t.startMs, endMs: t.endMs,
                                                windowMs: winMs) else { continue }
            var ns = t.startMs
            var ne = t.endMs
            if edges.first - t.startMs > 600 { ns = edges.first }
            if t.endMs - edges.last > 600 { ne = edges.last }
            if (ns != t.startMs || ne != t.endMs), ne - ns >= 500 {
                out[i] = GeminiTranscriber.Turn(speakerLabel: t.speakerLabel,
                                                startMs: ns, endMs: ne, text: t.text)
                trimmedCount += 1
            }
        }

        // Pass 3: relocate unconfirmed turns, monotonic.
        var moved = 0
        var cursor: Int64 = 0
        for i in out.indices {
            let t = out[i]
            if confirmed[i] {
                cursor = max(cursor, t.endMs)
                continue
            }
            var windowEnd = Int64.max
            for j in (i + 1)..<out.count where confirmed[j] {
                windowEnd = out[j].startMs + 400
                break
            }
            let dur = max(900, t.endMs - t.startMs)
            let cands = map.spans.filter { $0.endMs > cursor && $0.startMs < windowEnd }
            guard !cands.isEmpty else {
                cursor = max(cursor, t.endMs)
                continue // no room in the window: leave as-is (no worse)
            }
            let best = cands.min {
                abs(max($0.startMs, cursor) - t.startMs) < abs(max($1.startMs, cursor) - t.startMs)
            }!
            let ns = max(best.startMs, cursor)
            guard ns < windowEnd else {
                cursor = max(cursor, t.endMs)
                continue
            }
            let ne = min(max(best.endMs, ns + 900), ns + dur)
            out[i] = GeminiTranscriber.Turn(speakerLabel: t.speakerLabel,
                                            startMs: ns,
                                            endMs: max(ne, ns + 900),
                                            text: t.text)
            moved += 1
            cursor = out[i].endMs
        }
        FileLogger.log("applyTiming: \(label), dominance snap: \(moved) relocated + \(trimmedCount) trimmed of \(turns.count) turns (\(map.spans.count) spans)")
        return out
    }

    private func applyTiming(rawTurns: [GeminiTranscriber.Turn],
                             wavURL: URL,
                             numSpeakers: Int?,
                             singlePass: Bool,
                             allowGeminiFallback: Bool,
                             keepRawIfNoDiar: Bool = false,
                             meetingId: String) async throws -> [GeminiTranscriber.Turn] {
        guard !rawTurns.isEmpty else { return [] }

        // SINGLE-speaker track (the mic "you" track, numSpeakers == 1): there is
        // nothing to re-diarize, every turn is the one speaker, and the
        // re-derivation below DISCARDS Whisper's own timestamps (which the code
        // itself calls reliable) and re-lays turns proportionally onto diarized
        // speech spans. On a mic that mostly listened (sparse speech + a few
        // real replies) that proportional placement drops a real phrase onto a
        // SILENT span, where the dominance gate then deletes it as "silence"
        // the "думаете, белый будет уместен?" / "Неплохо" mis-placement. Whisper
        // timed those correctly; keep its timing. capUserTurnDurations + the
        // dominance gate downstream still clamp durations and strip real
        // hallucinations (which keep their own silent timestamp and get gated).
        if numSpeakers == 1 {
            FileLogger.log("applyTiming: \(wavURL.lastPathComponent), single speaker, keeping \(rawTurns.count) raw ASR turns with Whisper's own timing (no re-derivation)")
            return Self.snapTurnsToDominantSpans(rawTurns, wavURL: wavURL,
                                               label: "\(wavURL.lastPathComponent) single-speaker")
        }

        var diarSegs: [DiarizedSegment] = []
        do {
            diarSegs = try await SpeakerDiarizer.shared.diarize(
                wavURL: wavURL, numSpeakers: numSpeakers)
        } catch {
            FileLogger.log("applyTiming: on-device diarization unavailable (\(error))")
        }

        if diarSegs.isEmpty {
            if allowGeminiFallback {
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
            // No Gemini fallback (Free, or offline). On a FRESH run keep the
            // raw ASR turns as-is, local Whisper's own timestamps are
            // reliable, so the transcript is still good (just not re-diarized
            // into multiple remote speakers). Far better than dropping the
            // track or 403-failing the whole meeting. A cache-hit re-derive
            // returns [] so the caller keeps its previously-derived finals.
            if keepRawIfNoDiar {
                FileLogger.log("applyTiming: \(wavURL.lastPathComponent), no on-device diarization, keeping \(rawTurns.count) raw ASR turns with their own timing")
                return rawTurns
            }
            FileLogger.log("applyTiming: \(wavURL.lastPathComponent), no on-device diarization, offline re-derive → caller keeps cached finals")
            return []
        }

        // SINGLE-speaker track under a WHISPER provider (Groq / local / whisper-1):
        // keep the raw ASR turns with their own timing, exactly like the mic
        // `numSpeakers == 1` shortcut above. When FluidAudio finds only one
        // speaker on this track there is nothing to SPLIT, so the re-lay below
        // buys no WHO and only risks WHEN: on a degraded far-end (a Bluetooth
        // call, measured) the diarizer under-covers the speech, the proportional
        // / token re-lay squeezes real turns onto the covered spans, and turns
        // that land on a now-silent stretch are deleted by the downstream
        // dominance gate. A whole side of a call went missing this way (15 loud,
        // real far-end turns dropped, verified their system-track RMS was 0.05
        // to 0.13 the entire time). Whisper's per-segment timestamps are
        // reliable (the code already trusts them for the mic track), so keeping
        // them here is strictly safer than re-laying. Gemini is EXCLUDED: its
        // per-chunk timestamps are the unreliable thing diarize-first exists to
        // fix, so a single-speaker Gemini track still re-lays. Multi-speaker
        // tracks always re-lay (that is the only way to split WHO).
        let diarSpeakers = Set(diarSegs.map(\.speakerId)).count
        if diarSpeakers <= 1, currentProvider != .gemini {
            FileLogger.log("applyTiming: \(wavURL.lastPathComponent), single diarized speaker + Whisper-reliable timing, keeping \(rawTurns.count) raw ASR turns (no re-lay)")
            return Self.snapTurnsToDominantSpans(rawTurns, wavURL: wavURL,
                                               label: "\(wavURL.lastPathComponent) single-diar")
        }

        // Forced-alignment when on-device ASR is available; fall back to
        // the proven proportional placement when it isn't. Both are pure
        // and deterministic, so this re-runs free on every load.
        let tokens = (try? await ForcedAligner.shared.align(wavURL: wavURL)) ?? []
        let result: [GeminiTranscriber.Turn]
        if tokens.isEmpty {
            result = Self.relabel(asr: rawTurns, using: diarSegs)
            FileLogger.log("applyTiming: \(wavURL.lastPathComponent), \(rawTurns.count) turns, PROPORTIONAL placement across \(Set(diarSegs.map(\.speakerId)).count) speakers")
        } else {
            result = Self.alignByTokens(asr: rawTurns, tokens: tokens, diar: diarSegs)
            FileLogger.log("applyTiming: \(wavURL.lastPathComponent), \(rawTurns.count) turns, FORCED-ALIGNED on \(tokens.count) tokens across \(Set(diarSegs.map(\.speakerId)).count) speakers")
        }
        return result
    }

    /// Diarize-first time assignment. Gemini's per-chunk timestamps over
    /// the VAD-compressed track are unreliable on dense speech, turns
    /// overlap, balloon to 40 s+, sum PAST the recording length, and the
    /// karaoke highlight drifts right off the audio. FluidAudio diarizes
    /// the FULL, uncompressed file, so ITS timeline is the ground truth
    /// for WHEN. We therefore discard Gemini's timestamps entirely and
    /// lay the ASR text turns end-to-end onto the concatenation of
    /// diarized speech spans, proportional to each turn's text length (a
    /// steady proxy for spoken duration, Gemini's own duration is the
    /// exact thing we don't trust). Every turn then lands on a real,
    /// monotonic, non-overlapping interval inside actual diarized speech,
    /// labelled by the FluidAudio speaker at that time. Net: the
    /// highlight tracks the audio, the timeline can't exceed 100 %, and
    /// the tail can't collapse. The dual-track routing (mic=you /
    /// system=others, merge by start-ms) is unchanged, only the
    /// start-ms SOURCE moves from "Gemini-projected (broken)" to
    /// "FluidAudio".
    static func relabel(asr: [GeminiTranscriber.Turn],
                        using diar: [DiarizedSegment]) -> [GeminiTranscriber.Turn] {
        guard !diar.isEmpty, !asr.isEmpty else { return asr }
        let segs = diar.sorted { $0.startMs < $1.startMs }
        let totalDiar = segs.reduce(Int64(0)) { $0 + max(0, $1.endMs - $1.startMs) }
        guard totalDiar > 0 else { return asr }

        // Offset within the concatenated diarized speech (gaps = silence,
        // no turn is ever placed there) → real ms + the FluidAudio
        // speaker whose span covers it.
        func locate(_ offset: Int64) -> (ms: Int64, speaker: String) {
            var acc: Int64 = 0
            for s in segs {
                let dur = max(0, s.endMs - s.startMs)
                if offset < acc + dur {
                    return (s.startMs + min(max(0, offset - acc), dur), s.speakerId)
                }
                acc += dur
            }
            let last = segs[segs.count - 1]
            return (last.endMs, last.speakerId)
        }

        let weights = asr.map { max(Int64(1), Int64($0.text.count)) }
        let totalWeight = weights.reduce(Int64(0), +)
        guard totalWeight > 0 else { return asr }

        var out: [GeminiTranscriber.Turn] = []
        out.reserveCapacity(asr.count)
        var cum: Int64 = 0
        for (i, turn) in asr.enumerated() {
            let oStart = Int64(Double(cum) / Double(totalWeight) * Double(totalDiar))
            cum += weights[i]
            let oEnd = Int64(Double(cum) / Double(totalWeight) * Double(totalDiar))
            let (sMs, spk) = locate(oStart)
            let (eMsRaw, _) = locate(max(oStart, oEnd))
            out.append(GeminiTranscriber.Turn(speakerLabel: spk,
                                              startMs: sMs,
                                              endMs: max(sMs, eMsRaw),
                                              text: turn.text))
        }
        return out
    }

    /// Forced-alignment time assignment. `tokens` are on-device ASR
    /// (Parakeet TDT v3) tokens with REAL acoustic times on the FULL
    /// uncompressed file timeline. Gemini's text and Parakeet's tokens
    /// are DIFFERENT transcripts of the same audio (Gemini ran on the
    /// VAD-compressed track, may drop/merge chunks, different wording,
    /// RU/EN code-switch), so the old single global char-proportional
    /// `scale` drifted progressively and the `lastEnd` clamp compounded
    /// it. Instead we find sparse, high-confidence ANCHOR words that are
    /// unique in BOTH streams, force their order monotone (LIS), and
    /// proportionally place turns BETWEEN adjacent anchors, resetting
    /// the proportion constant at every anchor so error can never
    /// accumulate past one span. Regions with no anchors degrade
    /// seamlessly to bounded proportional placement (== `relabel`
    /// locally), so this is never worse than the proportional floor.
    /// Pure value-in/value-out: re-derivable offline for free.
    static func alignByTokens(asr: [GeminiTranscriber.Turn],
                              tokens: [TimedToken],
                              diar: [DiarizedSegment]) -> [GeminiTranscriber.Turn] {
        guard !asr.isEmpty else { return [] }
        // No acoustic timeline → the proportional placement is the
        // validated floor; never do worse than it.
        guard !tokens.isEmpty else { return relabel(asr: asr, using: diar) }

        func norm(_ s: String) -> String {
            String(String.UnicodeScalarView(
                s.lowercased().unicodeScalars.filter {
                    CharacterSet.alphanumerics.contains($0)
                }))
        }

        // ── Gemini word stream in normalised-char space. Each turn owns
        //    [turnStartChar, turnEndChar); a word carries its global
        //    char offset so an anchor word pins an exact char position.
        struct GWord { let norm: String; let charPos: Int }
        var gWords: [GWord] = []
        var turnStartChar: [Int] = []
        var turnEndChar: [Int] = []
        var gCursor = 0
        for turn in asr {
            turnStartChar.append(gCursor)
            for raw in turn.text.split(whereSeparator: { $0.isWhitespace }) {
                let n = norm(String(raw))
                if !n.isEmpty { gWords.append(GWord(norm: n, charPos: gCursor)) }
                // Whitespace contributes 0; only normalised chars advance
                // the timeline so the proportion matches `relabel`.
                gCursor += n.count
            }
            turnEndChar.append(gCursor)
        }
        let totalChars = gCursor
        guard totalChars > 0 else { return relabel(asr: asr, using: diar) }

        // ── Parakeet token stream: normalised text → its real start ms.
        struct PWord { let norm: String; let startMs: Int64 }
        let pWords: [PWord] = tokens.map {
            PWord(norm: norm($0.text), startMs: $0.startMs)
        }

        // ── Anchor candidates: terms (≥4 normalised chars) that occur
        //    EXACTLY once in each stream. Uniqueness is the rejection
        //    rule, ambiguous repeats are exactly what mis-jumped before.
        var gCount: [String: Int] = [:]
        var pCount: [String: Int] = [:]
        for w in gWords where w.norm.count >= 4 { gCount[w.norm, default: 0] += 1 }
        for w in pWords where w.norm.count >= 4 { pCount[w.norm, default: 0] += 1 }
        var gPos: [String: Int] = [:]
        var pMs: [String: Int64] = [:]
        for w in gWords where gCount[w.norm] == 1 { gPos[w.norm] = w.charPos }
        for w in pWords where pCount[w.norm] == 1 { pMs[w.norm] = w.startMs }

        var cands: [(charPos: Int, ms: Int64)] = []
        for (term, c) in gPos {
            if let m = pMs[term], pCount[term] == 1 { cands.append((c, m)) }
        }
        cands.sort { $0.charPos < $1.charPos }

        // ── Strict-increasing-ms LIS over char-sorted candidates: drops
        //    any unique-but-misplaced match that contradicts its
        //    neighbours, so survivors are guaranteed monotone in BOTH
        //    axes (no drift, no backward jump).
        let kept: [(charPos: Int, ms: Int64)] = {
            guard !cands.isEmpty else { return [] }
            var tails: [Int] = []          // indices into cands; ms increasing
            var prev = [Int](repeating: -1, count: cands.count)
            for i in 0..<cands.count {
                var lo = 0, hi = tails.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if cands[tails[mid]].ms < cands[i].ms { lo = mid + 1 }
                    else { hi = mid }
                }
                if lo > 0 { prev[i] = tails[lo - 1] }
                if lo == tails.count { tails.append(i) } else { tails[lo] = i }
            }
            var seq: [(charPos: Int, ms: Int64)] = []
            var k = tails.isEmpty ? -1 : tails[tails.count - 1]
            while k >= 0 { seq.append(cands[k]); k = prev[k] }
            return seq.reversed()
        }()

        // ── Bound every interpolation by real acoustic endpoints so no
        //    region ever extrapolates unbounded.
        let tailMs = tokens[tokens.count - 1].endMs
        var anchors: [(charPos: Int, ms: Int64)] = [(0, tokens[0].startMs)]
        anchors.append(contentsOf: kept)
        anchors.append((totalChars, tailMs))

        // Position (in normalised chars) → ms, by locating the bounding
        // anchor pair and interpolating proportionally WITHIN it. This is
        // `relabel`'s proportional math with the constant reset per span.
        func msAtChar(_ pos: Int) -> Int64 {
            let p = min(max(pos, 0), totalChars)
            var aIdx = anchors.count - 2
            for i in 0..<(anchors.count - 1) where p < anchors[i + 1].charPos {
                aIdx = i; break
            }
            let a = anchors[aIdx], b = anchors[aIdx + 1]
            let cSpan = b.charPos - a.charPos
            let tSpan = b.ms - a.ms
            guard cSpan > 0, tSpan > 0 else { return a.ms }
            let frac = Double(p - a.charPos) / Double(cSpan)
            return a.ms + Int64(frac * Double(tSpan))
        }

        func speaker(at ms: Int64) -> String {
            for d in diar where ms >= d.startMs && ms < d.endMs { return d.speakerId }
            return diar.min(by: { abs($0.startMs - ms) < abs($1.startMs - ms) })?
                .speakerId ?? (diar.first?.speakerId ?? "Speaker 1")
        }

        var out: [GeminiTranscriber.Turn] = []
        out.reserveCapacity(asr.count)
        var lastEnd: Int64 = tokens[0].startMs
        for (i, turn) in asr.enumerated() {
            let rs = msAtChar(turnStartChar[i])
            let re = msAtChar(turnEndChar[i])
            // Clamp to `lastEnd`/`tailMs`: monotone, non-overlapping,
            // in-bounds. Carry `end` (not `start`), the historical bug
            // carried `start`, which let the next turn overlap this
            // turn's body.
            let start = min(max(lastEnd, min(rs, re)), tailMs)
            let end = min(max(start, max(rs, re)), tailMs)
            lastEnd = end
            out.append(GeminiTranscriber.Turn(
                speakerLabel: diar.isEmpty ? turn.speakerLabel : speaker(at: start),
                startMs: start, endMs: end, text: turn.text))
        }
        return out
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
    /// ones, so a single struct handles every format at decode time.
    ///
    /// `rawUserTurns`/`rawOtherTurns` are Gemini's text BEFORE timing.
    /// WHEN/WHO is re-derived on-device from them every run, so iterating
    /// the timing logic never re-spends a Gemini call. Older v9 records
    /// lack them; their `userTurns`/`otherTurns` text+order still IS the
    /// raw Gemini output (relabel never touched `.text`), so the reader
    /// migrates transparently. `userTurns`/`otherTurns` are now the
    /// last-derived finals, kept only as a no-audio fallback.
    private struct CachedTranscript: Codable {
        // Legacy, single-stream output.
        let userLabel: String?
        let turns: [GeminiTranscriber.Turn]?
        // Dual-track, last-derived FINAL (timed) turns.
        let userTurns: [GeminiTranscriber.Turn]?
        let otherTurns: [GeminiTranscriber.Turn]?
        // Dual-track, RAW Gemini text turns (pre-timing). Source of
        // truth for re-derivation; absent on pre-migration records.
        var rawUserTurns: [GeminiTranscriber.Turn]? = nil
        var rawOtherTurns: [GeminiTranscriber.Turn]? = nil

        var isDualTrack: Bool {
            userTurns != nil || otherTurns != nil
                || rawUserTurns != nil || rawOtherTurns != nil
        }
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
    /// DB still contain them, `purgeKnownHallucinations` clears those at
    /// launch, and this filter blocks any that slip through new pipelines.
    /// One-time scrub at app launch, sweeps known hallucinated lines out
    /// of the existing transcripts so users don't have to re-run anything.
    static func purgeKnownHallucinations(repo: MeetingRepository) {
        do {
            let segs = try repo.allSegments()
            // EXACT-only here (not isHallucination's 60% substring rule):
            // this is a permanent DELETE of already-stored transcript lines,
            // so only nuke a segment that is ENTIRELY a known artefact. A
            // real sentence that merely contains a pattern must survive.
            let badIds = segs.compactMap { s -> Int64? in
                guard let id = s.id else { return nil }
                return Hallucinations.isExactHallucination(s.text) ? id : nil
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
        guard AppSettings.autoTitle else { return }
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
                    RecordingDirNaming.renameToTitled(repo: repo, meetingId: id)
                    FileLogger.log("startup: titled \(id) → \"\(title)\"")
                }
                // Be polite to the API between meetings.
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            FileLogger.log("startup: title backfill done")
        }
    }

}
