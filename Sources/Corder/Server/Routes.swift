import Foundation
import GRDB
import Swifter
import AppKit

enum Routes {
    static func register(server: HttpServer, repo: MeetingRepository) {
        server.get["/"] = { _ in serveIndex() }
        server.get["/index.html"] = { _ in serveIndex() }
        server.get["/assets/:path"] = { req in serveAsset(path: req.params[":path"] ?? "") }

        server.get["/api/meetings"] = { _ in listMeetings(repo: repo) }
        server.get["/api/meetings/:id"] = { req in
            meetingDetail(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/meetings/:id/transcript.txt"] = { req in
            transcriptText(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/meetings/:id/transcript.md"] = { req in
            transcriptExport(id: req.params[":id"] ?? "", repo: repo, kind: .md)
        }
        server.get["/api/meetings/:id/transcript.json"] = { req in
            transcriptExport(id: req.params[":id"] ?? "", repo: repo, kind: .json)
        }
        server.get["/api/meetings/:id/video"] = { req in
            serveMedia(id: req.params[":id"] ?? "", kind: .video, repo: repo, headers: req.headers)
        }
        server.get["/api/meetings/:id/audio"] = { req in
            serveMedia(id: req.params[":id"] ?? "", kind: .audio, repo: repo, headers: req.headers)
        }
        server.get["/api/meetings/:id/bundle.zip"] = { req in
            bundleZip(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/speakers/:sid/rename"] = { req in
            renameSpeaker(req: req, repo: repo)
        }
        server.post["/api/meetings/:id/rename"] = { req in
            renameMeeting(req: req, repo: repo)
        }
        server.post["/api/meetings/:id/retranscribe"] = { req in
            retranscribe(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/cancel-transcription"] = { req in
            cancelTranscription(id: req.params[":id"] ?? "")
        }
        server.post["/api/meetings/:id/expected-speakers"] = { req in
            setExpectedSpeakers(id: req.params[":id"] ?? "", req: req, repo: repo)
        }
        server.get["/api/meetings/:id/last-error"] = { req in
            lastError(id: req.params[":id"] ?? "")
        }
        server.post["/api/meetings/:id/summarize"] = { req in
            summarize(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/recording/state"] = { _ in recordingState() }
        server.post["/api/recording/start"] = { _ in startRecordingNow() }
        server.post["/api/recording/stop"] = { _ in stopRecordingNow() }
        server.get["/api/settings"] = { _ in settingsGet() }
        server.post["/api/settings"] = { req in settingsSet(req: req) }
        server.get["/api/installed-apps"] = { _ in installedAppsGet() }
        server.get["/api/app-icon/:bundle"] = { req in
            appIcon(bundle: req.params[":bundle"] ?? "")
        }
        server.delete["/api/meetings/:id"] = { req in
            deleteMeeting(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/archive"] = { _ in listArchived(repo: repo) }
        server.post["/api/meetings/:id/archive"] = { req in
            archive(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/restore"] = { req in
            restore(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/pin"] = { req in
            setPin(id: req.params[":id"] ?? "", repo: repo, pinned: true)
        }
        server.post["/api/meetings/:id/unpin"] = { req in
            setPin(id: req.params[":id"] ?? "", repo: repo, pinned: false)
        }
        server.get["/api/search"] = { req in
            let q = req.queryParams.first(where: { $0.0 == "q" })?.1 ?? ""
            return search(query: q, repo: repo)
        }
        server.get["/api/update-status"] = { _ in updateStatus() }
        server.post["/api/update-check"] = { _ in updateCheck() }
    }

    // MARK: static

    /// Web-assets root, resolved from `Bundle.main` — NOT the
    /// SwiftPM-generated `Bundle.module`.
    ///
    /// `Bundle.module`'s accessor calls `fatalError` when it can't find
    /// `Corder_Corder.bundle`. Its candidate list is baked at compile
    /// time and includes the dev machine's `.build/release/` path, so a
    /// miss is invisible locally but a HARD CRASH on any other Mac — the
    /// friend's "open Library → SIGTRAP" was exactly this: the first
    /// HTTP request from the WKWebView hit `Bundle.module` init →
    /// assertionFailure. In a packaged .app the resource bundle lives at
    /// `Contents/Resources/Corder_Corder.bundle` (put there by
    /// build-app.sh), which `Bundle.main.resourceURL` points straight
    /// at. Resolve from there; on a genuine miss serve a clean 404
    /// instead of trapping the whole process.
    private static let webRootURL: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Corder_Corder.bundle"))
        }
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Corder_Corder.bundle"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("Corder_Corder.bundle"))
        }
        for bundle in candidates {
            let web = bundle.appendingPathComponent("web", isDirectory: true)
            if fm.fileExists(atPath: web.appendingPathComponent("index.html").path) {
                return web
            }
        }
        FileLogger.log("Routes: web assets not found in any Bundle.main candidate — serving 404 (resource bundle missing from .app)")
        return nil
    }()

    private static func serveIndex() -> HttpResponse {
        guard let url = webRootURL?.appendingPathComponent("index.html"),
              let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        return .raw(200, "OK", ["Content-Type": "text/html; charset=utf-8"]) { writer in
            try writer.write(data)
        }
    }

    private static func serveAsset(path: String) -> HttpResponse {
        guard let webRoot = webRootURL else { return .notFound }
        let target = webRoot.appendingPathComponent("assets").appendingPathComponent(path)
        guard let data = try? Data(contentsOf: target) else { return .notFound }
        let mime = mimeType(for: target.pathExtension)
        return .raw(200, "OK", ["Content-Type": mime]) { try $0.write(data) }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    // MARK: api

    private static func listMeetings(repo: MeetingRepository) -> HttpResponse {
        do {
            // Single SQL query with correlated subselects — replaces the
            // old per-meeting segments + speakers fan-out that produced
            // ≥2N reads on every sidebar poll.
            let rows = try repo.listMeetingSummaries()
            let summaries: [DTO.MeetingSummary] = rows.map { r in
                DTO.MeetingSummary(
                    id: r.id,
                    started_at: r.startedAt,
                    ended_at: r.endedAt,
                    duration_ms: r.durationMs,
                    status: r.status,
                    title: r.title,
                    preview: r.preview,
                    speaker_count: r.speakerCount,
                    speaker_names: r.speakerNames,
                    pinned: r.pinnedAt != nil
                )
            }
            return jsonResponse(summaries)
        } catch {
            return .internalServerError
        }
    }

    private static func meetingDetail(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let speakers = try repo.speakers(forMeeting: id)
            let segments = try repo.segments(forMeeting: id)
            let hasVideo = FileManager.default.fileExists(atPath: m.videoPath)
                || (m.dropboxVideoPath != nil)
            let dto = DTO.MeetingDetail(
                id: m.id, started_at: m.startedAt, duration_ms: m.durationMs,
                status: m.status.rawValue,
                title: m.title,
                summary: m.summary,
                speakers: speakers.map {
                    DTO.SpeakerDTO(id: $0.id, label: $0.label, custom_name: $0.customName, color_hex: $0.colorHex)
                },
                segments: segments.map {
                    DTO.SegmentDTO(id: $0.id ?? 0, speaker_id: $0.speakerId,
                                   start_ms: $0.startMs, end_ms: $0.endMs, text: $0.text,
                                   text_boost: $0.textBoost)
                },
                expected_other_speakers: m.expectedOtherSpeakers,
                has_video: hasVideo
            )
            return jsonResponse(dto)
        } catch {
            return .internalServerError
        }
    }

    private static func transcriptText(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            let segments = try repo.segments(forMeeting: id)
            let speakers = try repo.speakers(forMeeting: id)
            let text = TranscriptFormatter.clipboardText(segments: segments, speakers: speakers)
            return .raw(200, "OK", ["Content-Type": "text/plain; charset=utf-8"]) {
                try $0.write([UInt8](text.utf8))
            }
        } catch {
            return .internalServerError
        }
    }

    /// Bundles whatever exists locally (video, mixed audio, transcript)
    /// into a single .zip. Shells out to /usr/bin/zip — ships with macOS,
    /// no dependency. Blocks the Swifter worker like the other media
    /// routes; the payload is small (a short meeting) to a few hundred MB.
    private static func bundleZip(id: String, repo: MeetingRepository) -> HttpResponse {
        guard let m = try? repo.meeting(id: id) else { return .notFound }

        let fm = FileManager.default
        let stage = fm.temporaryDirectory
            .appendingPathComponent("corder-bundle-\(id)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
        catch { return .internalServerError }

        // Transcript
        if let segs = try? repo.segments(forMeeting: id),
           let spks = try? repo.speakers(forMeeting: id), !segs.isEmpty {
            let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)
            try? text.data(using: .utf8)?
                .write(to: stage.appendingPathComponent("transcript.txt"))
        }
        // Video
        let videoURL = URL(fileURLWithPath: m.videoPath)
        if fm.fileExists(atPath: videoURL.path) {
            try? fm.copyItem(at: videoURL,
                             to: stage.appendingPathComponent("video." + videoURL.pathExtension))
        }
        // Audio — prefer the mixed audio.wav (both sides), else stored path.
        let mixURL = AppPaths.recordingDir(for: id).appendingPathComponent("audio.wav")
        let audioURL = fm.fileExists(atPath: mixURL.path)
            ? mixURL : URL(fileURLWithPath: m.audioPath)
        if fm.fileExists(atPath: audioURL.path) {
            try? fm.copyItem(at: audioURL,
                             to: stage.appendingPathComponent("audio.wav"))
        }

        let entries = (try? fm.contentsOfDirectory(atPath: stage.path)) ?? []
        guard !entries.isEmpty else { return .notFound }

        let zipURL = fm.temporaryDirectory
            .appendingPathComponent("corder-\(id)-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: zipURL) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = stage
        proc.arguments = ["-j", "-q", "-r", zipURL.path, "."]
        do { try proc.run(); proc.waitUntilExit() }
        catch { return .internalServerError }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: zipURL) else { return .internalServerError }

        let bytes = [UInt8](data)
        return .raw(200, "OK", [
            "Content-Type": "application/zip",
            "Content-Disposition": "attachment; filename=\"corder-\(id).zip\"",
            "Content-Length": String(bytes.count)
        ]) { try $0.write(bytes) }
    }

    private enum ExportKind { case md, json }
    private static func transcriptExport(id: String, repo: MeetingRepository,
                                         kind: ExportKind) -> HttpResponse {
        do {
            let segments = try repo.segments(forMeeting: id)
            let speakers = try repo.speakers(forMeeting: id)
            let m = try? repo.meeting(id: id)
            let title = (m?.title?.trimmingCharacters(in: .whitespaces)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Corder recording"
            let (body, ctype, fname): (String, String, String)
            switch kind {
            case .md:
                body = TranscriptFormatter.markdown(segments: segments, speakers: speakers, title: title)
                ctype = "text/markdown; charset=utf-8"
                fname = "\(id).md"
            case .json:
                body = TranscriptFormatter.json(segments: segments, speakers: speakers, title: title)
                ctype = "application/json; charset=utf-8"
                fname = "\(id).json"
            }
            return .raw(200, "OK", [
                "Content-Type": ctype,
                "Content-Disposition": "attachment; filename=\"corder-\(fname)\""
            ]) { try $0.write([UInt8](body.utf8)) }
        } catch {
            return .internalServerError
        }
    }

    private static func recordingState() -> HttpResponse {
        switch RecordingStateSnapshot.read() {
        case .idle:
            return jsonResponse(["active": false] as [String: Any])
        case .recording(let meetingId, let startedAt):
            return jsonResponse([
                "active": true,
                "meeting_id": meetingId,
                "started_at_ms": Int64(startedAt.timeIntervalSince1970 * 1000)
            ] as [String: Any])
        case .stopping:
            return jsonResponse(["active": true, "stopping": true] as [String: Any])
        }
    }

    private static func startRecordingNow() -> HttpResponse {
        // The inline blob in the Library window posts here. Same path as
        // the menu-bar Start button: tell the meeting detector to drop
        // any pending invite (we already know about the call), then
        // start a full-display capture.
        Task { @MainActor in
            MeetingDetector.shared.userStartedRecordingManually()
            await RecordingController.shared.startRecording(source: .fullDisplay)
        }
        return .ok(.text("starting"))
    }

    private static func stopRecordingNow() -> HttpResponse {
        Task { @MainActor in
            await RecordingController.shared.stopRecording()
        }
        return .ok(.text("stopping"))
    }

    /// Polled by the React toolbar (~once a minute). Returns the
    /// newest version Sparkle has resolved from the appcast, if any.
    /// Sparkle keeps re-checking on its own 24h schedule + at startup;
    /// we just expose the latest verdict.
    private static func updateStatus() -> HttpResponse {
        let v = AvailableUpdateSnapshot.read()
        var payload: [String: Any] = ["available": v != nil]
        if let v = v { payload["version"] = v }
        return jsonResponse(payload)
    }

    /// Fire-and-forget: tells Sparkle to show its standard update UI
    /// (the "A new version of Corder is available" panel with the
    /// release notes from `appcast.xml`). Click on the green toolbar
    /// pill posts here.
    private static func updateCheck() -> HttpResponse {
        Task { @MainActor in
            UpdateController.shared.checkForUpdates(nil)
        }
        return .ok(.text("checking"))
    }

    private static var geminiKeyPath: String {
        ("~/.config/corder/gemini_key" as NSString).expandingTildeInPath
    }

    private static let kbNames: [Int: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
        11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",
        31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",
        36:"↩",48:"⇥",49:"Space",53:"Esc",
        122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
        101:"F9",109:"F10",103:"F11",111:"F12",
        123:"←",124:"→",125:"↓",126:"↑",
    ]

    /// Carbon mods mask + key code → "⌃⌥⇧⌘F"-style label.
    private static func hotkeyLabel(code: Int, mods: Int) -> String {
        var s = ""
        if mods & 4096 != 0 { s += "⌃" }
        if mods & 2048 != 0 { s += "⌥" }
        if mods & 512  != 0 { s += "⇧" }
        if mods & 256  != 0 { s += "⌘" }
        s += kbNames[code] ?? "Key\(code)"
        return s
    }

    /// Curated table of well-known macOS *system* shortcuts. We can't
    /// detect a clashing third-party app (no OS API for that) — the UI
    /// says so — but the stock ones are stable and worth warning about.
    private static func hotkeyConflict(code: Int, mods: Int) -> String? {
        switch (mods, code) {
        case (256, 49):   return "Spotlight (⌘Space)"
        case (4096, 49):  return "Input source (⌃Space)"
        case (768, 20):   return "Screenshot (⌘⇧3)"
        case (768, 21):   return "Screenshot (⌘⇧4)"
        case (768, 23):   return "Screenshot (⌘⇧5)"
        case (256, 48):   return "App switcher (⌘⇥)"
        case (4096, 126): return "Mission Control (⌃↑)"
        case (4096, 123): return "Move a space left (⌃←)"
        case (4096, 124): return "Move a space right (⌃→)"
        case (4352, 12):  return "Lock screen (⌃⌘Q)"
        default:          return nil
        }
    }

    private static func currentSettings() -> DTO.Settings {
        DTO.Settings(
            language: AppLanguage.current,
            vocabulary: AppVocabulary.current,
            gemini_key: nil,        // never echo the key back
            gemini_key_set: FileManager.default.fileExists(atPath: geminiKeyPath),
            notifications: AppSettings.notificationsEnabled,
            capture_video: AppSettings.captureVideo,
            capture_audio: AppSettings.captureAudio,
            auto_transcribe: AppSettings.autoTranscribe,
            auto_title: AppSettings.autoTitle,
            meeting_whitelist: AppSettings.meetingWhitelist,
            meeting_blacklist: AppSettings.meetingBlacklist,
            detected_mic_apps: MicAppsSnapshot.read(),
            record_hotkey_code: AppSettings.recordHotkeyKeyCode,
            record_hotkey_mods: AppSettings.recordHotkeyModifiers,
            record_hotkey_label: hotkeyLabel(
                code: AppSettings.recordHotkeyKeyCode,
                mods: AppSettings.recordHotkeyModifiers),
            record_hotkey_conflict: hotkeyConflict(
                code: AppSettings.recordHotkeyKeyCode,
                mods: AppSettings.recordHotkeyModifiers),
            record_hotkey_ok: HotkeyStatusSnapshot.read()
        )
    }

    private static func settingsGet() -> HttpResponse {
        return jsonResponse(currentSettings())
    }

    /// Installed apps for the Settings picker. Scans the usual app
    /// roots, reads each bundle's id + display name, dedups, and floats
    /// apps Corder recently saw on the mic to the top. Best-effort and
    /// off-main (Swifter thread) — purely UI sugar, never blocks core.
    private static func installedAppsGet() -> HttpResponse {
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        var byBundle: [String: String] = [:]   // bundle → display name
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for e in entries where e.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(e)
                guard let b = Bundle(url: url),
                      let id = b.bundleIdentifier, !id.isEmpty else { continue }
                if byBundle[id] != nil { continue }
                let info = b.infoDictionary
                let name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? (e as NSString).deletingPathExtension
                byBundle[id] = name
            }
        }
        let recent = Set(MicAppsSnapshot.read())
        let apps = byBundle
            .map { DTO.InstalledApp(bundle: $0.key, name: $0.value,
                                    recent: recent.contains($0.key)) }
            .sorted {
                if $0.recent != $1.recent { return $0.recent && !$1.recent }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        return jsonResponse(apps)
    }

    /// 64-pt PNG icon for one bundle id, for the picker / list rows.
    /// Browser-cacheable; 404 when the app isn't resolvable.
    private static func appIcon(bundle: String) -> HttpResponse {
        guard !bundle.isEmpty,
              let appURL = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundle)
        else { return .notFound }
        return autoreleasepool { () -> HttpResponse in
            // Rasterise to a fixed 64 px bitmap. (icon.tiffRepresentation
            // hands back the full multi-resolution icon — up to 1024 px,
            // ~1.4 MB each — far too heavy for a list of rows.)
            let px = 64
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
            else { return .notFound }
            rep.size = NSSize(width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                      from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:])
            else { return .notFound }
            return .raw(200, "OK", [
                "Content-Type": "image/png",
                "Cache-Control": "max-age=86400",
            ]) { try $0.write(png) }
        }
    }

    private static func settingsSet(req: HttpRequest) -> HttpResponse {
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.Settings.self, from: body)
            if let lang = parsed.language, lang == "ru" || lang == "en" {
                UserDefaults.standard.set(lang, forKey: AppLanguage.key)
                Task { @MainActor in
                    AppContext.shared.language = lang
                }
            }
            if let vocab = parsed.vocabulary {
                UserDefaults.standard.set(
                    vocab.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: AppVocabulary.key)
            }
            if let key = parsed.gemini_key?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                let path = geminiKeyPath
                try? FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try? key.write(toFile: path, atomically: true, encoding: .utf8)
                // Owner-only — it's a secret.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            }
            // Functional toggles + app lists. Absent field ⇒ unchanged
            // (a stale frontend can never silently flip a new toggle).
            if let v = parsed.notifications    { AppSettings.setNotifications(v) }
            if let v = parsed.capture_video    { AppSettings.setCaptureVideo(v) }
            if let v = parsed.capture_audio    { AppSettings.setCaptureAudio(v) }
            if let v = parsed.auto_transcribe  { AppSettings.setAutoTranscribe(v) }
            if let v = parsed.auto_title       { AppSettings.setAutoTitle(v) }
            if let v = parsed.meeting_whitelist { AppSettings.setMeetingWhitelist(v) }
            if let v = parsed.meeting_blacklist { AppSettings.setMeetingBlacklist(v) }
            if let c = parsed.record_hotkey_code, let m = parsed.record_hotkey_mods {
                AppSettings.setRecordHotkey(code: c, mods: m)
                // Carbon registration must happen on the main run loop.
                // record_hotkey_ok in this response may still reflect
                // the previous binding (the re-register is async); the
                // client re-fetches shortly to get the authoritative
                // value. The conflict label is computed synchronously
                // from the table so it's already correct here.
                Task { @MainActor in
                    HotkeyManager.shared.register(
                        keyCode: UInt32(c), modifiers: UInt32(m))
                }
            }
            FileLogger.log("settings: language=\(parsed.language ?? "nil") vocab=\(parsed.vocabulary != nil) keySet=\(parsed.gemini_key != nil) toggles[n=\(parsed.notifications.map(String.init) ?? "-"),v=\(parsed.capture_video.map(String.init) ?? "-"),a=\(parsed.capture_audio.map(String.init) ?? "-"),at=\(parsed.auto_transcribe.map(String.init) ?? "-"),ti=\(parsed.auto_title.map(String.init) ?? "-")] wl=\(parsed.meeting_whitelist?.count ?? -1) bl=\(parsed.meeting_blacklist?.count ?? -1)")
            return jsonResponse(currentSettings())
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func retranscribe(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        FileLogger.log("retranscribe: queued for \(id)")
        // Flip status + clear old segments synchronously so the very next
        // GET /api/meetings/:id from the UI returns `transcribing` with an
        // empty segment list — letting the TranscribingBanner appear
        // instantly instead of the "Empty transcript" placeholder.
        if var m = try? repo.meeting(id: id) {
            m.status = .transcribing
            try? repo.updateMeeting(m)
        }
        try? repo.clearTranscript(meetingId: id)
        TranscriptionErrors.clear(meetingId: id)
        Task { @MainActor in
            TranscriptionPipeline.shared.enqueue(meetingId: id)
        }
        return .ok(.text("queued"))
    }

    /// On-demand summary. Returns the cached `summary` if present;
    /// otherwise generates one from the transcript (blocking this
    /// Swifter worker for the Gemini round-trip — same accepted pattern
    /// as the Dropbox-hydrate path), stores it, and returns it.
    private static func summarize(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        guard let m = try? repo.meeting(id: id) else { return .notFound }
        if let cached = m.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            return jsonResponse(["summary": cached])
        }
        let segs = (try? repo.segments(forMeeting: id)) ?? []
        guard !segs.isEmpty else {
            return jsonResponse(["summary": "", "error": "no transcript"])
        }
        let spks = (try? repo.speakers(forMeeting: id)) ?? []
        let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)

        let sema = DispatchSemaphore(value: 0)
        var result: String?
        Task {
            result = await GeminiSummarizer.generate(transcript: text)
            sema.signal()
        }
        sema.wait()

        guard let summary = result, !summary.isEmpty else {
            return jsonResponse(["summary": "", "error": "generation failed"])
        }
        try? repo.setSummary(meetingId: id, summary: summary)
        FileLogger.log("summarize: generated summary for \(id) (\(summary.count) chars)")
        return jsonResponse(["summary": summary])
    }

    private static func cancelTranscription(id: String) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        FileLogger.log("cancelTranscription: \(id)")
        Task { @MainActor in
            TranscriptionPipeline.shared.cancel(meetingId: id)
        }
        return .ok(.text("cancelled"))
    }

    private static func lastError(id: String) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        let payload: [String: Any] = ["error": TranscriptionErrors.read(meetingId: id) as Any]
        return jsonResponse(payload)
    }

