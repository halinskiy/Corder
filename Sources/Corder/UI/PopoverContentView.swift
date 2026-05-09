import SwiftUI

/// Strings used by the menu-bar popover. Keyed by feature; resolved at view
/// render time against `AppContext.language`, so flipping the toggle in the
/// Library window updates the popover on the next runloop tick.
fileprivate enum L {
    static func t(_ key: String, lang: String) -> String {
        let dict = lang == "ru" ? ru : en
        return dict[key] ?? en[key] ?? key
    }
    private static let en: [String: String] = [
        "idle": "Not recording",
        "recording": "Recording",
        "saving": "Saving…",
        "start": "Start recording",
        "stop": "Stop recording",
        "open_library": "Open library",
        "quit": "Quit",
    ]
    private static let ru: [String: String] = [
        "idle": "Запись не идёт",
        "recording": "Идёт запись",
        "saving": "Сохраняем…",
        "start": "Начать запись",
        "stop": "Остановить запись",
        "open_library": "Открыть библиотеку",
        "quit": "Выйти",
    ]
}

struct PopoverContentView: View {
    @ObservedObject var ctx: AppContext = .shared
    let onOpenLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch ctx.recordingState {
            case .idle:        idleSection
            case .recording(_, let startedAt): recordingSection(startedAt: startedAt)
            case .stopping:    stoppingSection
            }

            // Hairline separator between primary action and library/quit.
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 2)

            VStack(spacing: 10) {
                Button {
                    onOpenLibrary()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.stack")
                        Text(L.t("open_library", lang: ctx.language))
                    }
                }
                .buttonStyle(FlatButtonStyle(role: .secondary))

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text(L.t("quit", lang: ctx.language))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            IdleStatus(lang: ctx.language)
            Button {
                Task {
                    await RecordingController.shared.startRecording(source: .fullDisplay)
                }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(L.t("start", lang: ctx.language))
                }
            }
            .buttonStyle(FlatButtonStyle(role: .primary))
            .keyboardShortcut("r", modifiers: [.command])
        }
    }

    // MARK: - Recording

    private func recordingSection(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            RecordingStatus(startedAt: startedAt, lang: ctx.language)
            Button {
                Task { await RecordingController.shared.stopRecording() }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .frame(width: 9, height: 9)
                    Text(L.t("stop", lang: ctx.language))
                }
            }
            .buttonStyle(FlatButtonStyle(role: .primary))
            .keyboardShortcut("s", modifiers: [.command])
        }
    }

    // MARK: - Stopping

    private var stoppingSection: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text(L.t("saving", lang: ctx.language))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

}

// MARK: - Idle status (same shape as RecordingStatus, all grey, no animation)

private struct IdleStatus: View {
    let lang: String
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.t("idle", lang: lang))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("00:00")
                    .font(.system(size: 22, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - Recording status

private struct RecordingStatus: View {
    let startedAt: Date
    let lang: String
    @State private var now: Date = .init()
    private static let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(blink ? 1.0 : 0.25)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.t("recording", lang: lang))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(formatted)
                    .font(.system(size: 22, weight: .light))
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onReceive(Self.timer) { now = $0 }
    }

    private var blink: Bool { Int(now.timeIntervalSince1970) % 2 == 0 }
    private var formatted: String {
        let total = Int(now.timeIntervalSince(startedAt))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Flat IBM/Airbnb-style button

private struct FlatButtonStyle: ButtonStyle {
    enum Role { case primary, secondary }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        FlatButtonView(role: role, configuration: configuration)
    }
}

/// Internal view so we can hold @State (hover) — ButtonStyle protocol does not
/// allow stateful storage directly. Also makes the whole rounded rect a hit
/// target via `.contentShape`, instead of just the label glyphs.
private struct FlatButtonView: View {
    let role: FlatButtonStyle.Role
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            // Match the typography of the IdleStatus / RecordingStatus label
            // (14 pt regular) so the label, the primary action button, and
            // the secondary "Открыть библиотеку" all read as the same family.
            .font(.system(size: 14, weight: .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .foregroundColor(foreground)
            .background(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1.0 : 0.4)
            .onHover { hovered = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var pressed: Bool { configuration.isPressed }

    /// Hover/press shift is a tiny step away from the resting tone in BOTH
    /// directions: in Light mode the black button gets a touch lighter; in
    /// Dark mode the white button gets a touch darker. We use
    /// `NSColor(name:dynamicProvider:)` so the same Color responds correctly
    /// to whatever appearance the popover is rendered under.
    private var fillColor: Color {
        switch role {
        case .primary:
            if pressed { return Self.primaryShade(0.32) }
            if hovered { return Self.primaryShade(0.22) }
            return Color.primary
        case .secondary:
            if pressed { return Color.primary.opacity(0.08) }
            if hovered { return Color.primary.opacity(0.04) }
            return Color.clear
        }
    }
    private var strokeColor: Color {
        switch role {
        case .primary:
            return fillColor // border tracks fill exactly
        case .secondary:
            if pressed { return Color.primary.opacity(0.24) }
            if hovered { return Color.primary.opacity(0.20) }
            return Color.primary.opacity(0.16)
        }
    }

    /// Returns a colour that's `delta` step away from `Color.primary` in the
    /// "less intense" direction:
    ///   Light mode (primary == black): black → white(delta)  (e.g. #1a1a1a)
    ///   Dark  mode (primary == white): white → white(1-delta) (e.g. #f0f0f0)
    private static func primaryShade(_ delta: CGFloat) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor(white: 1.0 - delta, alpha: 1.0)   // off-white
                : NSColor(white: delta, alpha: 1.0)         // off-black
        })
    }
    private var foreground: Color {
        switch role {
        case .primary:   return Color(NSColor.windowBackgroundColor)
        case .secondary: return Color.primary
        }
    }
}

