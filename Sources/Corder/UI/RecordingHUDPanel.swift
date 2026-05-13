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
    /// True while a recording is in progress and we'd otherwise want the
    /// floating HUD on screen. Tracked separately from the actual window
    /// presence so the Library-suppression toggle can re-show it on
    /// demand without re-asking the recording state machine.
    private var wantsVisible: Bool = false
    /// True while the Library window is the key window. In that case the
    /// floating HUD is redundant — the inline blob in the page covers
    /// the start/stop affordance — so we hide it. Restored as soon as
    /// the user switches focus away from the Library.
    private var librarySuppressed: Bool = false

    /// Total panel size. The blob itself only occupies ~60 % of this;
    /// the rest is breathing room for the radial glow + the hover
    /// scale-up so neither ever clips at the panel boundary.
    private static let windowSize: CGFloat = 110

    private static let originXKey = "Corder.HUDOrigin.x"
    private static let originYKey = "Corder.HUDOrigin.y"

    func show() {
        wantsVisible = true
        if librarySuppressed { return }
        ensureVisible()
    }

    private func ensureVisible() {
        if window?.isVisible == true { return }
        // Host the SwiftUI view inside HUDHostingView so the pointing-hand
        // cursor sticks even though `isMovableByWindowBackground` would
        // otherwise have AppKit's drag handler reset it. addCursorRect
        // (declared inside the subclass's resetCursorRects) is the
        // documented AppKit mechanism for view-level cursor declarations.
        let hostingView = HUDHostingView(rootView:
            RecordingHUDView(onTap: {
                Task { @MainActor in
                    await RecordingController.shared.stopRecording()
                }
            })
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.windowSize, height: Self.windowSize)

        let panel = ScreenClampingPanel(
            contentRect: hostingView.bounds,
            // .borderless: no chrome.
            // .nonactivatingPanel: clicking the HUD doesn't steal focus
            //   from the app the user is actually working in.
            // .utilityWindow: lets it persist while another app is
            //   front-most.
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                       // we draw our own glow
        // Native AppKit drag — reliable, no jitter, no conflict with
        // the SwiftUI tap gesture used for stop. We previously drove
        // drag from a SwiftUI DragGesture(minimumDistance: 0) so the
        // blob could deform against pointer velocity, but the tap/drag
        // threshold made the panel feel jumpy and the inertia effect
        // wasn't worth that price.
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Float over every Space + persist when the user switches Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Mouse-moved events are off by default on NSPanel — we need them on
        // so HUDHostingView's tracking area actually fires mouseMoved /
        // cursorUpdate. Without this, .nonactivatingPanel silently swallows
        // every mouse-moved event and the pointing-hand cursor never appears.
        panel.acceptsMouseMovedEvents = true

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
        wantsVisible = false
        if let panel = window {
            saveOrigin(panel.frame.origin)
        }
        window?.orderOut(nil)
        window = nil
        delegate = nil
        RecordingLevelMeter.shared.reset()
    }

    /// Called by `LibraryWindow` when its window becomes / resigns key.
    /// While suppressed, the floating HUD is hidden even during a
    /// recording — the user is looking at the Library, where the inline
    /// blob covers the same affordance.
    func setLibrarySuppressed(_ suppressed: Bool) {
        guard librarySuppressed != suppressed else { return }
        librarySuppressed = suppressed
        if suppressed {
            if let panel = window { saveOrigin(panel.frame.origin) }
            window?.orderOut(nil)
        } else if wantsVisible {
            ensureVisible()
        }
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

/// NSHostingView subclass that declares a pointing-hand cursor rect
/// over its full bounds via the documented AppKit mechanism
/// (`resetCursorRects` + `addCursorRect`). This wins against the
/// background-drag handler installed by `isMovableByWindowBackground`
/// on the floating panel — push/set-based approaches lose that fight
/// on .nonactivatingPanel windows.
///
/// Tracking area + cursorUpdate / mouseMoved overrides are kept as a
/// safety net for cases where AppKit doesn't query cursor rects (rare,
/// but cheap to defend against).
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    private var trackingArea: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

/// NSPanel subclass that clamps every move/resize to the visible
/// frame of whichever screen the panel currently sits on (closest
/// screen by centre, when in transition). Without this,
/// `isMovableByWindowBackground` lets the user drag the HUD past
/// the screen edge until it's no longer visible — there's no
/// frameless-window equivalent of AppKit's titlebar clamp.
final class ScreenClampingPanel: NSPanel {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(clamped(frameRect), display: flag)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(clamped(frameRect), display: flag, animate: animate)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        let proposed = NSRect(origin: point, size: frame.size)
        super.setFrameOrigin(clamped(proposed).origin)
    }
    private func clamped(_ rect: NSRect) -> NSRect {
        // Pick the screen whose visibleFrame contains the proposed
        // centre point; fall back to main if the centre is outside
        // every screen (multi-monitor wraparound, sleep/wake races).
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(centre) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return rect }
        var clamped = rect
        if clamped.minX < visible.minX { clamped.origin.x = visible.minX }
        if clamped.minY < visible.minY { clamped.origin.y = visible.minY }
        if clamped.maxX > visible.maxX { clamped.origin.x = visible.maxX - clamped.width }
        if clamped.maxY > visible.maxY { clamped.origin.y = visible.maxY - clamped.height }
        return clamped
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

/// Liquid Blob HUD body. Pulls the live level from RecordingLevelMeter,
/// renders a Canvas-based morphing shape, exposes a click-anywhere
/// stop. Drag is handled by the host window (`isMovableByWindowBackground`
/// on the floating panel; not applicable inside the Library window).
struct RecordingHUDView: View {

    /// Called when the user clicks the blob. Caller decides what that
    /// means — the floating HUD wires it to stop-recording; the Library
    /// embedding wires it to a state-aware toggle (start when idle,
    /// stop when recording).
    let onTap: () -> Void

    @ObservedObject private var meter = RecordingLevelMeter.shared
    /// Lets the view know when a recording is actually in flight — used
    /// to decide whether the blob is in "idle ambient" mode (subtle
    /// baseline morph, palette frozen on green) or in "recording" mode
    /// (audio-reactive shape + level boost + palette flips on speech).
    /// Only matters for the inline embedding inside the Library window;
    /// the floating HUD panel is only ever shown during a recording.
    @ObservedObject private var ctx: AppContext = .shared
    /// Drives the entry "leak from a single point" animation.
    @State private var appeared = false
    /// Whether the cursor is currently over the blob. Drives the gentle
    /// scale-up affordance.
    @State private var hovering = false
    /// True when the SwiftUI view's host window is on-screen and not
    /// fully occluded. Drives `TimelineView.paused`. We default to
    /// `true` so the first frame paints before the occlusion
    /// notification arrives — without that, the blob would render as
    /// frozen-then-jump on first appearance.
    @State private var visible = true
    var body: some View {
        let level = max(meter.micLevel, meter.systemLevel)
        // Peak over the last ~0.5 s ring buffer, scaled so a normal
        // speaking voice (peak ≈ 0.25-0.35) reads as full activity
        // and a quiet room (peak ≈ 0.02-0.05) reads as zero.
        let recentPeak = meter.history.max() ?? 0
        let audioActivity = CGFloat(min(1, max(0, (recentPeak - 0.05) * 6)))

        // At idle (no recording) the blob is a near-perfect circle with
        // only a faint breathing wobble — no morph through the star /
        // hexagon templates, no jitter. During a recording the audio
        // drives the shape directly.
        let isRecording = ctx.recordingState != .idle
        let shapeActivity: CGFloat = isRecording ? audioActivity : 0

        // Palette is bound directly to recording state — red while a
        // recording is in flight (whether the blob is the floating HUD
        // or the inline one in the Library), green at rest. Threshold-
        // based flipping made the floating HUD strobe colours mid-call
        // when audio dipped; that's the wrong signal for "we're still
        // recording, just nobody's talking at this exact moment".
        let palette: BlobPalette = isRecording ? .activeRed : .silentGreen

        // Frame-rate is state-driven so the blob doesn't burn CPU
        // 60× / sec when nothing on screen is meaningfully changing:
        //   • Recording:     30 Hz — fast enough to track voice ticks.
        //   • Idle, hovered:  20 Hz — gentle "I'm awake" breathe.
        //   • Idle, resting:   6 Hz — just enough to look alive.
        // Drops the always-on idle cost by ~10× vs the previous 60 Hz.
        // `paused: !visible` halts the timeline outright when the host
        // window is occluded (Library minimised, another app full-
        // screen, etc.) — see the `onReceive` further down.
        let fps: Double = isRecording ? 30 : (hovering ? 20 : 6)
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !visible)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            blobLayer(time: t, level: level, activity: shapeActivity,
                      palette: palette)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Entry animation: blob "leaks out" from a tiny dot in the
        // centre. Spring keeps it organic — no hard endpoint snap.
        .scaleEffect((appeared ? 1.0 : 0.05) * (hovering ? 1.08 : 1.0))
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: appeared)
        .animation(.easeOut(duration: 0.22), value: hovering)
        // Fast palette change on recording-state transitions. Scoped to
        // `isRecording` so nothing else animates with it.
        .animation(.easeInOut(duration: 0.10), value: isRecording)
        .onAppear { appeared = true }
        // onContinuousHover keeps re-applying the cursor on every
        // mouse movement inside the view.
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
        // Drag is owned by AppKit (isMovableByWindowBackground=true);
        // we only register a tap for stop. A tap on an NSPanel that's
        // also draggable still fires cleanly because AppKit only takes
        // the mouse-down event for drag once the cursor actually moves.
        .onTapGesture { onTap() }
        // Window occlusion → pause TimelineView. AppKit posts this
        // whenever a window is hidden behind another (front-most
        // full-screen app, Mission Control, Library window
        // minimised), and again when it's exposed. We can't easily
        // get the host window from inside the SwiftUI body so we just
        // check ALL windows — if the blob's host is among the visible
        // ones, we animate; otherwise pause. Cheap: NSApp.windows
        // returns a few items, comparison is by reference identity.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            visible = Self.anyHostWindowVisible()
        }
        .help("Click to start or stop recording")
    }

    /// True if any window currently in `NSApp.windows` is on-screen
    /// AND not occluded. Used as the gate for blob animation —
    /// pausing the TimelineView when both the floating panel and the
    /// Library window are off-screen.
    private static func anyHostWindowVisible() -> Bool {
        for win in NSApplication.shared.windows {
            if win.isVisible && win.occlusionState.contains(.visible) {
                return true
            }
        }
        return false
    }

    @ViewBuilder
    private func blobLayer(time: TimeInterval, level: Float, activity: CGFloat,
                           palette: BlobPalette) -> some View {
        BlobShape(time: time, level: CGFloat(level), activity: activity)
            .fill(
                RadialGradient(
                    colors: palette.fillStops,
                    center: UnitPoint(x: 0.38, y: 0.32),
                    startRadius: 6,
                    endRadius: 60
                )
            )
            .overlay(
                BlobShape(time: time, level: CGFloat(level), activity: activity)
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

}

/// Two named palettes the view snaps between based on detected
/// speech activity. The flip is hysteresis-gated and animated over
/// ~80 ms; no value interpolation, no crossfade.
private struct BlobPalette {
    let fillStops: [Color]
    let glowOuter: Color
    let glowInner: Color

    /// Idle / silent — brand green.
    static let silentGreen = BlobPalette(
        fillStops: [
            Color(red: 0.18, green: 0.66, blue: 0.40),    // bright leaf
            Color(red: 0.06, green: 0.49, blue: 0.27),    // brand #0e7c44
            Color(red: 0.03, green: 0.30, blue: 0.16)     // deep forest
        ],
        glowOuter: Color(red: 0.10, green: 0.60, blue: 0.34),
        glowInner: Color(red: 0.04, green: 0.34, blue: 0.18)
    )

    /// Active speech — bright crimson.
    static let activeRed = BlobPalette(
        fillStops: [
            Color(red: 0.95, green: 0.30, blue: 0.36),
            Color(red: 0.78, green: 0.16, blue: 0.24),
            Color(red: 0.52, green: 0.08, blue: 0.14)
        ],
        glowOuter: Color(red: 0.85, green: 0.20, blue: 0.28),
        glowInner: Color(red: 0.55, green: 0.10, blue: 0.18)
    )
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
        // squircles) and the wobble amplitude (very faint at silence
        // so the resting blob reads as calm, full-amplitude when
        // someone is speaking).
        let act = max(0, min(1, activity))
        // Tiny baseline wobble at idle (just enough to breathe), full
        // amplitude under speech.
        let wobbleAmplitude = 0.15 + 0.85 * act

        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * 2 * .pi - .pi / 2
            let morphedR = lerp(from.points[i], to.points[i], CGFloat(local))
            // At act=0 we lock onto a perfect circle (all radii = 1.0)
            // so the resting blob reads as truly round; the "blob"
            // template only kicks in as activity ramps up.
            let circleR: CGFloat = 1.0
            let baseR = lerp(circleR, morphedR, act)

            // Base breathing wobble — present even at activity=0 so
            // the resting blob never looks frozen. Amplitude is tiny
            // (≈ 1 % radius variation) so the shape stays visibly round.
            // Frequencies are close-but-not-commensurate so it never
            // settles into a repeating loop.
            let phase1 = time * 1.6 + Double(i) * 0.71
            let phase2 = time * 2.7 + Double(i) * 1.23
            let wobbleRaw = sin(phase1) * 0.05 + sin(phase2) * 0.03
            let baseWobble = wobbleRaw * Double(wobbleScaleMorphed) * Double(wobbleAmplitude)

            // High-frequency jitter that fades in with activity *and*
            // amplifies with instantaneous audio level — each spoken
            // syllable causes a visible twitch, not just a slow inflate.
            let jitterPhase1 = time * 7.5 + Double(i) * 1.13
            let jitterPhase2 = time * 13.1 + Double(i) * 2.37
            let jitterAmp = (0.08 + 1.0 * Double(level)) * Double(act)
            let jitter = (sin(jitterPhase1) * 0.07 + sin(jitterPhase2) * 0.05) * jitterAmp
            let wobble = baseWobble + jitter

            // Audio level pushes the radius outward. Phase rotates
            // per-point so loud audio bulges different sides at
            // different times rather than uniformly inflating. Multiplier
            // was 0.55 — bumped to 1.0 so deformation tracks volume
            // visibly, the way the user wants it to read as "this
            // blob is reacting to me".
            let levelPhase = sin(time * 2.1 + Double(i) * 1.2)
            let levelBoost = Double(level) * 1.0 * (0.5 + 0.5 * levelPhase)

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

    /// Two animatable scalars — level + activity — kept here so the
    /// Canvas redraws smoothly as RecordingLevelMeter publishes new
    /// values instead of snapping.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(level, activity) }
        set {
            level = newValue.first
            activity = newValue.second
        }
    }
}
