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
    /// Drives the blob's reverse spring on stop. Owned here, observed
    /// by the hosted `RecordingHUDView`. `hide()` flips `dismissing`
    /// true so the blob shrinks back to a transparent dot before the
    /// panel is actually orderOut'd.
    private let presentation = HUDPresentation()
    /// Strong ref so the delegate isn't deallocated while the panel
    /// is on screen — NSPanel.delegate is `weak`.
    private var delegate: HUDWindowDelegate?
    /// Local event monitor that forces `.pointingHand` whenever the
    /// cursor sits over the floating panel. Required because the panel
    /// is `.nonactivatingPanel` — macOS reads cursor preference from
    /// the window UNDER the floating panel for non-key windows, which
    /// means our addCursorRect / push() are silently ignored. The
    /// local monitor runs on every mouseMoved event in our process and
    /// can override that decision by `.set()`-ing on each tick.
    private var cursorMonitor: Any?
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

    /// Total panel size. The blob itself only occupies ~40 % of this;
    /// the rest is breathing room for the contact shadow + the hover
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
        // Fresh entry each time: clear any leftover dismiss flag so the
        // blob springs IN (onAppear) rather than starting collapsed.
        presentation.dismissing = false
        let hostingView = HUDHostingView(rootView:
            RecordingHUDView(presentation: presentation, onTap: {
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
        // `isMovableByWindowBackground` was `true` for drag, but AppKit's
        // drag-vs-click recognition added ~500ms of latency to the Stop
        // tap (mouseDown → AppKit waits for movement / timeout →
        // mouseUp → SwiftUI tap gesture). Stop has to feel instant, so
        // we disable AppKit drag entirely. The panel still has a
        // persisted origin (`Corder.HUDOrigin.x/y`); if drag becomes
        // important again, reintroduce it via a manual mouseDragged
        // override that only calls `performDrag` after the cursor
        // actually moves a few px.
        panel.isMovableByWindowBackground = false
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

        installCursorMonitor()
    }

    func hide() {
        wantsVisible = false
        guard let panel = window else {
            RecordingLevelMeter.shared.reset()
            return
        }
        saveOrigin(panel.frame.origin)
        // Reverse the entry spring: tell the view to collapse back to a
        // tiny transparent dot, then tear the panel down once that
        // animation has had time to land (matches the spring-in the
        // user asked for — "так же уходит когда запись останавливаю").
        presentation.dismissing = true
        window = nil          // re-entrancy guard; `panel` keeps it alive
        removeCursorMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            panel.orderOut(nil)
            self?.delegate = nil
            RecordingLevelMeter.shared.reset()
        }
    }

    /// No-op stubs left over from an earlier experiment that tried to
    /// force `.pointingHand` over the floating panel via a process-
    /// wide mouseMoved monitor. That approach didn't work for
    /// `.nonactivatingPanel` (WindowServer ignores our `.set()` on
    /// those), so we accept the system arrow on the floating blob
    /// for now. The inline blob in LibraryWindow still gets the
    /// pointing-hand cursor through `addCursorRect`.
    private func installCursorMonitor() { /* intentionally empty */ }
    private func removeCursorMonitor() {
        if let m = cursorMonitor {
            NSEvent.removeMonitor(m)
            cursorMonitor = nil
        }
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
    /// `true` while we've pushed `.pointingHand` onto AppKit's cursor
    /// stack. mouseEntered pushes once, mouseExited pops once — both
    /// gated by this flag so duplicate events (tracking-area + window-
    /// level forwarding both fire mouseEntered) don't stack up.
    private var pushedPointingHand = false
    /// Drag state. We re-implement window drag manually here instead
    /// of using `isMovableByWindowBackground` because AppKit's built-in
    /// drag handler holds the click for ~500 ms while it decides
    /// drag-vs-tap, which made the Stop tap on the recording HUD feel
    /// unresponsive. By driving drag from `mouseDragged` after a small
    /// pixel threshold, taps fire immediately on mouseUp and drag only
    /// kicks in when the user actually moves the pointer.
    private var mouseDownLocation: NSPoint?
    private var dragInitiated = false

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
        // Single permanent tracking area, .inVisibleRect keeps it in
        // sync with our bounds automatically. Recreating it on every
        // layout pass used to synthesise mouseExited at ~1 Hz and pop
        // our cursor, so we install once and trust super not to wipe
        // it (we double-check via `contains` just in case).
        if let area = trackingArea, trackingAreas.contains(area) { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect,
                      .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// `.push()` instead of `.set()`. WKWebView is a sibling subview
    /// at the same screen coordinates and its CSS-driven cursor
    /// handler calls `.set()` on every mouseMoved tick — that
    /// trampled our `pointingHand.set()` and reverted the cursor to
    /// the system arrow. `push()` adds pointingHand to AppKit's
    /// cursor stack which AppKit treats as authoritative until we
    /// `pop()`; subsequent `.set()` calls from any other view are
    /// ignored for the duration of the hover.
    override func mouseEntered(with event: NSEvent) {
        if !pushedPointingHand {
            pushedPointingHand = true
            NSCursor.pointingHand.push()
        }
        // CRITICAL: forward to super so SwiftUI's internal hover
        // pipeline (driving `.onContinuousHover` → `hovering` →
        // scale-effect) keeps receiving the event. Without this, the
        // cursor worked but the blob never scaled on hover.
        super.mouseEntered(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        if pushedPointingHand {
            pushedPointingHand = false
            NSCursor.pop()
        }
        super.mouseExited(with: event)
    }
    /// Manual drag handover for the floating recording HUD. We do
    /// nothing on mouseDown except remember where it landed — letting
    /// the click reach SwiftUI's tap gesture cleanly on mouseUp.
    /// `mouseDragged` then kicks AppKit's drag handler once the cursor
    /// has moved past the threshold, which transfers control to AppKit
    /// (consuming the rest of the mouseDragged + mouseUp events). The
    /// `ScreenClampingPanel` check scopes this to the floating panel —
    /// the inline blob hosted inside `LibraryWindow` has its own drag
    /// (the page's `.main-header` strip) and shouldn't grab drags here.
    override func mouseDown(with event: NSEvent) {
        if window is ScreenClampingPanel {
            mouseDownLocation = NSEvent.mouseLocation
            dragInitiated = false
        }
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if !dragInitiated,
           let start = mouseDownLocation,
           let panel = window as? ScreenClampingPanel {
            let current = NSEvent.mouseLocation
            let dx = current.x - start.x
            let dy = current.y - start.y
            // 4 px threshold — small enough that "click then nudge"
            // doesn't trigger drag, large enough that finger jitter on
            // a trackpad doesn't either.
            if (dx * dx + dy * dy) >= 16 {
                dragInitiated = true
                panel.performDrag(with: event)
                return
            }
        }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        // dragInitiated stays as-is until next mouseDown — AppKit's
        // drag handler consumed the mouseUp if drag was active, so
        // this branch only runs on a real click.
        super.mouseUp(with: event)
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

/// Shared presentation flag so the panel can ask the SwiftUI view to
/// play its reverse spring before the host window is torn down. The
/// inline Library blob creates its own instance and never flips
/// `dismissing` — it's persistent, so it only ever springs in.
@MainActor
final class HUDPresentation: ObservableObject {
    @Published var dismissing = false
}

/// Liquid Blob HUD body. Pulls the live level from RecordingLevelMeter,
/// renders a Canvas-based morphing shape, exposes a click-anywhere
/// stop. Drag is handled by the host window (`isMovableByWindowBackground`
/// on the floating panel; not applicable inside the Library window).
struct RecordingHUDView: View {

    /// Drives spring-in (onAppear) and spring-out (panel sets
    /// `dismissing`). The Library embedding passes a private instance
    /// that never dismisses.
    @ObservedObject var presentation: HUDPresentation = HUDPresentation()

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
    /// Ambient idle motion — gentle position drift + slow hue / brightness
    /// shimmer, driven by SwiftUI's animation system (NOT TimelineView)
    /// so the resting blob feels alive without burning a per-frame
    /// view recompute. Four independent periods make the cycle look
    /// organic rather than mechanically clocked.
    @State private var idleHueShift: Double = -6
    @State private var idleBrightness: Double = -0.02
    /// Wall-clock instant the recording ended (matching `timeline.date`'s
    /// reference epoch). The persistent inline blob eases its audio-
    /// reactive energy down from this point instead of snapping; `nil`
    /// means "no relax in flight" (either recording, or fully settled).
    @State private var stopAt: TimeInterval? = nil
    /// Holds the 30 Hz tick through the relax settle so the 30→20 Hz
    /// idle downgrade can't hitch mid-transition.
    @State private var relaxing = false
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

        // Palette is bound directly to recording state — red while a
        // recording is in flight (whether the blob is the floating HUD
        // or the inline one in the Library), green at rest. Threshold-
        // based flipping made the floating HUD strobe colours mid-call
        // when audio dipped; that's the wrong signal for "we're still
        // recording, just nobody's talking at this exact moment".
        let palette: BlobPalette = isRecording ? .activeRed : .silentGreen

        // Frame-rate is state-driven so the blob doesn't burn CPU
        // when nothing meaningful is changing on screen:
        //   • Recording:     30 Hz — fast enough to track voice ticks.
        //   • Idle, hovered: 20 Hz — gentle "I'm awake" breathe.
        //   • Idle, resting:  5 Hz — minimum tick rate that still
        //     reads as "alive" (subtle drift + shape wobble) without
        //     pulling the ~10% background CPU the original 6 Hz path
        //     burned. The reduction comes from the smaller per-tick
        //     work: we feed BlobShape an `act` of 0.04 (just enough
        //     to wake the baseline wobble) instead of full audio-
        //     reactive activity, so the path computation is cheap.
        // `paused: !visible` halts everything while the host window
        // is occluded (minimised, behind a fullscreen app, etc.).
        // Only the recording / hover states drive a per-frame
        // TimelineView. The resting green blob does NOT: a low-Hz idle
        // tick reads as choppy "lag", and a high-Hz one burns CPU. Its
        // "alive" motion instead comes entirely from the cheap,
        // display-rate-smooth SwiftUI ambient animations applied below
        // (drift + hue + brightness) over a perfectly static, perfectly
        // round shape. Net: idle is calm + buttery, deformation is
        // reserved for when there's actual audio to react to.
        // The blob animates whenever it's actually on screen — idle
        // included. The earlier "idle = paused, static" version froze
        // the shape (and, with a stale level, froze it mid-bulge). At
        // rest we run a low, near-circular wobble: activity 0 + level 0
        // means BlobShape only applies its 0.15-amplitude baseline
        // breathing — the blob gently circles and keeps relaxing back
        // toward round, never spiking. 20 Hz keeps it buttery (the
        // choppy reading before was the old 5 Hz tick, not the motion
        // itself). `paused: !visible` still hard-stops it when the host
        // window is occluded, so there's no background CPU burn.
        // The persistent inline blob (Library window) does NOT spring
        // away on stop the way the floating HUD does — it stays on
        // screen and transitions recording→idle in place. Hard-cutting
        // level/activity to 0 the instant `recordingState` hit `.idle`
        // snapped the bulged red shape to a round circle in a single
        // frame, which read as the "странно дергается when it shrinks"
        // the user saw (the floating HUD never showed it — it dismisses
        // instead). Drive a relax envelope from the TimelineView clock
        // (NOT a withAnimation @State — a per-frame TimelineView
        // re-render reads the final value and clobbers the interpolation):
        // on stop the audio-reactive energy eases 1→0 over `relax`
        // seconds so the silhouette settles gently into the calm idle
        // circle. Stay at 30 Hz until it has settled so the 30→20 Hz
        // schedule change can't hitch mid-transition.
        let relax: TimeInterval = 0.5
        let fps: Double = (isRecording || relaxing) ? 30 : 20
        Group {
            TimelineView(.animation(minimumInterval: 1.0 / fps,
                                    paused: !visible)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let energy: CGFloat = {
                    if isRecording { return 1 }
                    guard let s = stopAt else { return 0 }
                    let p = (t - s) / relax
                    if p >= 1 { return 0 }
                    // easeOut: quick initial give, long soft settle.
                    let e = 1 - p
                    return CGFloat(e * e)
                }()
                blobLayer(time: t,
                          level: level * Float(energy),
                          activity: audioActivity * energy,
                          palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Entry animation: blob "leaks out" from a tiny dot in the
        // centre. Spring keeps it organic — no hard endpoint snap.
        .scaleEffect((appeared ? 1.0 : 0.05) * (hovering ? 1.18 : 1.0))
        .opacity(appeared ? 1.0 : 0.0)
        // Ambient idle shimmer — colour only, NO positional drift. The
        // blob must stay anchored in place; the "movement" the user
        // wants is the shape gently flexing while it rotates (that's the
        // BlobShape baseline wobble driven by the timeline), not the
        // whole thing sliding around. Keep the faint hue/brightness
        // breathing (±6°, ±0.04) — that reads as alive without moving.
        .hueRotation(.degrees(idleHueShift))
        .brightness(idleBrightness)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: appeared)
        .animation(.easeOut(duration: 0.22), value: hovering)
        // Fast palette change on recording-state transitions. Scoped to
        // `isRecording` so nothing else animates with it.
        .animation(.easeInOut(duration: 0.10), value: isRecording)
        // Soft-fade the whole blob+glow into transparency BEFORE it
        // reaches the host's rectangular bounds. The outer bloom radius
        // (≈ 44–62 pt) is far larger than the breathing room around the
        // 43 pt blob in the 110 pt host, so without this the glow gets
        // hard-clipped at the window edge and reads as an ugly bright
        // RECTANGLE around the blob (worse once the glow opacity was
        // raised). A radial vignette whose clear point sits at the
        // inscribed-circle radius guarantees every edge AND corner is
        // fully transparent — the glow just dissolves like real light
        // instead of hitting a box. Applied after the scale/animation
        // modifiers and at the fixed host size, so hover scale-up can
        // never push the soft edge back out to the rectangular border.
        .mask(
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2
                RadialGradient(
                    // Long concave ease, not "solid then cliff": the
                    // blob body stays fully solid, then the glow's own
                    // light dissolves so gradually it has no perceptible
                    // boundary — yet it's exactly 0 by every edge/corner
                    // (corners sit past endRadius → clamped to the final
                    // clear stop). A short ramp here just swapped the
                    // hard rectangle for an equally hard circle.
                    gradient: Gradient(stops: [
                        .init(color: .white, location: 0.00),
                        .init(color: .white, location: 0.34),
                        .init(color: .white.opacity(0.92), location: 0.50),
                        .init(color: .white.opacity(0.74), location: 0.62),
                        .init(color: .white.opacity(0.52), location: 0.72),
                        .init(color: .white.opacity(0.32), location: 0.81),
                        .init(color: .white.opacity(0.16), location: 0.89),
                        .init(color: .white.opacity(0.06), location: 0.95),
                        .init(color: .white.opacity(0),    location: 1.00)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: r
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        )
        // Panel-driven exit: reuse the very same scale/opacity spring as
        // the entry, just run backwards — the blob shrinks to a tiny
        // transparent dot. The panel waits ~0.45 s (spring settle) before
        // orderOut, so this fully plays before the window disappears.
        .onChange(of: presentation.dismissing) { _, dismissing in
            if dismissing { appeared = false }
        }
        // Inline-blob relax (see the TimelineView energy envelope above).
        // `.stopping` keeps `isRecording` true, so the edge into the
        // settle fires exactly once — on the real transition to `.idle`.
        // The delayed clear releases the 30 Hz hold and pins energy to a
        // hard 0 once the ease has fully landed.
        .onChange(of: ctx.recordingState) { _, state in
            if state != .idle {
                stopAt = nil
                relaxing = false
            } else {
                stopAt = Date().timeIntervalSinceReferenceDate
                relaxing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    relaxing = false
                    stopAt = nil
                }
            }
        }
        .onAppear {
            appeared = true
            // Start the ambient loops after the entry spring lands so
            // they don't fight the leak-from-a-dot scale animation.
            // Four different periods keep the cycle visibly irregular —
            // the blob never lines up with itself, which is what makes
            // the motion feel "alive" instead of "looping".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) {
                    idleHueShift = 6
                }
                withAnimation(.easeInOut(duration: 3.9).repeatForever(autoreverses: true)) {
                    idleBrightness = 0.04
                }
            }
        }
        // SwiftUI hover drives only the scale-up. The cursor is fully
        // owned by HUDHostingView's push/pop on AppKit's cursor stack
        // — pushing wins against WKWebView's per-mouseMoved `.set()`
        // that the SwiftUI-side `.set()` couldn't outpace.
        .onContinuousHover { phase in
            switch phase {
            case .active: if !hovering { hovering = true }
            case .ended:  hovering = false
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
        let lvl = CGFloat(level)
        BlobShape(time: time, level: lvl, activity: activity)
            .fill(
                RadialGradient(
                    colors: palette.fillStops,
                    center: UnitPoint(x: 0.38, y: 0.32),
                    startRadius: 6,
                    endRadius: 60
                )
            )
            .overlay(
                BlobShape(time: time, level: lvl, activity: activity)
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
        // The blob's original soft brand-coloured glow. The
        // backdrop-blur "frosted lens" experiment put a dark veil over
        // the blob (NSVisualEffectView `.hudWindow` darkened it) — the
        // user rejected that; we're back to a clean opaque blob with
        // just this multi-layer bloom (wide faint halo → mid → tight
        // core). Breathes up with audio level.
        .shadow(color: palette.glowOuter.opacity(0.22),
                radius: 44 + 18 * lvl, x: 0, y: 8)
        .shadow(color: palette.glowOuter.opacity(0.40),
                radius: 26 + 14 * lvl, x: 0, y: 6)
        .shadow(color: palette.glowOuter.opacity(0.48),
                radius: 13 + 8 * lvl, x: 0, y: 4)
        .shadow(color: palette.glowInner.opacity(0.32),
                radius: 5, x: 0, y: 2)
    }

}

/// Two named palettes the view snaps between based on detected
/// speech activity. The flip is hysteresis-gated and animated over
/// ~80 ms; no value interpolation, no crossfade.
private struct BlobPalette {
    let fillStops: [Color]
    /// Soft brand-coloured glow the blob has always carried (the
    /// multi-layer bloom in `blobLayer`). Kept separate from the
    /// frosted-lens fill so the ambient glow reads as the blob's own
    /// light, not a hard drop shadow.
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
            let jitterAmp = (0.08 + 0.9 * Double(level)) * Double(act)
            let jitter = (sin(jitterPhase1) * 0.06 + sin(jitterPhase2) * 0.04) * jitterAmp
            let wobble = baseWobble + jitter

            // Audio level pushes the radius outward. Phase rotates
            // per-point so loud audio bulges different sides at
            // different times rather than uniformly inflating.
            // Gated by `act`: at rest (act≈0) this is exactly zero even
            // if `level` carries a stale value from a just-finished
            // recording — otherwise a paused idle frame freezes the blob
            // mid-bulge ("застыл в растёкшемся состоянии").
            let levelPhase = sin(time * 2.1 + Double(i) * 1.2)
            let levelBoost = Double(level) * 0.9 * (0.55 + 0.45 * levelPhase) * Double(act)

            // Directional "audio tongue": a single localised edge that
            // lunges OUT hard when sound hits, instead of the whole blob
            // inflating uniformly. The pull is centred on a slowly
            // sweeping angle and falls off (gaussian) with angular
            // distance, so the silhouette grows a living, stretching
            // grань that tracks volume — exactly the "an edge pulls on
            // the beat" read the user wanted. Driven by `level`
            // directly (not gated by `act`): `level` is already ~0 in
            // silence, so the tongue only appears when there's actual
            // sound, and its reach scales with how loud it is.
            let pointAngle = Double(i) / Double(pointCount) * 2 * .pi
            let tongueDir = time * 0.85
            var dAng = abs((pointAngle - tongueDir)
                .truncatingRemainder(dividingBy: 2 * .pi))
            if dAng > .pi { dAng = 2 * .pi - dAng }
            // σ ≈ 0.5 rad (~30°) — a focused lobe, not a soft swell.
            let tongueFalloff = exp(-(dAng * dAng) / (2 * 0.5 * 0.5))
            // Lift mid-levels (pow < 1) so normal speech — not just
            // shouting — moves the edge. Reach kept modest (×1.0) so it
            // reads as "an edge leans out on the beat", not a spike
            // lashing out — the previous ×2.4 was way too violent.
            let levelLifted = pow(max(0, Double(level)), 0.8)
            // Also gated by `act` so the resting blob can never grow a
            // tongue from a stale level — only a live recording with
            // real speech activity does.
            let tongue = levelLifted * 1.0 * tongueFalloff * Double(act)

            // Idle "breath bulge": even with zero audio, one side leans
            // gently out and the lobe slowly travels around the rim, so
            // the resting blob reads as alive instead of a frozen circle.
            // Always on (NOT gated by act/level), tiny (~3.5% radius),
            // slow — "a side just barely wants to break out, regularly".
            let idleDir = time * 0.55
            var dIdle = abs((pointAngle - idleDir)
                .truncatingRemainder(dividingBy: 2 * .pi))
            if dIdle > .pi { dIdle = 2 * .pi - dIdle }
            let idleLobe = exp(-(dIdle * dIdle) / (2 * 0.8 * 0.8))
            let idlePulse = (0.5 + 0.5 * sin(time * 1.3)) * 0.035 * idleLobe

            let r = baseRadius * (baseR + CGFloat(wobble)
                                  + CGFloat(levelBoost) + CGFloat(tongue)
                                  + CGFloat(idlePulse))
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
