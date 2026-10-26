import Foundation
import FluidAudio

/// Single decision point for outbound app traffic. Model downloads and
/// Sparkle are the only exceptions to Local only; loopback UI stays local.
enum NetworkPolicy {
    enum Channel: CaseIterable {
        case news, telemetry, transcriptSync, lastError, title, summary, chapters
        case cloudTranscription, cleanup, dropbox, share, account, calendar
        case diagnostics, billing, cloudMedia, feedback, auxiliaryModels
        case modelDownload, updates
    }

    struct Blocked: LocalizedError {
        let channel: Channel
        var errorDescription: String? {
            if AppSettings.localOnly { return "Local only is enabled. This action needs a cloud connection." }
            if channel == .share { return "Enable Sync transcripts to your account in Settings to share a link." }
            return "This cloud feature is disabled in Settings."
        }
    }

    static func allows(_ channel: Channel, defaults: UserDefaults = .standard) -> Bool {
        if AppSettings.localOnly(in: defaults) {
            return channel == .modelDownload || channel == .updates
        }
        switch channel {
        case .transcriptSync, .share, .cloudMedia:
            return AppSettings.syncTranscripts(in: defaults)
        case .title: return AppSettings.autoTitle(in: defaults)
        case .telemetry: return AppSettings.telemetryEnabled(in: defaults)
        default: return true
        }
    }

    static func require(_ channel: Channel) throws {
        guard allows(channel) else { throw Blocked(channel: channel) }
    }

    static func transcriptionProvider(_ preferred: TranscriptionProvider,
                                      defaults: UserDefaults = .standard) -> TranscriptionProvider {
        AppSettings.localOnly(in: defaults) ? .whisperLocal : preferred
    }

    static var callbackSession: URLSession { transport }
    private static let transport = URLSession(configuration: .default, delegate: PolicyRedirectDelegate(), delegateQueue: nil)

    static func data(for request: URLRequest, channel: Channel,
                     session: URLSession? = nil) async throws -> (Data, URLResponse) {
        try require(channel)
        return try await (session ?? transport).data(for: request)
    }

    static func upload(for request: URLRequest, from data: Data, channel: Channel) async throws -> (Data, URLResponse) {
        try require(channel)
        return try await transport.upload(for: request, from: data)
    }

    static func upload(for request: URLRequest, fromFile file: URL, channel: Channel) async throws -> (Data, URLResponse) {
        try require(channel)
        return try await transport.upload(for: request, fromFile: file)
    }

    static func download(for request: URLRequest, channel: Channel) async throws -> (URL, URLResponse) {
        try require(channel)
        return try await transport.download(for: request)
    }

    private static let auxiliaryLock = NSLock()
    private static var auxiliaryCancellations: [UUID: () -> Void] = [:]

    /// Track third-party model loads as cancellable operations. Cancelling
    /// their task also cancels future URLSession calls during SDK recovery.
    static func withAuxiliaryModels<T>(defaults: UserDefaults = .standard,
                                      _ operation: @escaping () async throws -> T) async throws -> T {
        guard allows(.auxiliaryModels, defaults: defaults) else { throw Blocked(channel: .auxiliaryModels) }
        let id = UUID()
        let task: Task<T, Error> = auxiliaryLock.withLock {
            let task = Task {
                try Task.checkCancellation()
                guard allows(.auxiliaryModels, defaults: defaults) else { throw Blocked(channel: .auxiliaryModels) }
                return try await operation()
            }
            auxiliaryCancellations[id] = { task.cancel() }
            return task
        }
        defer { _ = auxiliaryLock.withLock { auxiliaryCancellations.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    static func cancelAuxiliaryOperations() {
        auxiliaryLock.withLock { auxiliaryCancellations.values.forEach { $0() } }
    }

    /// Stop already running app requests when the user closes the network
    /// gate. Model downloads and Sparkle use their own sessions.
    static func cancelCloudRequests() {
        cancelAuxiliaryOperations()
        for session in [transport, SupabasePolicyProtocol.transport, WhisperTranscriber.transcribeSession, DownloadUtils.sharedSession] {
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
    }
}

final class PolicyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(AppSettings.localOnly ? nil : request)
    }
}

/// Reject cloud traffic in Local only, including SDK background auth refresh.
/// Allowed requests use URLSession's native transport: never relay or read bodies.
/// Transcript sync is gated at its call sites, where the operation is known.
final class SupabasePolicyProtocol: URLProtocol, @unchecked Sendable {
    static let transport: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [SupabasePolicyProtocol.self]
        return URLSession(configuration: configuration, delegate: PolicyRedirectDelegate(), delegateQueue: nil)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        !NetworkPolicy.allows(.account)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NetworkPolicy.Blocked(channel: .account))
    }
    override func stopLoading() {}
}
