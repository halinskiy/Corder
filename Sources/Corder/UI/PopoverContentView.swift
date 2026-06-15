import SwiftUI

// Localized strings now live in `Shared/Localizations.swift` (the shared
// `L` enum). The menu-bar popover and the meeting-invite panel both
// resolve via the same table so adding a string in one place wires it
// up everywhere.

struct PopoverContentView: View {
    @ObservedObject var ctx: AppContext = .shared
    let onOpenLibrary: () -> Void

    /// Until the user finishes the Welcome wizard AND has a live
    /// Supabase session we treat the app as "locked": recording and
    /// the Library are unavailable, and the popover redirects the
    /// user to the wizard (primary) and the account site (secondary).
    /// Reading `currentUser` is synchronous — the SDK keeps the
    /// restored session in memory after launch — so it's cheap to
    /// re-check on every popover open. Without this guard the
    /// popover showed the signed-in surface for a user whose OAuth
    /// callback never reached the app (port-rotation bug).
    private var locked: Bool {
        if !AppSettings.onboardingCompleted { return true }
        if SupabaseClientHolder.shared.auth.currentUser == nil { return true }
        return false
    }

    /// Account portal — `getcorder.com/account`. Falls back to the
    /// landing root if the account page isn't built yet on launch
    /// day. Update this single constant when the page goes live.
    private static let accountURL = URL(string: "https://getcorder.com/account")!

