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
    /// Strong ref so the delegate isn't deallocated while the panel
    /// is on screen — NSPanel.delegate is `weak`.
    private var delegate: HUDWindowDelegate?

    /// Total panel size. The blob itself only occupies ~60 % of this;
    /// the rest is breathing room for the radial glow + the hover
    /// scale-up so neither ever clips at the panel boundary.
    private static let windowSize: CGFloat = 110

    private static let originXKey = "Corder.HUDOrigin.x"
    private static let originYKey = "Corder.HUDOrigin.y"

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
        // Drag is driven by a SwiftUI DragGesture so we can react to
        // the motion (blob deforms against the velocity vector). The
        // native AppKit drag is therefore disabled — there's no way
        // to observe its velocity from SwiftUI.
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        // Float over every Space + persist when the user switches Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panelHolder.panel = panel

        // Persisted position from a previous session, falling back to
        // the bottom-right corner of the main screen if there's nothing
        // saved yet (or if the saved point is on a screen that's no
        // longer attached — happens when the user undocks an external
        // monitor between sessions).
        let origin = restoredOrigin(for: panel) ?? defaultOrigin(for: panel)
        panel.setFrameOrigin(origin)

        // Hook windowDidMove so dragging the HUD persists immediately
        // — no need to wait for hide() to flush the new position.
        let del = HUDWindowDelegate { [weak self] frame in
            self?.saveOrigin(frame.origin)
        }
        panel.delegate = del
        delegate = del

        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        if let panel = window {
            saveOrigin(panel.frame.origin)
        }
        window?.orderOut(nil)
        window = nil
        delegate = nil
        RecordingLevelMeter.shared.reset()
    }

    // MARK: - Position persistence

    private func saveOrigin(_ p: NSPoint) {
        UserDefaults.standard.set(Double(p.x), forKey: Self.originXKey)
        UserDefaults.standard.set(Double(p.y), forKey: Self.originYKey)
    }

    private func restoredOrigin(for panel: NSPanel) -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil,
              defaults.object(forKey: Self.originYKey) != nil else {
            return nil
        }
        let p = NSPoint(
            x: defaults.double(forKey: Self.originXKey),
            y: defaults.double(forKey: Self.originYKey)
        )
        // Reject the saved point if no screen contains it (the user
        // unplugged the monitor it was on). Falls back to the default
        // bottom-right corner of the main screen.
        let probe = NSRect(x: p.x, y: p.y,
                           width: panel.frame.width, height: panel.frame.height)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) else {
            return nil
        }
        return p
    }

    private func defaultOrigin(for panel: NSPanel) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let f = screen.visibleFrame
        let w = panel.frame.width
        let h = panel.frame.height
        // Bottom-right corner with a small breathing margin so the
        // glow never hits the screen edge.
        return NSPoint(x: f.maxX - w - 16, y: f.minY + 16)
    }
}

/// NSPanel.delegate hook — fires on every move, lets us persist the
/// HUD's last-known origin without the SwiftUI view having to know
/// about UserDefaults.
private final class HUDWindowDelegate: NSObject, NSWindowDelegate {
    let onMove: (NSRect) -> Void
    init(onMove: @escaping (NSRect) -> Void) {
        self.onMove = onMove
    }
    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        onMove(w.frame)
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
    /// Drives the entry "leak from a single point" animation.
    @State private var appeared = false
    /// Mouse hover for the gentle scale-up affordance.
    @State private var hovering = false

    // Drag tracking. We measure pointer velocity in pt/s, normalize
    // it (1000 pt/s ≈ 1.0), low-pass filter it, then feed the result
    // into BlobShape so the blob deforms against the motion vector
    // — the side facing the direction of travel pulls in, the trailing
    // side stretches out. A spring on release snaps it back to neutral.
    @State private var dragVelocity: CGSize = .zero
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastDragTime: Date?

