import SwiftUI
import AppKit

/// SwiftUI body of the custom update modal. Drawn over a `NSWindow`
/// hosted by `UpdateWindowController`. Self-contained — talks to the
/// outside world only through the closures the driver hands in.
///
/// Visual contract (Костя's spec):
///   • Compact 3D entrance — card scales + tilts in on appear
///   • Animated star field behind the card, particles streaming
///     toward centre (the "celebration" backdrop)
///   • Big primary "Update" button — single CTA does the whole flow
///   • Release notes collapsed by default, expanded on "Show more"
///   • Type tokens 16 / 14 — nothing smaller, design-system shell
struct UpdateView: View {
    @ObservedObject var state: UpdateState
    let onPrimary: () -> Void
    let onDismiss: () -> Void

    @State private var entered = false
    @State private var notesOpen = false

    var body: some View {
        ZStack {
            StarFieldView()
                .ignoresSafeArea()

            card
                .opacity(entered ? 1 : 0)
                .scaleEffect(entered ? 1 : 0.86)
                .rotation3DEffect(
                    .degrees(entered ? 0 : 12),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.6
                )
                .animation(.spring(response: 0.55, dampingFraction: 0.74), value: entered)
        }
        .frame(width: 420, height: notesOpen ? 520 : 360)
        .background(Color.clear)
        .onAppear { entered = true }
    }

    @ViewBuilder
    private var card: some View {
        VStack(spacing: 18) {
            // Compact eyebrow + version stack — release notes collapsed.
            VStack(spacing: 6) {
                Text("Corder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(state.versionTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.top, 4)

            if let phaseMsg = state.phaseStatusLine {
                Text(phaseMsg)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            if state.phase.showsProgress {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .frame(height: 6)
                    .padding(.horizontal, 8)
            }

            // Primary CTA. Disabled during indeterminate phases.
            Button(action: onPrimary) {
                Text(state.primaryLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 0.055, green: 0.49, blue: 0.27))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!state.primaryEnabled)
            .opacity(state.primaryEnabled ? 1 : 0.55)
            .keyboardShortcut(.defaultAction)

            // Secondary actions — disclosure + close. Inline text-only
            // buttons; the heavy lifting is the big CTA above.
            HStack(spacing: 18) {
                if let notes = state.releaseNotes, !notes.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { notesOpen.toggle() }
                    } label: {
                        Text(notesOpen ? "Hide details" : "Show details")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Text("Later")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            if notesOpen, let notes = state.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 18)
        )
    }
}

/// Animated star backdrop. Particles spawn at the viewport edges and
/// stream toward the centre, fading in and out. Drawn on a SwiftUI
/// `Canvas` driven by `TimelineView(.animation)` — that's the
/// accelerated WAAPI-equivalent path on macOS and stays at 60fps
/// without redrawing the rest of the SwiftUI tree.
struct StarFieldView: View {
    @State private var stars: [Star] = (0..<70).map { _ in Star.random() }
    @State private var lastTick: Date = Date()

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let now = context.date
                let dt = max(0.001, min(0.05, now.timeIntervalSince(lastTick)))
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                var next: [Star] = []
                next.reserveCapacity(stars.count)
                for var s in stars {
                    s.advance(dt: dt, centre: centre, size: size)
                    next.append(s)

                    let alpha = s.alpha
                    let r = s.radius
                    let rect = CGRect(x: s.position.x - r, y: s.position.y - r, width: r * 2, height: r * 2)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(alpha))
                    )
                }
                DispatchQueue.main.async {
                    stars = next
                    lastTick = now
                }
            }
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct Star {
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var life: Double
    var maxLife: Double

    static func random() -> Star {
        let w: CGFloat = 420
        let h: CGFloat = 420
        let centre = CGPoint(x: w / 2, y: h / 2)
        // Spawn anywhere in the viewport, but with a velocity that
        // points toward the centre — gives the "everything converges"
        // celebration feel.
        let x = CGFloat.random(in: 0...w)
        let y = CGFloat.random(in: 0...h)
        let dx = centre.x - x
        let dy = centre.y - y
        let dist = max(1, (dx * dx + dy * dy).squareRoot())
        let speed = CGFloat.random(in: 22...60)
        let vx = dx / dist * speed
        let vy = dy / dist * speed
        let maxLife = Double.random(in: 1.6...3.4)
        return Star(
            position: CGPoint(x: x, y: y),
            velocity: CGVector(dx: vx, dy: vy),
            radius: CGFloat.random(in: 0.6...1.7),
            life: 0,
            maxLife: maxLife
        )
    }

    mutating func advance(dt: TimeInterval, centre: CGPoint, size: CGSize) {
        life += dt
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt
        let dx = position.x - centre.x
        let dy = position.y - centre.y
        let distSq = dx * dx + dy * dy
        if life >= maxLife || distSq < 16 || position.x < -20 || position.x > size.width + 20 || position.y < -20 || position.y > size.height + 20 {
            self = Star.random()
            // Re-anchor to the actual canvas size we just learned about.
            position = CGPoint(
                x: CGFloat.random(in: 0...size.width),
                y: CGFloat.random(in: 0...size.height)
            )
            let dxs = centre.x - position.x
            let dys = centre.y - position.y
            let d = max(1, (dxs * dxs + dys * dys).squareRoot())
            let speed = CGFloat.random(in: 22...60)
            velocity = CGVector(dx: dxs / d * speed, dy: dys / d * speed)
        }
    }

    var alpha: Double {
        let t = life / maxLife
        // Triangle envelope: 0 → 1 → 0
        let env = t < 0.5 ? (t * 2) : ((1 - t) * 2)
        return Double(max(0, min(0.9, env)))
    }
}
