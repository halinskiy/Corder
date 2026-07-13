import AppKit
import SwiftUI
import Combine

/// Floating panel that hovers over every other window while Corder is
/// recording. The visual is a live frequency-spectrum equalizer: a row of
/// bars driven by an FFT of the captured audio (RecordingLevelMeter), flat
/// in silence and reacting per-band to real sound. Click stops the
/// recording. (This replaced the old "blob"; the in-window indicator is
/// gone too, recording is started/stopped from the popover + in-app button.)
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
    /// is on screen, NSPanel.delegate is `weak`.
    private var delegate: HUDWindowDelegate?
    /// Local event monitor that forces `.pointingHand` whenever the
    /// cursor sits over the floating panel. Required because the panel
    /// is `.nonactivatingPanel`, macOS reads cursor preference from
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
    /// floating HUD is redundant, the inline blob in the page covers
    /// the start/stop affordance, so we hide it. Restored as soon as
    /// the user switches focus away from the Library.
    private var librarySuppressed: Bool = false

    /// Total panel size. The blob itself only occupies ~40 % of this;
    /// the rest is breathing room for the contact shadow + the hover
    /// scale-up so neither ever clips at the panel boundary.
    private static let windowSize: CGFloat = 110

    private static let originXKey = "Corder.HUDOrigin.x"
    private static let originYKey = "Corder.HUDOrigin.y"

    func show() {
        // The floating equalizer HUD is user-toggleable (Settings → General
        // → "Recording equalizer", default ON). When off, never bring the
        // pill up, and keep `wantsVisible` false so a later Library-suppress
        // toggle can't resurrect it either. Recording runs headless; Stop is
        // still reachable from the popover + the in-app button.
        guard AppSettings.hudEnabled else {
            wantsVisible = false
            FileLogger.log("RecordingHUDPanel.show: suppressed (hudEnabled=false)")
            return
        }
        wantsVisible = true
        FileLogger.log("RecordingHUDPanel.show: wantsVisible=true librarySuppressed=\(librarySuppressed)")
        if librarySuppressed { return }
        ensureVisible()
    }

    private func ensureVisible() {
        if window?.isVisible == true {
            FileLogger.log("RecordingHUDPanel.ensureVisible: already visible, skip")
            return
        }
        // Reuse a panel that was only ordered OUT (not torn down). The
        // common case: `setLibrarySuppressed(true)` does `window?.orderOut`
        // but keeps `window`, so its `isVisible` is false. Without this
        // reuse, every suppress→unsuppress toggle (each Space switch,
        // ⌘H, minimize, app-switch, Library close while recording) would
        // build a BRAND-NEW panel and overwrite `window`, orphaning the
        // previous NSPanel + SwiftUI TimelineView tree. The orphans are
        // never torn down and keep re-rendering off-screen, an unbounded
        // memory + power leak that grows with how much the user moves
        // around during a call. Just bring the existing panel back.
        if let existing = window {
            presentation.dismissing = false
            existing.orderFrontRegardless()
            FileLogger.log("RecordingHUDPanel.ensureVisible: re-showed existing panel (no rebuild)")
            return
        }
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
        // Mouse-moved events are off by default on NSPanel, we need them on
        // so HUDHostingView's tracking area actually fires mouseMoved /
        // cursorUpdate. Without this, .nonactivatingPanel silently swallows
        // every mouse-moved event and the pointing-hand cursor never appears.
        panel.acceptsMouseMovedEvents = true

        // Persisted position from a previous session, falling back to
        // the bottom-right corner of the main screen if there's nothing
        // saved yet (or if the saved point is on a screen that's no
        // longer attached, happens when the user undocks an external
        // monitor between sessions).
        let origin = restoredOrigin(for: panel) ?? defaultOrigin(for: panel)
        panel.setFrameOrigin(origin)

        // Hook windowDidMove so dragging the HUD persists immediately,
        // no need to wait for hide() to flush the new position.
        let del = HUDWindowDelegate { [weak self] frame in
            self?.saveOrigin(frame.origin)
        }
        panel.delegate = del
        delegate = del

        panel.orderFrontRegardless()
        window = panel

        installCursorMonitor()
        FileLogger.log("RecordingHUDPanel.ensureVisible: panel ordered front at origin=(\(origin.x),\(origin.y)) size=\(Self.windowSize) level=\(panel.level.rawValue) visible=\(panel.isVisible)")
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
        // user asked for, "так же уходит когда запись останавливаю").
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
    /// recording, the user is looking at the Library, where the inline
    /// blob covers the same affordance.
    func setLibrarySuppressed(_ suppressed: Bool) {
        // The floating equalizer HUD now stays visible even while the Library
        // window is focused, the user wants it ALWAYS up during recording, not
        // only when Corder is hidden (there's no inline in-window equalizer to
        // fall back on anymore). We keep this hook (many callers: Library
        // key/occlusion/⌘H) but no longer hide the pill; we just make sure it's
        // up when it should be. Flip `hudFollowsLibrary` back to re-enable
        // hiding if that's ever wanted again.
        let hudFollowsLibrary = false
        FileLogger.log("RecordingHUDPanel.setLibrarySuppressed(\(suppressed)) [follows=\(hudFollowsLibrary), wantsVisible=\(wantsVisible)]")
        guard hudFollowsLibrary else {
            if librarySuppressed { librarySuppressed = false }
            if wantsVisible { ensureVisible() }
            return
        }
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
        // Bottom-right corner with a small breathing margin so the
        // glow never hits the screen edge.
        return NSPoint(x: f.maxX - w - 16, y: f.minY + 16)
    }
}

