import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var ctx: AppContext = .shared
    let onOpenLibrary: () -> Void

    @State private var availableWindows: [CaptureSource] = []
    @State private var selectedWindow: CaptureSource?
    @State private var loadingSources = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Corder").font(.headline)

            switch ctx.recordingState {
            case .idle:
                idleView

            case .recording(_, let startedAt):
                RecordingTimerLabel(startedAt: startedAt)
                Button {
                    Task { await RecordingController.shared.stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.red)
                }

            case .stopping:
                ProgressView().scaleEffect(0.7)
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Button("Open Library", action: onOpenLibrary).frame(maxWidth: .infinity)
            Button("Quit Corder") { NSApp.terminate(nil) }.frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 280)
        .task { await refreshWindowsIfNeeded() }
    }

    @ViewBuilder
    private var idleView: some View {
        Picker("", selection: $ctx.sourceMode) {
            Text("Full screen").tag(SourceMode.full)
            Text("Window").tag(SourceMode.window)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if ctx.sourceMode == .window {
            if loadingSources {
                ProgressView().scaleEffect(0.7)
            } else if availableWindows.isEmpty {
                Text("No windows found")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Window", selection: $selectedWindow) {
                    Text("— choose —").tag(CaptureSource?.none)
                    ForEach(availableWindows, id: \.id) { src in
                        Text(src.displayLabel).tag(Optional(src))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            Button("Refresh windows") {
                Task { await loadWindows() }
            }
            .font(.caption)
        }

        Button {
            Task {
                let src: CaptureSource
                switch ctx.sourceMode {
                case .full:
                    src = .fullDisplay
                case .window:
                    guard let chosen = selectedWindow else { return }
                    src = chosen
                }
                await RecordingController.shared.startRecording(source: src)
            }
        } label: {
            Label("Start Recording", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
        }
        .disabled(ctx.sourceMode == .window && selectedWindow == nil)
        .keyboardShortcut("r", modifiers: [.command])
    }

    private func refreshWindowsIfNeeded() async {
        if ctx.sourceMode == .window && availableWindows.isEmpty {
            await loadWindows()
        }
    }

    private func loadWindows() async {
        loadingSources = true
        defer { loadingSources = false }
        do {
            availableWindows = try await AvailableSources.windows()
            if selectedWindow == nil {
                selectedWindow = availableWindows.first
            }
        } catch {
            availableWindows = []
        }
    }
}

extension CaptureSource {
    /// Stable identity used by SwiftUI lists.
    var id: String {
        switch self {
        case .fullDisplay: return "full"
        case .window(let id, _, _, _, _): return "win-\(id)"
        }
    }
}

private struct RecordingTimerLabel: View {
    let startedAt: Date
    @State private var now: Date = .init()

    private static let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(formatted).font(.system(.body, design: .monospaced))
        }
        .onReceive(Self.timer) { now = $0 }
    }

    private var formatted: String {
        let total = Int(now.timeIntervalSince(startedAt))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
