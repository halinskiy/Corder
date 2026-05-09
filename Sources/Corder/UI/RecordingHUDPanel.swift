import AppKit
import SwiftUI

/// Floating panel that hovers over every other window while Corder is
/// recording. The visual is a Liquid Blob — an organic shape that
/// morphs through several geometric templates (blob → star →
/// hexagon → squircle) on a slow cycle, while reacting in real time
/// to mic + system audio level. Click stops the recording; drag
/// repositions the panel.
@MainActor
final class RecordingHUDPanel {
    static let shared = RecordingHUDPanel()
    private init() {}

    private var window: NSPanel?

    /// Total panel size. The blob itself only occupies ~60 % of this;
    /// the rest is breathing room for the radial glow + the hover
    /// scale-up so neither ever clips at the panel boundary.
    private static let windowSize: CGFloat = 120

    func show() {
        if window?.isVisible == true { return }
        let panelHolder = WindowHolder()
        let host = NSHostingController(rootView:
            RecordingHUDView(holder: panelHolder)
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
        // Float over every Space + persist when the user switches Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panelHolder.panel = panel

        // Initial position: centered horizontally, ~12 px below the menu bar.
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
/// renders a Canvas-based morphing shape, exposes a click-anywhere
/// stop and a >3 pt drag.
private struct RecordingHUDView: View {

    let holder: WindowHolder

    @ObservedObject private var meter = RecordingLevelMeter.shared
    /// Cumulative drag-translation since gesture start. Used to (a)
    /// distinguish tap-from-drag and (b) repeatedly nudge the NSPanel
    /// origin in `onChanged`.
    @State private var dragAccumulated: CGSize = .zero
    /// Drives the entry "leak from a single point" animation.
    @State private var appeared = false
    /// Mouse hover for the gentle scale-up affordance.
    @State private var hovering = false

    var body: some View {
        let level = max(meter.micLevel, meter.systemLevel)

        // TimelineView gives us a steady 60 Hz tick so the shape
        // morph + breathing wobble keep moving even during silence.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            BlobShape(time: t, level: CGFloat(level))
                .fill(
                    // Three-stop radial gradient: hot cherry core →
                    // rose-red mid → deep crimson rim. All in the red
                    // family, no orange.
                    RadialGradient(
                        colors: [
                            Color(red: 0.95, green: 0.30, blue: 0.36),
                            Color(red: 0.78, green: 0.16, blue: 0.24),
                            Color(red: 0.52, green: 0.08, blue: 0.14)
                        ],
                        center: UnitPoint(x: 0.38, y: 0.32),
                        startRadius: 6,
                        endRadius: 60
                    )
                )
                .overlay(
                    // Faint top-rim highlight so the blob reads
                    // volumetric instead of as a flat sticker.
                    BlobShape(time: t, level: CGFloat(level))
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                // Glow + drop shadow live on the wrapping frame so the
                // shape itself stays crisp at any scale.
                .frame(width: 64, height: 64)
                .shadow(color: Color(red: 0.85, green: 0.20, blue: 0.28).opacity(0.55),
                        radius: 18 + 10 * CGFloat(level), x: 0, y: 6)
                .shadow(color: Color(red: 0.55, green: 0.10, blue: 0.18).opacity(0.35),
                        radius: 6, x: 0, y: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Entry animation: blob "leaks out" from a tiny dot in the
        // centre. Spring keeps it organic — no hard endpoint snap.
        .scaleEffect((appeared ? 1.0 : 0.05) * (hovering ? 1.12 : 1.0))
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: appeared)
        .animation(.easeOut(duration: 0.22), value: hovering)
        .onAppear { appeared = true }
        .onHover { isOver in
            hovering = isOver
            if isOver {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
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

// MARK: - Shape morphing

/// 12 control points distributed evenly around a circle. Each shape
/// in the morph cycle is a 12-element array of radius multipliers
/// (1.0 = sit on the base radius, <1.0 = pull toward the centre,
/// >1.0 = push away). The shape itself is drawn as a closed loop
/// of quadratic Béziers between successive midpoints, with each
/// control point as the curve's control — gives continuous tangents
/// at every joint.
private enum ShapeTemplate {
    /// Lazy organic — varying radius, no symmetry.
    static let blob: [CGFloat] = [
        1.05, 0.92, 1.02, 0.95, 1.08, 0.94,
        0.98, 1.06, 0.92, 1.04, 0.96, 1.00
    ]
    /// 6-pointed star: alternating peak / valley.
    static let star: [CGFloat] = [
        1.18, 0.62, 1.18, 0.62, 1.18, 0.62,
        1.18, 0.62, 1.18, 0.62, 1.18, 0.62
    ]
    /// Hexagon: every other point sits slightly inset so the shape
    /// reads as 6 corners with mid-edges between them.
    static let hexagon: [CGFloat] = [
        1.05, 0.93, 1.05, 0.93, 1.05, 0.93,
        1.05, 0.93, 1.05, 0.93, 1.05, 0.93
    ]
    /// Squircle / soft square: 4 broad corners with flatter sides.
    static let squircle: [CGFloat] = [
        1.10, 0.92, 0.85, 0.92, 1.10, 0.92,
        0.85, 0.92, 1.10, 0.92, 0.85, 0.92
    ]

    /// The wobble amplitude scales down on near-rigid shapes so they
    /// stay legible as a star / hexagon instead of mushing back into
    /// a generic blob.
    static let cycle: [(points: [CGFloat], wobbleScale: CGFloat)] = [
        (blob,     1.00),
        (star,     0.30),
        (hexagon,  0.45),
        (squircle, 0.45)
    ]

    /// One full pass through all four templates.
    static let cycleDurationSec: Double = 8.0
}

private struct BlobShape: Shape {
    var time: TimeInterval
    var level: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2 * 0.78
        let pointCount = 12

        // Pick the two templates we're currently morphing between
        // and our 0…1 progress through that morph.
        let cycle = ShapeTemplate.cycle
        let phase = time.truncatingRemainder(dividingBy: ShapeTemplate.cycleDurationSec)
                  / ShapeTemplate.cycleDurationSec
        let scaled = phase * Double(cycle.count)
        let idx = Int(scaled) % cycle.count
        let nextIdx = (idx + 1) % cycle.count
        var local = scaled - Double(idx)
        // Smoothstep keeps the curve soft at the joins so the shape
        // doesn't visibly accelerate at integer boundaries.
        local = local * local * (3 - 2 * local)

        let from = cycle[idx]
        let to   = cycle[nextIdx]
        let wobbleScale = lerp(from.wobbleScale, to.wobbleScale, CGFloat(local))

        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * 2 * .pi - .pi / 2
            let baseR = lerp(from.points[i], to.points[i], CGFloat(local))

            // Per-point breathing wobble. Frequencies are deliberately
            // close-but-not-commensurate so the blob never settles
            // into a repeating loop.
            let phase1 = time * 1.6 + Double(i) * 0.71
            let phase2 = time * 2.7 + Double(i) * 1.23
            let wobble = (sin(phase1) * 0.05 + sin(phase2) * 0.03) * Double(wobbleScale)

            // Audio level pushes the radius outward. Phase rotates
            // per-point so loud audio bulges different sides at
            // different times rather than uniformly inflating.
            let levelPhase = sin(time * 2.1 + Double(i) * 1.2)
            let levelBoost = Double(level) * 0.32 * (0.5 + 0.5 * levelPhase)

            let r = baseRadius * (baseR + CGFloat(wobble) + CGFloat(levelBoost))
            let px = center.x + CGFloat(cos(angle)) * r
            let py = center.y + CGFloat(sin(angle)) * r
            points.append(CGPoint(x: px, y: py))
        }

        var path = Path()
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

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    var animatableData: CGFloat {
        get { level }
        set { level = newValue }
    }
}