/// NSHostingView subclass that declares a pointing-hand cursor rect
/// over its full bounds via the documented AppKit mechanism
/// (`resetCursorRects` + `addCursorRect`). This wins against the
/// background-drag handler installed by `isMovableByWindowBackground`
/// on the floating panel, push/set-based approaches lose that fight
/// on .nonactivatingPanel windows.
///
/// Tracking area + cursorUpdate / mouseMoved overrides are kept as a
/// safety net for cases where AppKit doesn't query cursor rects (rare,
/// but cheap to defend against).
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    private var trackingArea: NSTrackingArea?
    /// `true` while we've pushed `.pointingHand` onto AppKit's cursor
    /// stack. mouseEntered pushes once, mouseExited pops once, both
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
    /// handler calls `.set()` on every mouseMoved tick, that
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
    /// nothing on mouseDown except remember where it landed, letting
    /// the click reach SwiftUI's tap gesture cleanly on mouseUp.
    /// `mouseDragged` then kicks AppKit's drag handler once the cursor
    /// has moved past the threshold, which transfers control to AppKit
    /// (consuming the rest of the mouseDragged + mouseUp events). The
    /// `ScreenClampingPanel` check scopes this to the floating panel
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
            // 4 px threshold, small enough that "click then nudge"
            // doesn't trigger drag, large enough that finger jitter on
            // a trackpad doesn't either.
            if (dx * dx + dy * dy) >= 16 {
                dragInitiated = true
                // `performDrag` is synchronous: it runs AppKit's drag loop
                // (moving the window through our setFrameOrigin override, where
                // the rubber-band applies) and RETURNS on mouse-up. Flag the
                // drag so the panel rubber-bands past the edge instead of hard-
                // clamping, then spring it back on-screen once the drag ends.
                panel.isUserDragging = true
                panel.performDrag(with: event)
                panel.isUserDragging = false
                panel.settleOnScreen()
                return
            }
        }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        // dragInitiated stays as-is until next mouseDown, AppKit's
        // drag handler consumed the mouseUp if drag was active, so
        // this branch only runs on a real click.
        super.mouseUp(with: event)
    }
}

