import AppKit
import SwiftUI

/// Floating panel that hovers over every other window while Corder is
/// recording. The visual is a Liquid Blob — an organic shape that
/// deforms with the user's voice / system audio level. Clicking the
/// blob stops the recording; dragging it (>3 pt) repositions the
/// panel without triggering stop.
@MainActor
final class RecordingHUDPanel {
    static let shared = RecordingHUDPanel()
    private init() {}

    private var window: NSPanel?

    /// Total window size. The blob itself is inset by `glowPadding` on
    /// each edge so the soft drop-shadow / glow has room to breathe
    /// without clipping at the panel boundary.
    private static let windowSize: CGFloat = 92
    private static let glowPadding: CGFloat = 6

    func show() {
        if window?.isVisible == true { return }
        // The view needs a non-owning ref to the window so DragGesture
        // can move the panel directly. We assign it after creating the
        // panel below.
        let panelHolder = WindowHolder()
        let host = NSHostingController(rootView:
            RecordingHUDView(holder: panelHolder, glowPadding: Self.glowPadding)
        )
        host.view.frame = NSRect(x: 0, y: 0, width: Self.windowSize, height: Self.windowSize)

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
        panel.hasShadow = false                       // we draw our own glow
        panel.isMovableByWindowBackground = false     // drag via DragGesture below
        panel.level = .floating
        // Float over every Space + persist when the user switches Spaces;
        // staying visible across Spaces is the entire point of the HUD.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panelHolder.panel = panel

        // Initial position: centered horizontally, ~12 px below the menu bar
        // on the screen the cursor is currently on.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let w = panel.frame.width
            let x = f.origin.x + (f.width - w) / 2
            let y = f.origin.y + f.height - panel.frame.height - 12
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

/// Lets the SwiftUI view drive an NSPanel without owning it. The
/// holder is created on the main actor, the panel is assigned after
/// `NSPanel.init`, and the view reads it through a weak pointer in
/// its DragGesture callback.
@MainActor
private final class WindowHolder {
    weak var panel: NSPanel?
}

/// Liquid Blob HUD body. Pulls the live level from RecordingLevelMeter,
/// renders a Canvas-based organic shape, exposes a click-anywhere
/// stop and a >3 pt drag.
private struct RecordingHUDView: View {
    let holder: WindowHolder
    let glowPadding: CGFloat

    @ObservedObject private var meter = RecordingLevelMeter.shared
    /// Cumulative drag-translation since gesture start. Used to (a)
    /// distinguish tap-from-drag and (b) repeatedly nudge the NSPanel
    /// origin in `onChanged`.
    @State private var dragAccumulated: CGSize = .zero

    var body: some View {
        let level = max(meter.micLevel, meter.systemLevel)

        // TimelineView gives us a steady 60 Hz tick so the blob phase
        // animates smoothly even when no audio is coming in. Without
        // it the blob would be perfectly still during silence.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                BlobShape(time: t, level: CGFloat(level))
                    .fill(
                        // Diagonal gradient from deep red (top-left) to
                        // warm orange (bottom-right). The shape feels
                        // like molten metal more than a recording icon.
                        LinearGradient(
                            colors: [
                                Color(red: 0.74, green: 0.18, blue: 0.18),
                                Color(red: 0.93, green: 0.45, blue: 0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        // Subtle inner highlight along the top to give
                        // the blob a sense of volume rather than reading
                        // as a flat sticker.
                        BlobShape(time: t, level: CGFloat(level))
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.35),
                                        Color.white.opacity(0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color(red: 0.74, green: 0.18, blue: 0.18).opacity(0.55),
                            radius: 14 + 8 * CGFloat(level), x: 0, y: 4)
                    .padding(glowPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())  // make the entire panel hit-test
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Move the NSPanel by the delta since last tick so
                    // the blob follows the cursor 1:1.
                    let dx = value.translation.width - dragAccumulated.width
                    let dy = value.translation.height - dragAccumulated.height
                    dragAccumulated = value.translation
                    if abs(value.translation.width) + abs(value.translation.height) > 3 {
                        moveWindow(dx: dx, dy: dy)
                    }
                }
                .onEnded { value in
                    let total = abs(value.translation.width) + abs(value.translation.height)
                    dragAccumulated = .zero
                    // Treat as a tap if the cursor barely moved between
                    // press-down and release.
                    if total < 3 {
                        stopRecording()
                    }
                }
        )
        .help("Click to stop recording")
    }

    private func moveWindow(dx: CGFloat, dy: CGFloat) {
        guard let panel = holder.panel else { return }
        var f = panel.frame
        // SwiftUI Y goes down, AppKit Y goes up — flip the delta.
        f.origin.x += dx
        f.origin.y -= dy
        panel.setFrameOrigin(f.origin)
    }

    private func stopRecording() {
        Task { @MainActor in
            await RecordingController.shared.stopRecording()
        }
    }
}

/// The blob path itself: a closed curve through 8 control points
/// distributed around a circle, with each point's distance from the
/// centre wobbling on its own phase. Audio level pushes a few of the
/// points further out, deforming the shape in step with the voice.
///
/// Implementation note: we draw quadratic Béziers between successive
/// midpoints, using each control point as the curve's control. This
/// is the textbook "smooth closed curve through points" trick — gives
/// continuous tangents at every joint without doing full Catmull-Rom.
private struct BlobShape: Shape {
    var time: TimeInterval
    var level: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2
        let pointCount = 8

        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * 2 * .pi - .pi / 2
            // Each point gets its own phase, so neighbours don't bulge
            // in lock-step. The frequencies are picked to be close but
            // not commensurate — the blob never quite repeats itself.
            let phase = time * 1.4 + Double(i) * 0.71
            let wobble = sin(phase) * 0.06 + sin(phase * 2.3 + 1.1) * 0.03
            // Audio level pushes the radius outward a touch. We rotate
            // the level-impact phase per-point so loud audio doesn't
            // just inflate the blob uniformly — different sides bulge
            // at different times for a "speaking" feel.
            let levelPhase = sin(time * 2.1 + Double(i) * 1.2)
            let levelBoost = Double(level) * 0.18 * (0.5 + 0.5 * levelPhase)
            let r = baseRadius * (1.0 + wobble + levelBoost)
            points.append(.init(
                x: center.x + cos(angle) * r,
                y: center.y + sin(angle) * r
            ))
        }

        var path = Path()
        // Start at the midpoint between the last and first control
        // points so the curve closes seamlessly.
        let startMid = midpoint(points.last!, points.first!)
        path.move(to: startMid)
        for i in 0..<pointCount {
            let next = points[(i + 1) % pointCount]
            let mid = midpoint(points[i], next)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    var animatableData: CGFloat {
        get { level }
        set { level = newValue }
    }
}
