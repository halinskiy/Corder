#!/usr/bin/env swift
// Render the DMG installer background as PNGs (1× + 2×) via
// AppKit / CoreText — the same rasteriser Finder uses for the
// "Corder" / "Applications" captions under the icons.
//
// Design (2026-06, Tracer-style, v2 per feedback): white canvas, a small
// crisp "Drag to install" caption sitting JUST ABOVE the dashed arrow
// (not a big fuzzy headline up top), and two soft semi-transparent green
// circles bleeding in from the side edges (radial gradient, NO blur),
// pushed far enough out that they're ambient and don't pull the eye.
//
// Coordinate system: AppKit native (origin bottom-left, Y grows upward).
// Layout constants are written as "logical Y from the TOP" and mapped via
// `upY()`. We never flip the context (NSAttributedString.draw ignores a
// CGContext flip), we only scale it.
//
// Output:
//   Resources/dmg-background.png       (540×400, 1×)
//   Resources/dmg-background@2x.png    (1080×800, 2×)

import AppKit

// MARK: - Logical canvas (matches `make-dmg.sh` --window-size).

let W: CGFloat = 540
let H: CGFloat = 400

// Icon centres (create-dmg `--icon X Y` uses TOP-DOWN Y, same as here).
let LEFT_ICON_CX_TOP:  CGFloat = 145
let RIGHT_ICON_CX_TOP: CGFloat = 395
let ICON_CY_TOP:       CGFloat = 172

// Dashed arrow on the icon-centre row, between the two icons.
let ARROW_Y_TOP:   CGFloat = ICON_CY_TOP
let ARROW_X_START: CGFloat = LEFT_ICON_CX_TOP  + 55  // 200
let ARROW_X_END:   CGFloat = RIGHT_ICON_CX_TOP - 55  // 340  (chevron tip)

// Caption: small, crisp, centred over the arrow and sitting just ABOVE it.
let HEADLINE = "Drag to install"
let HEADLINE_SIZE:  CGFloat = 15
let HEADLINE_GAP:   CGFloat = 22        // px above the arrow row

let DASH_COLOR     = NSColor(calibratedRed: 150/255, green: 150/255, blue: 150/255, alpha: 1)
let WHITE_COLOR    = NSColor.white
let HEADLINE_COLOR = NSColor(calibratedRed: 0x3a/255, green: 0x3a/255, blue: 0x3c/255, alpha: 1)

@inline(__always) func upY(_ topY: CGFloat) -> CGFloat { return H - topY }

@inline(__always) func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    return NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor
}

// MARK: - Soft circle (radial gradient, no blur)

/// A semi-transparent green disc fading from `color` at the centre to fully
/// transparent at `radius`. No Gaussian blur — the radial falloff is the
/// soft edge. Centres sit partly off-canvas so only an ambient arc shows.
func drawSoftCircle(_ cg: CGContext, centerTop: CGPoint, radius: CGFloat, color: CGColor) {
    let center = CGPoint(x: centerTop.x, y: upY(centerTop.y))
    let space = CGColorSpaceCreateDeviceRGB()
    let clear = color.copy(alpha: 0) ?? rgba(0, 0, 0, 0)
    guard let grad = CGGradient(colorsSpace: space,
                                colors: [color, clear] as CFArray,
                                locations: [0, 1]) else { return }
    cg.saveGState()
    cg.drawRadialGradient(grad,
                          startCenter: center, startRadius: 0,
                          endCenter: center, endRadius: radius,
                          options: [])
    cg.restoreGState()
}

// MARK: - Draw one rep at the given pixel scale

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(W * scale)
    let pxH = Int(H * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxW,
        pixelsHigh: pxH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("could not allocate bitmap") }
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create context")
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // NOTE: do NOT cg.scaleBy(scale) here. The rep already has a 2x backing
    // scale at scale=2 (rep.size 540×400 over a 1080×800 pixel buffer), so an
    // explicit scaleBy double-scales and throws the centred arrow/caption off
    // the @2x canvas (only the huge edge circles still bleed in). Drawing in
    // logical 540×400 coords fills both reps correctly via the backing scale.

    // ── White background.
    WHITE_COLOR.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()

    // ── Two ambient green circles bleeding in from the side edges. Centres
    //    pushed WELL off-canvas so only a soft arc shows; low alpha so they
    //    read as a faint wash, not a focal point. Brand greens (light-mode
    //    + dark-mode accent) for a subtle two-tone.
    drawSoftCircle(cg, centerTop: CGPoint(x: -70, y: 200), radius: 235,
                   color: rgba(0x1f, 0x9d, 0x59, 0.22))
    drawSoftCircle(cg, centerTop: CGPoint(x: 610, y: 200), radius: 225,
                   color: rgba(0x0e, 0x7c, 0x44, 0.20))

    // ── Caption "Drag to install": small, crisp, centred over the arrow,
    //    HEADLINE_GAP px above it.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        // Light/regular weight: Tracer's caption is a thin face, which reads
        // CRISPER than a semibold at this small size (semibold looked smeared).
        .font: NSFont.systemFont(ofSize: HEADLINE_SIZE, weight: .regular),
        .foregroundColor: HEADLINE_COLOR,
        .paragraphStyle: para,
        .kern: 0.1,
    ]
    let headline = NSAttributedString(string: HEADLINE, attributes: attrs)
    let textSize = headline.size()
    let lineH = ceil(textSize.height)
    // Centre the caption horizontally on the ARROW's midpoint (not just the
    // window centre) so the text + arrow read as one centred unit, and sit
    // it HEADLINE_GAP px above the arrow row.
    let arrowMidX = (ARROW_X_START + ARROW_X_END) / 2
    let blockTopY = ARROW_Y_TOP - HEADLINE_GAP - lineH
    let textRect = NSRect(x: arrowMidX - textSize.width / 2 - 8,
                          y: upY(blockTopY) - lineH,
                          width: ceil(textSize.width) + 16, height: lineH)
    headline.draw(in: textRect)

    // ── Dashed horizontal line ending just shy of the chevron tip.
    let arrowY  = upY(ARROW_Y_TOP)
    let lineEnd = ARROW_X_END - 16
    cg.saveGState()
    cg.setStrokeColor(DASH_COLOR.cgColor)
    cg.setLineWidth(3)
    cg.setLineCap(.round)
    cg.setLineDash(phase: 0, lengths: [9, 7])
    cg.beginPath()
    cg.move(to: CGPoint(x: ARROW_X_START, y: arrowY))
    cg.addLine(to: CGPoint(x: lineEnd, y: arrowY))
    cg.strokePath()
    cg.restoreGState()

    // ── Filled-triangle chevron at the right end.
    let tipX = ARROW_X_END
    let tipY = arrowY
    let chevLen: CGFloat = 16
    let chevHalfW: CGFloat = 7
    cg.saveGState()
    cg.setFillColor(DASH_COLOR.cgColor)
    cg.beginPath()
    cg.move(to: CGPoint(x: tipX, y: tipY))
    cg.addLine(to: CGPoint(x: tipX - chevLen, y: tipY - chevHalfW))
    cg.addLine(to: CGPoint(x: tipX - chevLen, y: tipY + chevHalfW))
    cg.closePath()
    cg.fillPath()
    cg.restoreGState()

    return rep
}

// MARK: - Encode + write

func writePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DMGBackground", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: URL(fileURLWithPath: path))
    print("✔ wrote \(path)")
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: make-dmg-background.swift <out-1x.png> <out-2x.png>\n", stderr)
    exit(2)
}

do {
    try writePNG(render(scale: 1), to: args[1])
    try writePNG(render(scale: 2), to: args[2])
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