/// NSPanel subclass that clamps every move/resize to the visible
/// frame of whichever screen the panel currently sits on (closest
/// screen by centre, when in transition). Without this,
/// `isMovableByWindowBackground` lets the user drag the HUD past
/// the screen edge until it's no longer visible, there's no
/// frameless-window equivalent of AppKit's titlebar clamp.
final class ScreenClampingPanel: NSPanel {
    /// True only while the user is hand-dragging the HUD (set around
    /// `performDrag`). During a drag we let the panel slip PAST the screen
    /// edge with rubber-band resistance (Apple-PiP feel) instead of a hard
    /// stop; on release `settleOnScreen()` springs it back. Every OTHER move
    /// (initial placement, screen change, programmatic reposition) uses the
    /// hard clamp so the HUD can never be left stranded off-screen.
    var isUserDragging = false
    /// True only while `settleOnScreen()`'s spring animation is playing, so
    /// its interpolated frames (which start off-screen at the overshoot spot)
    /// aren't hard-clamped mid-flight, that would snap the panel to the edge
    /// instantly and kill the animation.
    private var isSettling = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(bounded(frameRect), display: flag)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(bounded(frameRect), display: flag, animate: animate)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(bounded(NSRect(origin: point, size: frame.size)).origin)
    }

    private func bounded(_ rect: NSRect) -> NSRect {
        if isSettling { return rect }
        return isUserDragging ? rubberBanded(rect) : clamped(rect)
    }

    /// Screen whose visibleFrame contains the proposed centre; main as
    /// fallback (multi-monitor wraparound, sleep/wake races).
    private func visibleFrame(for rect: NSRect) -> NSRect? {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(centre) })
            ?? NSScreen.main
        return screen?.visibleFrame
    }

    private func clamped(_ rect: NSRect) -> NSRect {
        guard let visible = visibleFrame(for: rect) else { return rect }
        var c = rect
        if c.minX < visible.minX { c.origin.x = visible.minX }
        if c.minY < visible.minY { c.origin.y = visible.minY }
        if c.maxX > visible.maxX { c.origin.x = visible.maxX - c.width }
        if c.maxY > visible.maxY { c.origin.y = visible.maxY - c.height }
        return c
    }

    /// Damped overshoot: the panel can cross the edge, but each pixel past it
    /// counts for less, asymptotically capped at `maxOver`, so it can never
    /// run fully off-screen no matter how hard you drag (the PiP "push-back").
    private func rubberBanded(_ rect: NSRect) -> NSRect {
        guard let visible = visibleFrame(for: rect) else { return rect }
        var r = rect
        r.origin.x = resisted(r.origin.x, lo: visible.minX, hi: visible.maxX - r.width)
        r.origin.y = resisted(r.origin.y, lo: visible.minY, hi: visible.maxY - r.height)
        return r
    }
    private func resisted(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        if v < lo { return lo - damp(lo - v) }
        if v > hi { return hi + damp(v - hi) }
        return v
    }
    private func damp(_ over: CGFloat) -> CGFloat {
        let maxOver: CGFloat = 90          // hyperbolic resistance, →maxOver
        return maxOver * over / (over + maxOver)
    }

    /// Spring the HUD fully back on-screen after a drag ends. No-op when it
    /// already sits inside the visible frame (the common case).
    func settleOnScreen() {
        let target = clamped(frame)
        guard target != frame else { return }
        isSettling = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            // Slight back-ease overshoot for that springy PiP snap.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.4, 0.64, 1)
            ctx.allowsImplicitAnimation = true
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.isSettling = false
        })
    }
}

