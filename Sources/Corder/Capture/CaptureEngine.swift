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
    nonisolated(unsafe) private var tearingDown = false
    private(set) var startedAt: Date?
    private(set) var meetingId: String?

    /// Mach host-clock tick latched at the instant `start()` begins, the
    /// common t=0 that every audio writer left-pads up to. The mic tap
    /// (`AVAudioTime.hostTime`), the process tap (`AudioTimeStamp.mHostTime`)
    /// and the SCStream audio (`CMSampleBuffer` PTS) all report this SAME
    /// mach host clock, so their first-buffer timestamps are directly
    /// comparable. Without this, a writer that comes up LATE (the process
    /// tap can take 17 s while the BT watchdog rebuilds it) produces a file
    /// whose frame 0 is a LATER real instant than the others' — and every
    /// consumer that overlays the tracks from frame 0 (`AudioMixer`, the
    /// per-track timing) then shifts the far end earlier, onto the user's
    /// voice. Latching one clock and padding each writer to it keeps frame 0
    /// meaning the same instant in every file. Video already gets this for
    /// free via `startSession(atSourceTime: firstPTS)`.
    nonisolated(unsafe) private var captureStartHostTime: UInt64 = 0
    /// mach ticks → seconds, computed once from `mach_timebase_info`.
    private let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }()
    /// First-buffer pad guards (each writer pads exactly once).
    private var paddedMic = false
    nonisolated(unsafe) private var paddedSystem = false
    nonisolated(unsafe) private var paddedSCK = false
    private(set) var videoURL: URL?
    private(set) var micURL: URL?
    nonisolated(unsafe) private(set) var systemURL: URL?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.3mpq.corder.scstream", qos: .userInitiated)
    /// Dedicated serial queue for ALL media file I/O — video `append` and
    /// the synchronous `AVAudioFile.write` for system/SCK audio. Previously
    /// every video frame and system-audio buffer hopped to the MainActor and
    /// did its disk write there, so 31-86 audio buffers/sec (+ video) of
    /// synchronous I/O serialised on the main run loop WHILE it drove the
    /// animated HUD — the "everything lags from the start" load that
    /// Maksym-nocorny root-caused (issue #1, item 1). Writing here keeps the
    /// MainActor free; `stop()` drains this queue (`writeQueue.sync`) before
    /// closing files, and the sources are all stopped first, so no write
    /// races teardown. The multi-second leading-silence pad also lands here
    /// now instead of stalling the main thread at record start.
    private let writeQueue = DispatchQueue(label: "com.3mpq.corder.mediawrite", qos: .userInitiated)

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
    nonisolated(unsafe) private var videoWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var videoSessionStarted = false
    nonisolated(unsafe) private var videoFramesAppended: Int64 = 0

    // System audio now comes from a Core Audio process tap (see
    // SystemAudioTap) instead of SCStream's `.audio` output. SCStream
    // delivered silence on real calls because communication apps render
    // through Voice-Processing I/O, which bypasses the system mix it
    // taps. The tap's buffers are mirrored into a standalone .wav so
    // transcription doesn't depend on AVAssetWriter finalising the .mov.
    nonisolated(unsafe) private let systemTap = SystemAudioTap()
    nonisolated(unsafe) private var systemAudioFile: AVAudioFile?
    nonisolated(unsafe) private var systemAudioFormat: AVAudioFormat?
    // Diagnostic counter for the system-audio tap. If this stays at 0
    // across a recording, the process tap delivered no frames (TCC
    // denied, or genuinely nothing playing).
    nonisolated(unsafe) private var systemFramesWritten: Int64 = 0
    nonisolated(unsafe) private var loggedFirstSystemBuffer = false
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
    nonisolated(unsafe) private var sckSystemURL: URL?
    nonisolated(unsafe) private var sckAudioFile: AVAudioFile?
    nonisolated(unsafe) private var sckFramesWritten: Int64 = 0
    nonisolated(unsafe) private var loggedFirstSCKBuffer = false

    func start(meetingId: String, source: CaptureSource) async throws {
        FileLogger.log("CaptureEngine.start: meetingId=\(meetingId) source=\(source)")
        // Reject re-entry synchronously, BEFORE any await, so two near-
        // simultaneous starts (manual + auto-detect) can't
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

        // Latch t=0 for ALL audio writers HERE — after the (possibly slow,
        // first-run) mic-permission prompt has resolved but before any writer
        // is armed. Every writer's first-buffer host time is then >= this, so
        // each left-pads to one shared origin. Latched ONCE per recording and
        // never reset on a tap rebuild, so the watchdog's up-to-17 s of
        // rebuilds still pad system.wav against the true start.
        captureStartHostTime = mach_absolute_time()
        paddedMic = false
        paddedSystem = false
        paddedSCK = false

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

        // Whether to run the SCStream session AT ALL. MEASURED: a running
        // SCStream (full-display capture + audio) costs ~600 mW — and in
        // audio-only mode capturing the screen was the single biggest source
        // of the "recording heats the Mac" load (audio-only drew ~the same
        // power as video). We need SCStream only for: (a) video frames, or
        // (b) the SCK system-audio backup on a BLUETOOTH output route (where
        // the Core Audio process tap can capture silence). On a non-BT
        // audio-only recording the process tap captures system audio
        // reliably, so we skip SCStream entirely and save the power.
        //
        // This same flag also gates SCREEN-RECORDING PERMISSION. SCShareableContent
        // and SCStream both require the Screen Recording TCC grant, but the Core
        // Audio process tap + the AVAudioEngine mic do NOT. So an audio-only,
        // non-Bluetooth recording runs with NO Screen Recording permission at all
        // — a brand-new user can record audio the instant they open Corder, and
        // we only ever prompt for Screen Recording when video is actually on
        // (RecordingController enforces the grant up-front in that case). If the
        // SCShareableContent call here still throws (permission revoked, or a
        // race), we DON'T fail the recording — we degrade to audio-only, where
        // the process tap still captures the far end.
        let needSCStream = AppSettings.captureVideo || outputBluetoothAtStart
        if needSCStream {
            do {
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
                // Output size: the display's point resolution, capped at 1080p height
                // so a 4K/5K panel doesn't make the encoder chew huge frames. Aspect-
                // matched + even dimensions (H.264 requirement). Tracer-style "fixed
                // 1080p cap", NOT backing-resolution-scaled.
                let srcAspect = captureHeight > 0
                    ? CGFloat(captureWidth) / CGFloat(captureHeight) : 16.0 / 9.0
                let outH = min(1080, captureHeight)
                let outW = Int((CGFloat(outH) * srcAspect).rounded())
                config.width = outW - (outW % 2)
                config.height = outH - (outH % 2)
                // BGRA = the display framebuffer's NATIVE format. Requesting YUV here
                // forced ScreenCaptureKit/WindowServer to run an RGB→YUV color
                // conversion on EVERY captured frame — measured as the dominant cost
                // (WindowServer pegged ~88% during recording, the encoder itself was
                // cheap). Delivering BGRA straight through skips that conversion; the
                // hardware H.264 encoder takes BGRA and does its own conversion in
                // silicon for ~free. This is the single biggest lever on the
                // "recording heats the Mac" complaint (and matches Tracer/Loom).
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.queueDepth = 5
                // 10 fps is plenty for meeting recordings — cursor and window
                // motion read fine at that rate, and it's a third fewer frames for
                // the encoder than 15 fps (less CPU, smaller file) with no
                // perceptible loss on mostly-static screen content.
                config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                config.capturesAudio = true
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
                            // H.264 (not HEVC): the Apple-Silicon H.264 hardware encoder
                            // is more power-efficient than HEVC, and it takes BGRA input
                            // natively. Matches what Tracer/Loom use.
                            AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: config.width,
                            AVVideoHeightKey: config.height,
                            AVVideoCompressionPropertiesKey: [
                                // ~2.5 Mbps for 1080p10 H.264 screen content (mostly
                                // static, dips well below most of the time).
                                AVVideoAverageBitRateKey: 2_500_000,
                                AVVideoExpectedSourceFrameRateKey: 10,
                                // I-frame every 4s at 10fps → fast scrubbing in the Library.
                                AVVideoMaxKeyFrameIntervalKey: 40,
                                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                            ]
                        ]
                        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                        input.expectsMediaDataInRealTime = true
                        if writer.canAdd(input) {
                            writer.add(input)
                        }
                        // Fragmented MOV: flush a movie fragment every ~5s so a crash or
                        // power loss mid-recording leaves a PLAYABLE partial file. Without
                        // this the moov atom is written only by finishWriting(), so an
                        // interrupted recording yields an unplayable video.mov even though
                        // the frames are on disk. (Technique from NoCorny Tracer's
                        // recording-pipeline hardening; must be set before startWriting.)
                        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
                        if writer.startWriting() {
                            self.videoWriter = writer
                            self.videoInput = input
                            self.videoSessionStarted = false
                            self.videoFramesAppended = 0
                            FileLogger.log("CaptureEngine.start: AVAssetWriter armed (H.264, \(config.width)x\(config.height), 10fps, 2.5 Mbps, BGRA)")
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
                // Subscribe to SCREEN frames only when actually recording video —
                // in BT audio-only we keep the stream for SCK audio but never
                // touch the screen.
                if AppSettings.captureVideo {
                    try activeStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
                }
                // SCK (system_sck.wav) is ONLY a Bluetooth-output fallback for the
                // process tap, and is empirically pure silence on every non-BT
                // recording — yet each buffer still allocated an AVAudioPCMBuffer,
                // ran CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer and
                // wrote to disk. So register the `.audio` output ONLY on a BT
                // route. On a video+non-BT recording we now keep just the `.screen`
                // output and drop the third tap entirely (issue #1, item 2).
                if outputBluetoothAtStart {
                    do {
                        try activeStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
                        self.sckSystemURL = sckSystemURL
                        self.sckAudioFile = nil
                        self.sckFramesWritten = 0
                        self.loggedFirstSCKBuffer = false
                        FileLogger.log("CaptureEngine.start: SCStream configured (video=\(AppSettings.captureVideo), BT=\(outputBluetoothAtStart) → system_sck.wav)")
                    } catch {
                        // Non-fatal: the process tap is still the primary path. We
                        // just lose the Bluetooth-output safety net for this run.
                        self.sckSystemURL = nil
                        FileLogger.log("CaptureEngine.start: SCStream .audio output registration failed: \(error). Continuing with process tap only.")
                    }
                } else {
                    self.sckSystemURL = nil
                    FileLogger.log("CaptureEngine.start: SCStream configured (video=\(AppSettings.captureVideo), non-BT → no SCK tap, process tap only)")
                }
                do {
                    try await activeStream.startCapture()
                    FileLogger.log("CaptureEngine.start: SCStream.startCapture OK")
                } catch {
                    FileLogger.log("CaptureEngine.start: SCStream.startCapture FAILED: \(error). Continuing — audio tap + mic still record; no video.")
                }
                self.stream = activeStream
            } catch {
                // SCShareableContent / filter / .screen output threw — almost
                // always "Screen Recording not granted yet". DON'T fail the whole
                // recording: degrade to audio-only (process tap + mic). We lose
                // video + the (empirically-silent) SCK backup, but the far end
                // still comes from the process tap. RecordingController gates
                // video-on behind an explicit Screen Recording grant, so this
                // path is the safety net for a revoked grant / race.
                FileLogger.log("CaptureEngine.start: SCStream unavailable (\(error)) — Screen Recording likely not granted; recording audio-only via process tap")
                self.stream = nil
                self.sckSystemURL = nil
                self.videoWriter = nil
                self.videoInput = nil
            }
        } else {
            // Audio-only on a non-Bluetooth route: no SCStream at all. The
            // process tap (system.wav) is the system-audio source here, and it
            // needs NO Screen Recording permission.
            self.stream = nil
            self.sckSystemURL = nil
            FileLogger.log("CaptureEngine.start: audio-only + non-BT — skipping SCStream entirely (process tap handles system audio), ~600 mW saved")
        }

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
        // NOTE: macOS Voice Processing (AEC) was tried here to cancel
        // speaker→mic echo, but it puts the whole audio session into VoIP
        // mode — on Bluetooth it forces the low-quality HFP/SCO route (the
        // far end hears your voice degrade) and handed back a bogus 5-channel
        // mic format that produced an unusable recording. Reverted. The
        // no-headphones echo is handled in the playback mix instead (duck
        // the mic while the far end is talking), which never touches the
        // capture path or the audio route.
        // Mic init can throw -10868 (AUGraph input-chain init) when the input
        // device isn't bound yet: it was JUST changed (user un/replugs
        // headphones at record time) or coreaudiod is mid-restart, so
        // `inputNode.outputFormat` momentarily reports a 0 Hz / invalid
        // format. A single attempt hard-failed the whole recording with a
        // scary popup. Retry a few times with a short settle delay + an
        // engine reset — the device almost always binds within a second.
        var micStarted = false
        var lastMicError: Error?
        for attempt in 1...4 {
            let fmt = inputNode.outputFormat(forBus: 0)
            // 0 Hz / 0 ch = device not bound yet. Don't even try to open a
            // file with a bogus format (that's what throws -10868) — wait.
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
                lastMicError = NSError(domain: "Corder.mic", code: -10868,
                    userInfo: [NSLocalizedDescriptionKey: "input device not ready (format \(fmt.sampleRate) Hz)"])
                FileLogger.log("CaptureEngine.start: mic input not ready on attempt \(attempt) (format \(fmt.sampleRate) Hz) — settling + retry")
                try? await Task.sleep(nanoseconds: 450_000_000)
                continue
            }
            do {
                let micFile = try AVAudioFile(
                    forWriting: micURL,
                    settings: fmt.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                self.micFile = micFile
                inputNode.removeTap(onBus: 0)   // clear any tap a failed attempt left
                // bufferSize 1024 (not 4096): the input runs at 16 kHz, so
                // 4096 frames = 256 ms = only ~4 level-meter updates/sec — the
                // floating-HUD equalizer looked stepped no matter how the bars
                // were smoothed. 1024 = 64 ms ≈ 15.6 Hz, ~4x the spectrum frame
                // rate, which the HUD's per-frame lerp turns into continuous
                // motion. mic.wav is unaffected (same bytes, just written in
                // smaller chunks); the cost is a few more cheap tap callbacks.
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
                    guard let self = self else { return }
                    // First buffer: left-pad mic.wav to the capture-start clock
                    // so all audio tracks share frame 0. Mic normally arms ~at
                    // start so this is small, but we MEASURE it (it's the
                    // reference the other tracks align to) rather than assume 0.
                    if !self.paddedMic, let micFile = self.micFile {
                        self.paddedMic = true
                        let pad = when.isHostTimeValid
                            ? self.leadingPadFrames(firstBufferHostTime: when.hostTime,
                                                    sampleRate: buffer.format.sampleRate)
                            : 0
                        if pad > 0 {
                            self.writeSilence(pad, to: micFile, format: buffer.format)
                            FileLogger.log("CaptureEngine: mic.wav left-padded \(pad) frames (\(String(format: "%.2f", Double(pad)/buffer.format.sampleRate))s) to align with capture start")
                        }
                    }
                    // Log write failures and count frames only AFTER a successful
                    // write — incrementing before the write (with the error
                    // swallowed by `try?`) gave a falsely-healthy counter.
                    do {
                        try self.micFile?.write(from: buffer)
                        self.micFramesWritten &+= Int64(buffer.frameLength)
                    } catch {
                        FileLogger.log("CaptureEngine: mic.wav write failed — \(error)")
                    }
                    // Push raw peak to the level meter — the floating HUD pill.
                    RecordingLevelMeter.shared.ingestMic(buffer: buffer)
                }
                engine.prepare()
                try engine.start()
                self.audioEngine = engine
                micStarted = true
                FileLogger.log("CaptureEngine.start: mic via AVAudioEngine; format \(fmt.sampleRate) Hz, \(fmt.channelCount) ch\(attempt > 1 ? " (started on retry \(attempt))" : "")")
                break
            } catch {
                lastMicError = error
                FileLogger.log("CaptureEngine.start: mic init attempt \(attempt) failed (\(error)) — reset + retry")
                inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
                engine.reset()
                self.micFile = nil
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
        if !micStarted {
            // All retries exhausted. By here the SCStream is ALREADY live, so a
            // bare throw would leak it (privacy indicator stuck on). Tear the
            // partial capture down before rethrowing so it fails cleanly.
            FileLogger.log("CaptureEngine.start: mic init failed after retries — tearing down any already-armed SCStream to avoid a leaked live capture")
            if let s = self.stream {
                try? s.removeStreamOutput(self, type: .screen)
                try? s.removeStreamOutput(self, type: .audio)
                try? await s.stopCapture()
            }
            self.stream = nil
            self.sckSystemURL = nil
            inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            self.micFile = nil
            throw lastMicError ?? CaptureError.noDisplay
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
        systemTap.onAudio = { [weak self] pcm, hostTime in
            // IOProc queue. Feed the level meter here (it hops to main
            // internally + is cheap), then hand the buffer to the
            // main-actor writer — same pattern the old SCStream audio
            // path used. AVAudioFile.write off a serial source is fine.
            // `hostTime` is the buffer's mach host time, threaded through so
            // the writer can left-pad system.wav to the capture-start clock.
            RecordingLevelMeter.shared.ingestSystem(pcm: pcm)
            self?.writeQueue.async { [weak self] in
                self?.writeSystemAudioPCM(pcm, hostTime: hostTime)
            }
        }
        // ALWAYS start the Core-Audio process tap — including on Bluetooth.
        // Earlier (0.14.33) we skipped the tap on BT on the theory that the
        // live tap zeros SCStream .audio, so SCK could then capture the far
        // end. MEASURED WRONG: system_sck.wav is rms=0 (pure silence) on
        // EVERY recording, with OR without the tap — SCStream .audio simply
        // doesn't capture system audio on this macOS, so it's never a real
        // backup. Meanwhile the tap DOES capture the far end on BT in many
        // sessions (e.g. 824320 voiced frames). Skipping it therefore
        // GUARANTEED far-end loss on BT, which was strictly worse. The tap
        // is the only path that ever works, so it always runs now.
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

        // All buffer sources are now stopped (SCStream, process tap, mic), so
        // no NEW write is dispatched. Drain any writes still queued on the
        // serial write queue before we close the files below — this is what
        // makes closing them safe now that the writers run off the MainActor.
        writeQueue.sync { }
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
            writeQueue.async { [weak self] in
                self?.writeVideo(sampleBuffer)
            }
        case .audio:
            // Secondary system-audio backup (see sckSystemURL doc). The
            // CMSampleBuffer is CF-retained by the closure capture, so
            // it stays valid across the hop to the write queue.
            writeQueue.async { [weak self] in
                self?.writeSCKAudio(sampleBuffer)
            }
        default:
            break
        }
    }

    nonisolated private func writeVideo(_ buffer: CMSampleBuffer) {
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

    /// Frames of leading silence a writer needs so its first real sample
    /// lands at its true offset from `captureStartHostTime`. `ht` is the
    /// first buffer's mach host time. Clamps to 0 for a writer that armed
    /// before the latch (or an invalid clock), and caps at 1 h as a sanity
    /// guard against a bogus timestamp blowing the file up.
    nonisolated private func leadingPadFrames(firstBufferHostTime ht: UInt64, sampleRate: Double) -> AVAudioFrameCount {
        guard captureStartHostTime > 0, ht > captureStartHostTime, sampleRate > 0 else { return 0 }
        let seconds = Double(ht - captureStartHostTime) * ticksToSeconds
        let frames = (seconds * sampleRate).rounded()
        guard frames > 0, frames < sampleRate * 3600 else { return 0 }
        return AVAudioFrameCount(frames)
    }

    /// Write `frames` of zeroed samples to `file`, chunked so a multi-second
    /// pad doesn't allocate one giant buffer. Zeroes via the raw buffer list
    /// so it works for interleaved and non-interleaved, float or int.
    nonisolated private func writeSilence(_ frames: AVAudioFrameCount, to file: AVAudioFile, format: AVAudioFormat) {
        guard frames > 0 else { return }
        let chunkCap: AVAudioFrameCount = 16_000
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCap) else { return }
        var remaining = frames
        while remaining > 0 {
            let n = min(chunkCap, remaining)
            buf.frameLength = n
            for b in UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList) {
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
            do { try file.write(from: buf) } catch {
                FileLogger.log("CaptureEngine: leading-silence write failed — \(error)")
                return
            }
            remaining -= n
        }
    }

    /// Tap-buffer sink, hopped to the main actor (mirrors the old
    /// SCStream `.audio` → writeSystemAudio path). The tap's IOProc is a
    /// single serial queue, so even with the hop the buffers stay
    /// ordered. `hostTime` is the first sample's mach host time, sampled in
    /// the IOProc (the only place it's available) and used once to left-pad
    /// system.wav so its frame 0 lines up with the mic.
    nonisolated private func writeSystemAudioPCM(_ pcm: AVAudioPCMBuffer, hostTime: UInt64) {
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
        if !paddedSystem {
            paddedSystem = true
            let pad = leadingPadFrames(firstBufferHostTime: hostTime, sampleRate: format.sampleRate)
            if pad > 0 {
                writeSilence(pad, to: file, format: format)
                FileLogger.log("CaptureEngine: system.wav left-padded \(pad) frames (\(String(format: "%.2f", Double(pad)/format.sampleRate))s) to align with capture start")
            }
        }
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
    nonisolated private func writeSCKAudio(_ sampleBuffer: CMSampleBuffer) {
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
        if !paddedSCK {
            paddedSCK = true
            // SCStream PTS and `captureStartHostTime` are both the mach host
            // clock (in seconds vs ticks); diff them to left-pad SCK so a
            // BT-win recording (chooser picks SCK) is aligned too.
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let startSec = Double(captureStartHostTime) * ticksToSeconds
            if pts.isFinite, startSec > 0, pts > startSec {
                let pad = AVAudioFrameCount(((pts - startSec) * format.sampleRate).rounded())
                if pad > 0, pad < AVAudioFrameCount(format.sampleRate * 3600) {
                    writeSilence(pad, to: file, format: format)
                    FileLogger.log("CaptureEngine: system_sck.wav left-padded \(pad) frames (\(String(format: "%.2f", Double(pad)/format.sampleRate))s) to align with capture start")
                }
            }
        }
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