    var body: some View {
        // Outer gap + width + padding all live on `PopoverShell` so
        // both popover surfaces (this one + InviteOfferView in
        // MenuBarController) keep identical geometry on every tweak.
        VStack(alignment: .leading, spacing: PopoverShell.outerSpacing) {
            if locked {
                lockedSection
            } else {
                switch ctx.recordingState {
                // `.preroll` shows the idle section (no indicator); a
                // "Start recording" there promotes the pre-roll via
                // startRecording's pre-roll branch.
                case .idle, .preroll: idleSection
                case .recording(_, let startedAt): recordingSection(startedAt: startedAt)
                case .stopping:    stoppingSection
                }
            }

            // Hairline separator between primary action and library/quit.
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 2)

            VStack(spacing: 10) {
                if locked {
                    Button {
                        NSWorkspace.shared.open(Self.accountURL)
                    } label: {
                        HStack(spacing: 10) {
                            // External-link variant of `rectangle.stack`
                            // from the same SF Symbols family. Explicit
                            // size + medium weight so the glyph reads
                            // at the same visual weight as the Library
                            // icon below — otherwise the bordered
                            // square SF Symbol looks smaller than the
                            // open `rectangle.stack` silhouette.
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 15, weight: .medium))
                            Text(L.t("open_account", lang: ctx.language))
                        }
                    }
                    .buttonStyle(FlatButtonStyle(role: .secondary))
                } else {
                    Button {
                        onOpenLibrary()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 15, weight: .medium))
                            Text(L.t("open_library", lang: ctx.language))
                        }
                    }
                    .buttonStyle(FlatButtonStyle(role: .secondary))
                }

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
        .padding(PopoverShell.outerPadding)
        .frame(width: PopoverShell.width)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleSection: some View {
        VStack(alignment: .leading, spacing: PopoverShell.sectionSpacing) {
            IdleStatus(lang: ctx.language)
            Button {
                MeetingDetector.shared.userStartedRecordingManually()
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

    // MARK: - Locked (wizard not finished)

    /// Replaces the idle section while the Welcome wizard is
    /// incomplete. Status pill says "Cannot record yet", primary CTA
    /// opens / re-focuses the wizard, no red recording dot.
    @ViewBuilder
    private var lockedSection: some View {
        VStack(alignment: .leading, spacing: PopoverShell.sectionSpacing) {
            LockedStatus(lang: ctx.language)
            Button {
                WelcomeWindowController.shared.presentManually()
            } label: {
                // No red dot here — this isn't a record action,
                // it's "finish setup".
                Text(L.t("open_corder", lang: ctx.language))
            }
            .buttonStyle(FlatButtonStyle(role: .primary))
            .keyboardShortcut("o", modifiers: [.command])
        }
    }

    // MARK: - Recording

    private func recordingSection(startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: PopoverShell.sectionSpacing) {
            RecordingStatus(startedAt: startedAt, lang: ctx.language)
            // Warning card appears between the status pill and the
            // Stop button when nothing audible has happened for > 10
            // minutes (e.g. user forgot the recorder running). It owns
            // its own timer so the popover stays cheap when idle.
            SilenceWarningBlock(lang: ctx.language)
            Button {
                Task { await RecordingController.shared.stopRecording() }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                    Text(L.t("stop", lang: ctx.language))
                }
            }
            .buttonStyle(FlatButtonStyle(role: .danger))
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

// MARK: - Locked status (Welcome wizard not finished yet)

/// Identical chrome to `IdleStatus` so the popover doesn't visually
/// jump when the wizard finishes — just a different label and a
/// dot that stays muted (no red even at a glance, this is not a
/// recording-ready state).
private struct LockedStatus: View {
    let lang: String
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.t("locked_status", lang: lang))
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

// MARK: - Silence warning (10+ minutes without audible speech)

/// Shows a soft amber card inside the recording popover when the
/// `RecordingLevelMeter` has gone > 10 minutes without crossing the
/// "speech" peak floor. The view evaluates the warning on its own 5 s
/// timer (cheap, since the popover only exists while open) and reads
/// `lastSpeechAt` from the shared meter — no extra state in
/// AppContext, no Combine hops on the audio thread. When the user
/// speaks again the card disappears on its next tick.
private struct SilenceWarningBlock: View {
    let lang: String
    @ObservedObject private var meter = RecordingLevelMeter.shared
    @State private var now: Date = .init()
    private static let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// Silence threshold in seconds. 10 minutes matches the user's
    /// intent: "they walked away and forgot, nudge them".
    private static let thresholdSec: TimeInterval = 600

    private var shouldShow: Bool {
        guard let last = meter.lastSpeechAt else { return false }
        return now.timeIntervalSince(last) >= Self.thresholdSec
    }

    var body: some View {
        Group {
            if shouldShow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("silence_warning_title", lang: lang))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L.t("silence_warning_body", lang: lang))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onReceive(Self.timer) { now = $0 }
    }
}

// MARK: - Flat IBM/Airbnb-style button

// Internal (not private) so the menu-bar invite popover can reuse the
// exact same button vocabulary — the invite must read as the same
// component family as the main menu, not a lookalike.
struct FlatButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, danger, accent }
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
            // `.accent` matches the larger Library CTA pattern
            // (`.audio-btn-primary` / `.clarify-btn.accent` — 16 px /
            // medium, 14 px vertical padding, 10 px radius, no
            // visible border). The other roles keep the original
            // menu-bar popover sizing (14 / regular, 8 px radius).
            .font(.system(size: fontSize, weight: fontWeight))
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, 16)
            .foregroundColor(foreground)
            .background(fillColor)
            // Only outlined roles need an overlay stroke — for the
            // filled variants (primary / danger / accent) the
            // `strokeBorder` + `clipShape` combo produced a faint
            // 0.5 px anti-aliased halo that read as a "white edge"
            // on the accent button.
            .overlay(borderOverlay)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled ? 1.0 : 0.4)
            .onHover { hovered = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    // Geometry mirrors `.clarify-btn` in `Web/src/styles.css`:
    //   border-radius: 8px; padding: 13px 16px; font-size: 14px.
    // Weight: SF on macOS renders heavier than the same
    // `font-weight` rule in a browser, so we use `.light` (300)
    // for the dark-fill roles (primary on light popover = dark text
    // on white → SF subpixel AA already paints those glyphs as
    // visually weighty; .regular tipped over into "bold"). Inverse-
    // colour roles (secondary / danger / accent — light text on
    // dark fill) get `.regular`: white-on-dark loses some weight to
    // the dark surface eating into the glyph edges, so a touch
    // more body keeps "Start recording" reading at the same visual
    // weight as "Open library" right under it.
    private var cornerRadius: CGFloat   { 8 }
    private var fontSize: CGFloat       { 14 }
    private var fontWeight: Font.Weight {
        switch role {
        case .primary: return .regular
        case .secondary, .danger, .accent: return .light
        }
    }
    private var verticalPadding: CGFloat { 13 }

    @ViewBuilder
    private var borderOverlay: some View {
        switch role {
        case .secondary:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 1)
        case .primary, .danger, .accent:
            EmptyView()
        }
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
            // Appearance-aware fill: white pill in a light popover
            // (matches the `.clarify-btn` look in the Library), no
            // fill in a dark popover so the outlined-on-dark version
            // doesn't read as a blank white block against the dark
            // popover background. Foreground tracks the same
            // appearance switch (see `foreground`).
            return Color(NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                if isDark {
                    if pressed { return NSColor.white.withAlphaComponent(0.10) }
                    if hovered { return NSColor.white.withAlphaComponent(0.06) }
                    return NSColor.clear
                } else {
                    if pressed { return NSColor(white: 0.94, alpha: 1.0) }
                    if hovered { return NSColor(white: 0.97, alpha: 1.0) }
                    return NSColor.white
                }
            })
        case .danger:
            // Same crimson family as the HUD's "active" palette so the
            // recording state reads consistently across menu and HUD.
            if pressed { return Color(red: 0.62, green: 0.10, blue: 0.16) }
            if hovered { return Color(red: 0.85, green: 0.22, blue: 0.30) }
            return Color(red: 0.78, green: 0.16, blue: 0.24)
        case .accent:
            // Brand-green prominent — same `#1F7A4F` as `--accent` in
            // `Web/src/styles.css`. Hover = `color-mix(--accent 88%, #000)`
            // ≈ `#1B6B45`. Pressed darkens further to `#15573A` so the
            // mousedown reads as "selected" not "still hovered".
            if pressed { return Color(red: 0x15 / 255.0, green: 0x57 / 255.0, blue: 0x3A / 255.0) }
            if hovered { return Color(red: 0x1B / 255.0, green: 0x6B / 255.0, blue: 0x45 / 255.0) }
            return Color(red: 0x1F / 255.0, green: 0x7A / 255.0, blue: 0x4F / 255.0)
        }
    }
    private var strokeColor: Color {
        switch role {
        case .primary, .danger, .accent:
            return fillColor // border tracks fill exactly
        case .secondary:
            // Appearance-aware outline: dark hairline on the light
            // pill, light hairline on the dark pill.
            return Color(NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                let base: NSColor = isDark ? NSColor.white : NSColor.black
                let alpha: CGFloat
                if pressed   { alpha = 0.24 }
                else if hovered { alpha = 0.20 }
                else            { alpha = 0.16 }
                return base.withAlphaComponent(alpha)
            })
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
        // Foreground tracks the appearance-aware fill in `fillColor`:
        // dark text on the white light-mode pill, light text on the
        // transparent dark-mode pill. Using `Color.primary` directly
        // was insufficient because, under a `vibrantDark` popover, it
        // resolved to WHITE even when the pill itself was forced
        // white — yielding the white-on-white "invisible button"
        // Kostya saw on the Locked popover.
        case .secondary:
            return Color(NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                return isDark ? NSColor.white
                              : NSColor(white: 0.10, alpha: 1.0)
            })
        case .danger:    return Color.white
        case .accent:    return Color.white
        }
    }
}