/// NSPanel.delegate hook, fires on every move, lets us persist the
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
/// `dismissing`, it's persistent, so it only ever springs in.
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
    /// means, the floating HUD wires it to stop-recording; the Library
    /// embedding wires it to a state-aware toggle (start when idle,
    /// stop when recording).
    let onTap: () -> Void

    /// When true, the blob renders as if a recording is in flight
    /// (active morph through templates + audio-reactive amplitude)
    /// but **keeps the silent-green palette**. Used by the Welcome
    /// wizard's hero, "the app introducing itself", without the
    /// red recording-state strobe. Synthetic audio levels are
    /// generated from the TimelineView clock so the morph keeps
    /// moving even though no real audio is flowing.
    var welcomeActive: Bool = false

    /// Three-sine synthetic instantaneous level, gives the morph a
    /// believable "voice" amplitude without real audio. Peaks ~ 0.35
    /// so the shape deforms generously but never spikes into a star.
    /// Number of bars in the equalizer.
    fileprivate static let barCount = 11
    private static let barBaseH: CGFloat = 5    // resting height, short bars, never dots
    private static let barMaxExtra: CGFloat = 30

    /// Per-frame smoother for the equalizer bars. The spectrum DATA arrives
    /// at the mic-buffer rate (~10 Hz when only the user is speaking
    /// 4096 frames / 44.1 kHz ≈ 93 ms), far below the 20 fps render. Binding
    /// the bar heights straight to that data (with a per-bar `.easeOut` that
    /// RESTARTS on every ~100 ms step) read as the micro-jerks the user saw.
    /// Instead we lerp the DISPLAYED heights toward the latest target every
    /// rendered frame, so motion is smooth regardless of the data rate. A
    /// reference type so mutating it inside the TimelineView body doesn't
    /// invalidate the view (nothing observes it).
    private final class BarSmoother {
        var heights: [CGFloat] = []
        var lastT: TimeInterval = 0
    }
    @State private var barSmoother = BarSmoother()

    /// Displayed bar heights: the per-frame lerp of `barTargets` toward the
    /// live spectrum. `tau` is the smoothing time constant, small enough
    /// that syllables still pop, large enough to bridge the ~93 ms data
    /// steps into continuous motion.
    private func barHeights(t: TimeInterval, isRecording: Bool, relax: TimeInterval) -> [CGFloat] {
        let target = barTargets(t: t, isRecording: isRecording, relax: relax)
        let tau = 0.07
        let dt = barSmoother.lastT == 0 ? (1.0 / 20.0)
                                        : max(0, min(0.1, t - barSmoother.lastT))
        barSmoother.lastT = t
        if barSmoother.heights.count != target.count {
            barSmoother.heights = target          // first frame / count change: snap
            return target
        }
        let k = CGFloat(1 - exp(-dt / tau))
        for i in 0..<target.count {
            barSmoother.heights[i] += (target[i] - barSmoother.heights[i]) * k
        }
        return barSmoother.heights
    }

    /// Per-bar TARGET heights for the REAL spectrum equalizer. Each bar is a
    /// genuine FFT frequency band from `RecordingLevelMeter.spectrum`
    /// (low → high), so lows / mids / highs react independently to the
    /// actual sound, not one level faked across bars. Folds in the stop
    /// ease-out so it settles flat instead of snapping. Welcome mode
    /// synthesises a moving spectrum from the clock. Kept out of the
    /// ViewBuilder for type-check. `barHeights` smooths these per frame.
    private func barTargets(t: TimeInterval, isRecording: Bool, relax: TimeInterval) -> [CGFloat] {
        let energy: CGFloat
        if isRecording {
            energy = 1
        } else if let s = stopAt {
            let p = (t - s) / relax
            let e = 1 - p
            energy = p >= 1 ? 0 : CGFloat(e * e)
        } else {
            energy = 0
        }
        let n = Self.barCount
        let spec: [CGFloat]
        if welcomeActive {
            // A gently shifting fake spectrum for the onboarding demo.
            spec = (0..<n).map { i in
                let a = sin(t * 2.1 + Double(i) * 0.7)
                let b = sin(t * 3.3 + Double(i) * 1.9)
                return CGFloat(max(0, (a + b) * 0.5)) * 0.7
            }
        } else {
            spec = meter.spectrum.map { CGFloat($0) }
        }
        return (0..<n).map { i in
            let raw = i < spec.count ? Double(spec[i]) : 0
            // Perceptual fill: a gamma < 1 pulls mid-level bands UP toward
            // full (0.3→0.47, 0.5→0.66, 0.7→0.81) so normal speech visibly
            // fills the equalizer instead of barely lifting off the floor,
            // and a small gain saturates real peaks. Silence (raw 0) stays
            // flat, the noise gate already zeroed it upstream.
            let filled = raw > 0 ? min(1.0, pow(raw, 0.62) * 1.18) : 0
            let v = min(1, CGFloat(filled) * energy)
            return Self.barBaseH + v * Self.barMaxExtra
        }
    }

    /// The live equalizer: a centred row of vertical bars from `heights`.
    /// `heights` is ALREADY per-frame-smoothed by `barHeights` (a time-
    /// constant lerp toward the live spectrum), so the bars need NO SwiftUI
    /// `.animation(value:)` here, adding one on top restarts a 0.11 s ease
    /// on every ~93 ms data step, which is exactly the micro-jerk we removed.
    private func barsLayer(heights: [CGFloat], palette: MeterPalette) -> some View {
        let color = palette.fillStops.first ?? Color.white
        return HStack(alignment: .center, spacing: 3.5) {
            ForEach(0..<heights.count, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: heights[i])
            }
        }
        .frame(height: Self.barBaseH + Self.barMaxExtra)   // fixed → stable vertical centring
        .shadow(color: palette.glowOuter.opacity(0.35), radius: 5)
    }


    @ObservedObject private var meter = RecordingLevelMeter.shared
    /// Lets the view know when a recording is actually in flight, used
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
    /// notification arrives, without that, the blob would render as
    /// frozen-then-jump on first appearance.
    @State private var visible = true
    /// Ambient idle motion, gentle position drift + slow hue / brightness
    /// shimmer, driven by SwiftUI's animation system (NOT TimelineView)
    /// so the resting blob feels alive without burning a per-frame
    /// view recompute. Four independent periods make the cycle look
    /// organic rather than mechanically clocked.
    /// Wall-clock instant the recording ended (matching `timeline.date`'s
    /// reference epoch). The persistent inline blob eases its audio-
    /// reactive energy down from this point instead of snapping; `nil`
    /// means "no relax in flight" (either recording, or fully settled).
    @State private var stopAt: TimeInterval? = nil
    /// Holds the active (20 Hz) tick through the relax settle so the
    /// 20→12 Hz idle downgrade can't hitch mid-transition.
    @State private var relaxing = false
    var body: some View {
        // Real audio levels from the level meter, used everywhere
        // EXCEPT the welcome-active path, which synthesises its
        // own gentle wave from the timeline clock further down.
        let liveLevel = max(meter.micLevel, meter.systemLevel)

        // `welcomeActive` co-opts the recording-mode morph (active
        // templates + amplitude) without entering true recording
        // state, so the palette stays green while the shape still
        // breathes. The Library / HUD callers pass `false` and get
        // exactly the prior behaviour.
        let isRecording = welcomeActive || (ctx.recordingState != .idle)
        let palette: MeterPalette =
            welcomeActive ? .silentGreen
                          : (isRecording ? .activeRed : .silentGreen)

        // Frame-rate is state-driven so the blob doesn't burn CPU
        // when nothing meaningful is changing on screen:
        //   • Recording:     20 Hz, the bars are per-frame-lerped, so 20
        //                    reads smooth; matches the meter publish gate.
        //   • Idle, hovered: 20 Hz, gentle "I'm awake" breathe.
        //   • Idle, resting:  5 Hz, minimum tick rate that still
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
        // The blob animates whenever it's actually on screen, idle
        // included. The earlier "idle = paused, static" version froze
        // the shape (and, with a stale level, froze it mid-bulge). At
        // rest we run a low, near-circular wobble: activity 0 + level 0
        // means BlobShape only applies its 0.15-amplitude baseline
        // breathing, the blob gently circles and keeps relaxing back
        // toward round, never spiking. 20 Hz keeps it buttery (the
        // choppy reading before was the old 5 Hz tick, not the motion
        // itself). `paused: !visible` still hard-stops it when the host
        // window is occluded, so there's no background CPU burn.
        // The persistent inline blob (Library window) does NOT spring
        // away on stop the way the floating HUD does, it stays on
        // screen and transitions recording→idle in place. Hard-cutting
        // level/activity to 0 the instant `recordingState` hit `.idle`
        // snapped the bulged red shape to a round circle in a single
        // frame, which read as the "странно дергается when it shrinks"
        // the user saw (the floating HUD never showed it, it dismisses
        // instead). Drive a relax envelope from the TimelineView clock
        // (NOT a withAnimation @State, a per-frame TimelineView
        // re-render reads the final value and clobbers the interpolation):
        // on stop the audio-reactive energy eases 1→0 over `relax`
        // seconds so the silhouette settles gently into the calm idle
        // circle. Stay at the active rate until it has settled so the
        // 20→12 Hz schedule change can't hitch mid-transition.
        // 20 fps while recording (was 30): the equalizer scroll still reads
        // smooth at 20, and a continuous SwiftUI/Core-Animation re-render of
        // the floating pill is pure power drawn for the WHOLE recording
        // every frame shaved helps the always-on load. Idle drops to 12.
        let relax: TimeInterval = 0.5
        let fps: Double = (isRecording || relaxing) ? 20 : 12
        Group {
            TimelineView(.animation(minimumInterval: 1.0 / fps,
                                    paused: !visible)) { timeline in
                // LIVE BARS (equalizer). A row of vertical bars built from
                // the recent level history, newest on the right, scrolling
                // left as the meter shifts. Each bar IS a real sample, so the
                // bars jump with every syllable and lie flat in silence:
                // unmistakable "sound is being captured". Level math lives in
                // `meterBars` (out of this ViewBuilder closure for type-check).
                let t = timeline.date.timeIntervalSinceReferenceDate
                barsLayer(heights: barHeights(t: t, isRecording: isRecording, relax: relax),
                          palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid (but invisible) hit target across the WHOLE pill. The thin
        // equalizer bars leave most of the pill empty, so without this a
        // click between bars hit nothing and "Stop" didn't fire. An almost-
        // transparent fill is hit-testable everywhere; the real tap handler
        // is `.contentShape` + `.onTapGesture` further down.
        .background(Color.black.opacity(0.001))
        // Entry animation: blob "leaks out" from a tiny dot in the
        // centre. Spring keeps it organic, no hard endpoint snap.
        .scaleEffect((appeared ? 1.0 : 0.05) * (hovering ? 1.18 : 1.0))
        .opacity(appeared ? 1.0 : 0.0)
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
        // fully transparent, the glow just dissolves like real light
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
                    // boundary, yet it's exactly 0 by every edge/corner
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
        // the entry, just run backwards, the blob shrinks to a tiny
        // transparent dot. The panel waits ~0.45 s (spring settle) before
        // orderOut, so this fully plays before the window disappears.
        .onChange(of: presentation.dismissing) { _, dismissing in
            if dismissing { appeared = false }
        }
        // Inline-blob relax (see the TimelineView energy envelope above).
        // `.stopping` keeps `isRecording` true, so the edge into the
        // settle fires exactly once, on the real transition to `.idle`.
        // The delayed clear releases the active-rate hold and pins energy
        // to a hard 0 once the ease has fully landed.
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
        }
        // SwiftUI hover drives only the scale-up. The cursor is fully
        // owned by HUDHostingView's push/pop on AppKit's cursor stack,
        // pushing wins against WKWebView's per-mouseMoved `.set()`
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
        // check ALL windows, if the blob's host is among the visible
        // ones, we animate; otherwise pause. Cheap: NSApp.windows
        // returns a few items, comparison is by reference identity.
        //
        // DEBOUNCED (350 ms): this notification fires in BURSTS during any
        // window transition (Space switch, full-screen app coming forward,
        // the panel itself ordering in/out). Each raw event re-evaluated
        // `visible`, and a single transient `false` PAUSED the TimelineView,
        // freezing the per-frame bar lerp, read by a tester as the equalizer
        // "appears then disappears" repeatedly. Coalescing the burst and
        // applying only the SETTLED state kills that flicker (the LibraryWindow
        // occlusion debounce in 0.14.95 only covered the window-open regime;
        // this is the closed-window regime it missed).
        .onReceive(NotificationCenter.default
            .publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)) { _ in
            visible = Self.anyHostWindowVisible()
        }
        .help("Click to start or stop recording")
    }

    /// True if any window currently in `NSApp.windows` is on-screen
    /// AND not occluded. Used as the gate for blob animation
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

}

/// Two palettes the equalizer snaps between on detected speech activity:
/// green at rest, crimson while voiced. `fillStops.first` is the bar
/// colour, `glowOuter` the soft glow behind the bars.
private struct MeterPalette {
    let fillStops: [Color]
    let glowOuter: Color

    /// Idle / silent, brand green.
    static let silentGreen = MeterPalette(
        fillStops: [
            Color(red: 0.18, green: 0.66, blue: 0.40),    // bright leaf
            Color(red: 0.06, green: 0.49, blue: 0.27),    // brand #0e7c44
            Color(red: 0.03, green: 0.30, blue: 0.16)     // deep forest
        ],
        glowOuter: Color(red: 0.10, green: 0.60, blue: 0.34)
    )

    /// Active speech, bright crimson.
    static let activeRed = MeterPalette(
        fillStops: [
            Color(red: 0.95, green: 0.30, blue: 0.36),
            Color(red: 0.78, green: 0.16, blue: 0.24),
            Color(red: 0.52, green: 0.08, blue: 0.14)
        ],
        glowOuter: Color(red: 0.85, green: 0.20, blue: 0.28)
    )
}