    private static func setExpectedSpeakers(id: String, req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        guard let body = try? JSONDecoder().decode(DTO.ExpectedSpeakersRequest.self, from: Data(req.body)) else {
            return .badRequest(.text("bad json"))
        }
        do {
            guard var m = try repo.meeting(id: id) else { return .notFound }
            m.expectedOtherSpeakers = body.count
            try repo.updateMeeting(m)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func deleteMeeting(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            // Best-effort cleanup of cloud archive (fire-and-forget).
            if let m = try? repo.meeting(id: id) {
                if let vp = m.dropboxVideoPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: vp) }
                }
                if let ap = m.dropboxAudioPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: ap) }
                }
            }
            // Best-effort cleanup of files on disk.
            let dir = AppPaths.recordingDir(for: id)
            try? FileManager.default.removeItem(at: dir)
            try repo.deleteMeeting(id: id)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    /// Soft-archive: stamps `archived_at` so the meeting drops out of
    /// the main library and shows up in the archive panel. Audio stays
    /// on disk / Dropbox until the user either restores or wipes it,
    /// or until the 7-day grace period elapses (see launch cleanup).
    private static func archive(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try repo.setArchived(meetingId: id, archivedAt: now)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func restore(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            try repo.setArchived(meetingId: id, archivedAt: nil)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func setPin(id: String, repo: MeetingRepository, pinned: Bool) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try repo.setPinned(meetingId: id, pinnedAt: pinned ? now : nil)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func listArchived(repo: MeetingRepository) -> HttpResponse {
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let retentionMs: Int64 = 7 * 24 * 60 * 60 * 1000  // 7 days
            let items = try repo.listArchived().map { m -> [String: Any] in
                let archivedAt = m.archivedAt ?? now
                let purgeAt = archivedAt + retentionMs
                return [
                    "id": m.id,
                    "started_at": m.startedAt,
                    "duration_ms": m.durationMs as Any,
                    "archived_at": archivedAt,
                    "purge_at": purgeAt
                ]
            }
            return jsonResponse(["items": items])
        } catch {
            return .internalServerError
        }
    }

    private static func renameSpeaker(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let sid = req.params[":sid"] ?? ""
        guard !sid.isEmpty else { return .badRequest(.text("missing speaker id")) }
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.RenameRequest.self, from: body)
            try repo.renameSpeaker(speakerId: sid, customName: parsed.name)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func renameMeeting(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let id = req.params[":id"] ?? ""
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.MeetingTitleRequest.self, from: body)
            // Empty / whitespace clears the override so the UI falls back
            // to the auto-title (or the date label when there's none).
            let trimmed = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (trimmed?.isEmpty ?? true) ? nil : trimmed
            try repo.setTitle(meetingId: id, title: title)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func search(query: String, repo: MeetingRepository) -> HttpResponse {
        guard !query.isEmpty else { return jsonResponse([DTO.SearchHit]()) }
        do {
            let segs = try repo.searchSegments(query: query)
            let hits = segs.map {
                DTO.SearchHit(meeting_id: $0.meetingId, segment_id: $0.id ?? 0,
                              start_ms: $0.startMs, text: $0.text)
            }
            return jsonResponse(hits)
        } catch {
            return .internalServerError
        }
    }

    // MARK: media (Range)

    private enum MediaKind { case video, audio }

    private static func serveMedia(id: String, kind: MediaKind, repo: MeetingRepository, headers: [String: String]) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let dropboxRemote = (kind == .video) ? m.dropboxVideoPath : m.dropboxAudioPath
            let contentType = (kind == .video) ? "video/quicktime" : "audio/wav"

            // Audio resolution order:
            //   1. The post-mix audio.wav inside the meeting dir — this is
            //      what AudioMixer produces from mic+system, and the only
            //      local file that contains BOTH the user and the
            //      interlocutor. Always prefer it when it's on disk.
            //   2. The DB-stored audioPath (usually mic.wav) — fallback for
            //      meetings where mix.wav is gone but mic.wav is still around
            //      (legacy rows pre-dual-track, or capture races).
            //   3. Neither exists → fall through to Dropbox hydrate below,
            //      which restores audio.wav from the archive.
            // Video has only the canonical videoPath; no fallback.
            var url: URL
            if kind == .video {
                url = URL(fileURLWithPath: m.videoPath)
            } else {
                let mixURL = AppPaths.recordingDir(for: id).appendingPathComponent("audio.wav")
                if FileManager.default.fileExists(atPath: mixURL.path) {
                    url = mixURL
                } else {
                    let direct = URL(fileURLWithPath: m.audioPath)
                    if FileManager.default.fileExists(atPath: direct.path) {
                        url = direct
                    } else {
                        // Hydrate target — full mix lives at audio.wav remote.
                        url = mixURL
                    }
                }
            }

            // Cloud cache miss: file was archived to Dropbox and the local
            // copy got deleted. Pull it back to the canonical local path
            // (one-time blocking download), then continue down the regular
            // local-file branch — including Range support. Subsequent
            // scrubbing requests are served straight from disk without
            // re-blocking a Swifter worker.
            if !FileManager.default.fileExists(atPath: url.path), let remote = dropboxRemote {
                FileLogger.log("serveMedia: cache miss for \(id) (\(kind)), fetching from Dropbox \(remote)")
                guard hydrateDropboxFile(remote: remote, localURL: url) else {
                    return .internalServerError
                }
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            // Swifter lower-cases header keys.
            guard let rangeHeader = headers["range"] ?? headers["Range"] else {
                let data = try Data(contentsOf: url)
                return .raw(200, "OK", [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(size)"
                ]) { try $0.write(data) }
            }

            guard let r = RangeRequest.parse(rangeHeader, fileSize: size) else {
                return .raw(416, "Range Not Satisfiable", [
                    "Content-Range": "bytes */\(size)"
                ]) { _ in }
            }

            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(r.start))
            let chunk = handle.readData(ofLength: Int(r.length))
            try? handle.close()

            return .raw(206, "Partial Content", [
                "Content-Type": contentType,
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(r.start)-\(r.end)/\(size)",
                "Content-Length": "\(r.length)"
            ]) { try $0.write(chunk) }
        } catch {
            return .internalServerError
        }
    }

    /// One-time Dropbox → local restore. Used by `serveMedia` when the
    /// canonical local file has been archived and deleted. Blocks the
    /// calling Swifter worker for the duration of the download (which can
    /// be tens of seconds for an hour-long meeting), but only on the very
    /// first request — once the file lands at `localURL` every subsequent
    /// request, including Range scrubs, is served straight from disk
    /// without ever touching this code path again.
    ///
    /// We deliberately don't proxy bytes per-request the way the previous
    /// implementation did: scrubbing produces dozens of Range requests in
    /// a few seconds, each of which would have blocked a worker thread on
    /// its own `URLSession.data` round-trip and hammered Dropbox's
    /// rate limit.
    private static func hydrateDropboxFile(remote: String, localURL: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        Task.detached {
            defer { semaphore.signal() }
            do {
                try await DropboxService.shared.download(remotePath: remote, to: localURL)
                ok = true
            } catch {
                FileLogger.log("hydrateDropboxFile: \(remote) → \(localURL.lastPathComponent) failed: \(error)")
            }
        }
        semaphore.wait()
        return ok
    }

    // MARK: helpers

    private static func jsonResponse<T: Encodable>(_ value: T) -> HttpResponse {
        do {
            let enc = JSONEncoder()
            let data = try enc.encode(value)
            return .raw(200, "OK", ["Content-Type": "application/json; charset=utf-8"]) {
                try $0.write([UInt8](data))
            }
        } catch {
            return .internalServerError
        }
    }

    private static func jsonResponse(_ value: [String: Any]) -> HttpResponse {
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            return .raw(200, "OK", ["Content-Type": "application/json; charset=utf-8"]) {
                try $0.write([UInt8](data))
            }
        } catch {
            return .internalServerError
        }
    }
}