    var body: some View {
        let level = max(meter.micLevel, meter.systemLevel)
        // Peak over the last ~0.5 s ring buffer, scaled so a normal
        // speaking voice (peak ≈ 0.25-0.35) reads as full activity
        // and a quiet room (peak ≈ 0.02-0.05) reads as zero. Below
        // the floor the blob freezes back into a static shape with
        // only a faint breath of wobble.
        let recentPeak = meter.history.max() ?? 0
        let activity = CGFloat(min(1, max(0, (recentPeak - 0.05) * 6)))

        // Three palettes, one stacked layer each. Opacity is the
        // crossfade driver:
        //   • silent (green)    when not hovering AND no speech
        //   • active (red)      when not hovering AND speech detected
        //   • hover  (dark red) whenever the cursor is over the blob,
        //                      regardless of speech.
        let hoverOpacity: CGFloat = hovering ? 1.0 : 0.0
        let activeOpacity = (1 - hoverOpacity) * activity
        let silentOpacity = (1 - hoverOpacity) * (1 - activity)

        // TimelineView gives us a steady 60 Hz tick so the breathing
        // wobble keeps moving even when audio is flat.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                blobLayer(time: t, level: level, activity: activity,
                          dragVx: dragVelocity.width, dragVy: dragVelocity.height,
                          palette: greenPalette)
                    .opacity(silentOpacity)
                blobLayer(time: t, level: level, activity: activity,
                          dragVx: dragVelocity.width, dragVy: dragVelocity.height,
                          palette: activeRedPalette)
                    .opacity(activeOpacity)
                blobLayer(time: t, level: level, activity: activity,
                          dragVx: dragVelocity.width, dragVy: dragVelocity.height,
                          palette: hoverDarkRedPalette)
                    .opacity(hoverOpacity)
            }
            .animation(.easeInOut(duration: 0.28), value: hovering)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Entry animation: blob "leaks out" from a tiny dot in the
        // centre. Spring keeps it organic — no hard endpoint snap.
        .scaleEffect((appeared ? 1.0 : 0.05) * (hovering ? 1.12 : 1.0))
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: appeared)
        .animation(.easeOut(duration: 0.22), value: hovering)
        .onAppear { appeared = true }
        // onContinuousHover keeps re-applying the cursor on every
        // mouse movement inside the view. Plain .onHover only fires
        // at enter/exit, and on a .nonactivatingPanel that single
        // .set() call gets clobbered by AppKit before it sticks.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !hovering { hovering = true }
                NSCursor.pointingHand.set()
            case .ended:
                hovering = false
                NSCursor.arrow.set()
            }
        }
        .contentShape(Rectangle())
        // Drag and tap share one DragGesture. The 4 pt threshold in
        // onEnded splits them: short clicks become stop, anything
        // longer was a drag and we just spring the velocity back to
        // zero so the blob settles back into its neutral shape.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Move the panel itself — we drive the position
                    // from SwiftUI here so we can also observe velocity.
                    let dx = value.translation.width - lastDragTranslation.width
                    let dy = value.translation.height - lastDragTranslation.height
                    if abs(value.translation.width) + abs(value.translation.height) > 1 {
                        moveWindow(dx: dx, dy: dy)
                    }

                    // Velocity in pt/s, normalized so a brisk drag
                    // (≈1000 pt/s) maps to ~1.0. Low-pass filter
                    // (alpha=0.35) smooths out single-frame spikes.
                    let now = Date()
                    if let last = lastDragTime {
                        let dt = now.timeIntervalSince(last)
                        if dt > 0.001 {
                            let scale: CGFloat = 1.0 / 1000.0
                            let rawVx = (dx / CGFloat(dt)) * scale
                            let rawVy = (dy / CGFloat(dt)) * scale
                            let alpha: CGFloat = 0.35
                            dragVelocity.width = dragVelocity.width * (1 - alpha) + rawVx * alpha
                            dragVelocity.height = dragVelocity.height * (1 - alpha) + rawVy * alpha
                        }
                    }
                    lastDragTranslation = value.translation
                    lastDragTime = now
                }
                .onEnded { value in
                    let total = abs(value.translation.width) + abs(value.translation.height)
                    lastDragTranslation = .zero
                    lastDragTime = nil
                    if total < 4 {
                        // Treat as a tap — barely moved, never really
                        // had a velocity. Don't bother springing.
                        dragVelocity = .zero
                        stopRecording()
                    } else {
                        // Spring the deformation back to neutral. A
                        // little overshoot (dampingFraction 0.55)
                        // gives the blob a satisfying jiggle on
                        // settle.
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                            dragVelocity = .zero
                        }
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

    @ViewBuilder
    private func blobLayer(time: TimeInterval, level: Float, activity: CGFloat,
                           dragVx: CGFloat, dragVy: CGFloat, palette: BlobPalette) -> some View {
        BlobShape(time: time, level: CGFloat(level), activity: activity,
                  dragVx: dragVx, dragVy: dragVy)
            .fill(
                RadialGradient(
                    colors: palette.fillStops,
                    center: UnitPoint(x: 0.38, y: 0.32),
                    startRadius: 6,
                    endRadius: 60
                )
            )
            .overlay(
                BlobShape(time: time, level: CGFloat(level), activity: activity,
                          dragVx: dragVx, dragVy: dragVy)
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
            .frame(width: 43, height: 43)
            .shadow(color: palette.glowOuter.opacity(0.55),
                    radius: 14 + 8 * CGFloat(level), x: 0, y: 4)
            .shadow(color: palette.glowInner.opacity(0.35),
                    radius: 5, x: 0, y: 2)
    }

    /// Default state: brand green. Recording is happening, the user
    /// shouldn't feel the blob is "danger-coloured" until they hover
    /// to indicate intent to stop.
    private var greenPalette: BlobPalette {
        BlobPalette(
            fillStops: [
                Color(red: 0.18, green: 0.66, blue: 0.40),    // bright leaf
                Color(red: 0.06, green: 0.49, blue: 0.27),    // brand #0e7c44
                Color(red: 0.03, green: 0.30, blue: 0.16)     // deep forest
            ],
            glowOuter: Color(red: 0.10, green: 0.60, blue: 0.34),
            glowInner: Color(red: 0.04, green: 0.34, blue: 0.18)
        )
    }

    /// Active speech: bright crimson, draws attention. Same hue as
    /// the previous "hover" state — the role moved to "someone is
    /// talking right now" instead.
    private var activeRedPalette: BlobPalette {
        BlobPalette(
            fillStops: [
                Color(red: 0.95, green: 0.30, blue: 0.36),
                Color(red: 0.78, green: 0.16, blue: 0.24),
                Color(red: 0.52, green: 0.08, blue: 0.14)
            ],
            glowOuter: Color(red: 0.85, green: 0.20, blue: 0.28),
            glowInner: Color(red: 0.55, green: 0.10, blue: 0.18)
        )
    }

    /// Hover state: deep wine — clearly distinguished from the active
    /// crimson so the user can tell whether the blob is reacting to
    /// audio or to their cursor.
    private var hoverDarkRedPalette: BlobPalette {
        BlobPalette(
            fillStops: [
                Color(red: 0.62, green: 0.10, blue: 0.16),
                Color(red: 0.44, green: 0.06, blue: 0.12),
                Color(red: 0.26, green: 0.02, blue: 0.06)
            ],
            glowOuter: Color(red: 0.50, green: 0.08, blue: 0.14),
            glowInner: Color(red: 0.30, green: 0.04, blue: 0.10)
        )
    }

    private func stopRecording() {
        Task { @MainActor in
            await RecordingController.shared.stopRecording()
        }
    }
}

/// Bundle of colours that define a single state of the blob —
/// recording (green) vs about-to-stop (red). Kept as a value type so
/// the SwiftUI body can crossfade between two stacked copies without
/// any imperative state plumbing.
private struct BlobPalette {
    let fillStops: [Color]
    let glowOuter: Color
    let glowInner: Color
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
    static let cycleDurationSec: Double = 4.0
}

private struct BlobShape: Shape {
    var time: TimeInterval
    var level: CGFloat
    /// 0 = silence (frozen on the static blob template, faint
    /// breath only); 1 = active speech (full morph through the
    /// shape cycle, full-amplitude wobble).
    var activity: CGFloat
    /// Pointer velocity components in normalised units (±1 ≈ 1000 pt/s).
    /// Each control point's radius is shifted by a projection of this
    /// vector onto its own outward direction, so the blob trails
    /// behind the cursor while being dragged.
    var dragVx: CGFloat
    var dragVy: CGFloat

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
        let wobbleScaleMorphed = lerp(from.wobbleScale, to.wobbleScale, CGFloat(local))

        // Activity gates two things at once: the morph amplitude
        // (at 0 we drop fully back to the canonical blob template,
        // at 1 we let the cycle fully express stars / hexagons /
        // squircles) and the wobble amplitude (0 = a faint 0.2×
        // breath so the shape isn't visibly frozen, 1 = full wobble).
        let act = max(0, min(1, activity))
        let wobbleAmplitude = 0.2 + 0.8 * act

        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * 2 * .pi - .pi / 2
            let morphedR = lerp(from.points[i], to.points[i], CGFloat(local))
            let staticR = ShapeTemplate.blob[i]
            let baseR = lerp(staticR, morphedR, act)

            // Base breathing wobble — present even at activity=0 so
            // the blob never looks frozen. Frequencies are deliberately
            // close-but-not-commensurate so it never settles into a
            // repeating loop.
            let phase1 = time * 1.6 + Double(i) * 0.71
            let phase2 = time * 2.7 + Double(i) * 1.23
            let wobbleRaw = sin(phase1) * 0.05 + sin(phase2) * 0.03
            let baseWobble = wobbleRaw * Double(wobbleScaleMorphed) * Double(wobbleAmplitude)

            // High-frequency jitter that fades in with activity. This
            // is what makes the blob look "agitated" when someone is
            // actually speaking — the slow breath alone reads too calm.
            let jitterPhase1 = time * 7.5 + Double(i) * 1.13
            let jitterPhase2 = time * 13.1 + Double(i) * 2.37
            let jitter = (sin(jitterPhase1) * 0.07 + sin(jitterPhase2) * 0.05) * Double(act)
            let wobble = baseWobble + jitter

            // Audio level pushes the radius outward. Phase rotates
            // per-point so loud audio bulges different sides at
            // different times rather than uniformly inflating.
            let levelPhase = sin(time * 2.1 + Double(i) * 1.2)
            let levelBoost = Double(level) * 0.55 * (0.5 + 0.5 * levelPhase)

            // Drag deformation: each point moves in the direction
            // OPPOSITE to the panel's motion. Project the negative
            // velocity vector onto the point's own outward unit
            // vector — points facing the direction of travel get
            // a negative offset (they pull in), trailing points
            // get a positive offset (they stretch out). 0.22 is the
            // amplitude cap; at full velocity (≈1000 pt/s) the
            // deformation reaches ±22 % of base radius.
            let unitX = cos(angle)
            let unitY = sin(angle)
            let dragProj = -unitX * Double(dragVx) - unitY * Double(dragVy)
            let dragDeform = dragProj * 0.22

            let r = baseRadius * (baseR + CGFloat(wobble) + CGFloat(levelBoost) + CGFloat(dragDeform))
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

    /// Four animatable scalars — level, activity, dragVx, dragVy —
    /// packed into nested AnimatablePairs. The spring on drag-end
    /// rides on dragVx/dragVy; level + activity continue to update
    /// continuously from RecordingLevelMeter.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(level, activity),
                AnimatablePair(dragVx, dragVy)
            )
        }
        set {
            level = newValue.first.first
            activity = newValue.first.second
            dragVx = newValue.second.first
            dragVy = newValue.second.second
        }
    }
}
