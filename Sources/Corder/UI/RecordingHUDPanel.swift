import AppKit
import SwiftUI

/// Floating pill-shaped panel that hovers over every other window while
/// Corder is recording. Shows a live mic + system-audio level meter,
/// the elapsed time, and a one-click stop button — directly inspired
/// by Granola's bar so users have constant feedback that capture is
/// actually running.
@MainActor
final class RecordingHUDPanel {
    static let shared = RecordingHUDPanel()
    private init() {}

    private var window: NSPanel?

    func show() {
        if window?.isVisible == true { return }
        let host = NSHostingController(rootView: RecordingHUDView())
        // Compact pill, sized to match Granola's bar — small enough to
        // not get in the way, big enough to read at a glance.
        host.view.frame = NSRect(x: 0, y: 0, width: 188, height: 32)

        let panel = NSPanel(
            contentRect: host.view.bounds,
            // .borderless: no chrome.
            // .nonactivatingPanel: clicking the HUD doesn't steal focus
            //   from the app the user is actually working in.
            // .utilityWindow: lets it persist while another app is
            //   front-most.
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Float over every Space + persist when the user switches Spaces;
        // staying put visually is critical for "is it still recording?"
        // confidence — Granola uses the same combo.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        // Initial position: centered horizontally, ~44px below the menu bar
        // on the screen the cursor is currently on.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let w = panel.frame.width
            let x = f.origin.x + (f.width - w) / 2
            let y = f.origin.y + f.height - panel.frame.height - 8
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        RecordingLevelMeter.shared.reset()
    }
}

/// SwiftUI body of the HUD pill. Pulls live values from the level meter
/// and the recording controller; nothing is owned here, this is a pure
/// projection of app state.
private struct RecordingHUDView: View {
    @ObservedObject private var meter = RecordingLevelMeter.shared
    @State private var elapsed: String = "0:00"
    @State private var pulse: Bool = false

    /// Tick the elapsed-time label once per second.
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color(red: 0.78, green: 0.27, blue: 0.24))
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.0 : 0.55)
                .opacity(pulse ? 1.0 : 0.55)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            // Waveform: each bar reads the level from `history` at its
            // own age, so newer audio appears on the right and older
            // values trail to the left like a tiny EQ. With
            // sqrt-scaling upstream, normal speech draws ~50 % of the
            // bar height — clearly visible without distorting loud
            // peaks.
            Waveform(history: meter.history)
                .frame(width: 60, height: 18)

            Text(elapsed)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(white: 0.92))
                .frame(minWidth: 36, alignment: .trailing)

            Button(action: { stopRecording() }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.78, green: 0.27, blue: 0.24))
                        .frame(width: 20, height: 20)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                }
            }
            .buttonStyle(.plain)
            .help("Остановить запись")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .onReceive(timer) { _ in updateElapsed() }
    }

    private func updateElapsed() {
        // Read started-at from the global recording state. Falls back to
        // "0:00" if we're somehow visible outside of an active recording
        // (shouldn't happen, but defensive > crashing a HUD).
        guard case .recording(_, let startedAt) = AppContext.shared.recordingState else {
            elapsed = "0:00"
            return
        }
        let secs = max(0, Int(Date().timeIntervalSince(startedAt)))
        let m = secs / 60, s = secs % 60
        elapsed = String(format: "%d:%02d", m, s)
    }

    private func stopRecording() {
        Task { @MainActor in
            await RecordingController.shared.stopRecording()
        }
    }
}

/// Tiny EQ-style waveform: 7 vertical bars centered on the mid-line.
/// Each bar's height is driven by the corresponding slot in the level
/// history ring buffer. The newest sample sits on the right; older
/// samples slide left over time, producing a recognisable "rolling
/// waveform" look at a fraction of the per-frame cost of a real
/// fft-driven scope.
private struct Waveform: View {
    let history: [Float]    // index 0 = newest

    var body: some View {
        GeometryReader { geo in
            let count = history.count
            let totalGap = CGFloat(count - 1) * 3
            let barW = max(1.5, (geo.size.width - totalGap) / CGFloat(count))
            HStack(spacing: 3) {
                // Iterate oldest → newest so the latest level always
                // sits on the right of the bar group.
                ForEach(0..<count, id: \.self) { i in
                    let idx = count - 1 - i
                    let v = CGFloat(min(1, max(0, history[idx])))
                    // Floor at ~14 % so a fully-silent bar still has a
                    // pixel of presence — the bar group reads as a
                    // shape, not as flickering dots.
                    let h = max(geo.size.height * 0.14, geo.size.height * v)
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: barW, height: h)
                        .animation(.easeOut(duration: 0.18), value: v)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
