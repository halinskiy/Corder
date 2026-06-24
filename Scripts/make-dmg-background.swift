#!/usr/bin/env swift
// Render the DMG installer background as PNGs (1× + 2×) via
// AppKit / CoreText — the same rasteriser Finder uses for the
// "Corder" / "Applications" captions under the icons.
//
// Design (2026-06, Tracer-style): white canvas, a "Drag to install"
// headline near the top, two soft organic brand-green "blob" shapes
// flanking the icon row (the getcorder.com hero motif, deformed
// circles, low opacity so they read as decoration not chrome), and a
// dashed arrow + chevron between the Corder.app and Applications icons.
//
// Coordinate system: AppKit native (origin bottom-left, Y grows
// upward). Layout constants are written as "logical Y from the TOP of
// the canvas" for readability and mapped through `upY()` at draw time.
// (NSAttributedString.draw ignores a CGContext flip and paints
// baseline-up, so we never flip the context — we only scale it.)
//
// Output:
//   Resources/dmg-background.png       (540×400, 1×)
//   Resources/dmg-background@2x.png    (1080×800, 2×)

import AppKit
import CoreImage

// MARK: - Logical canvas (matches `make-dmg.sh` --window-size).

let W: CGFloat = 540
let H: CGFloat = 400

// Icon centres. create-dmg `--icon X Y` uses TOP-DOWN Y, the same
// convention as this renderer, so the values match 1:1. Icons sit a
// touch above the vertical centre so the headline has room above and
// the Finder captions have room below.
let LEFT_ICON_CX_TOP:  CGFloat = 145
let RIGHT_ICON_CX_TOP: CGFloat = 395
let ICON_CY_TOP:       CGFloat = 172

// Arrow lives on the icon-centre row, BETWEEN the two icons.
let ARROW_Y_TOP:   CGFloat = ICON_CY_TOP
let ARROW_X_START: CGFloat = LEFT_ICON_CX_TOP  + 55  // 200
let ARROW_X_END:   CGFloat = RIGHT_ICON_CX_TOP - 55  // 340  (chevron tip)

// Headline.
let HEADLINE = "Drag to install"
let HEADLINE_Y_TOP: CGFloat = 66        // top of the text block
let HEADLINE_SIZE:  CGFloat = 22

let DASH_COLOR     = NSColor(calibratedRed: 150/255, green: 150/255, blue: 150/255, alpha: 1)
let WHITE_COLOR    = NSColor.white
let HEADLINE_COLOR = NSColor(calibratedRed: 0x1d/255, green: 0x1d/255, blue: 0x1f/255, alpha: 1)

// Helper: map "logical Y from top" → AppKit bottom-up Y.
@inline(__always) func upY(_ topY: CGFloat) -> CGFloat { return H - topY }

@inline(__always) func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    return NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a).cgColor
}

// MARK: - Organic blob path

/// Anchor points on a circle whose radius is perturbed per-vertex,
/// giving a "slightly deformed circle". `radii` length = vertex count.
func blobPoints(center: CGPoint, baseR: CGFloat, radii: [CGFloat]) -> [CGPoint] {
    let n = radii.count
    return (0..<n).map { i -> CGPoint in
        let a = (CGFloat(i) / CGFloat(n)) * 2 * .pi
        let r = baseR * radii[i]
        return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }
}

/// Smooth closed curve through all anchor points (Catmull-Rom → cubic
/// Bézier). Produces the soft, hand-drawn blob outline.
func addClosedSmoothPath(_ cg: CGContext, _ pts: [CGPoint]) {
    let n = pts.count
    guard n >= 3 else { return }
    cg.move(to: pts[0])
    for i in 0..<n {
        let p0 = pts[(i - 1 + n) % n]
        let p1 = pts[i]
        let p2 = pts[(i + 1) % n]
        let p3 = pts[(i + 2) % n]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        cg.addCurve(to: p2, control1: c1, control2: c2)
    }
    cg.closePath()
}

/// Fill a blob with a vertical brand-green gradient, clipped to the
/// deformed-circle outline. `topColor`/`botColor` already carry their
/// own (low) alpha so the shape stays a soft wash over white.
func drawBlob(_ cg: CGContext,
              centerTop: CGPoint,
              baseR: CGFloat,
              radii: [CGFloat],
              topColor: CGColor,
              botColor: CGColor) {
    let center = CGPoint(x: centerTop.x, y: upY(centerTop.y))
    let pts = blobPoints(center: center, baseR: baseR, radii: radii)
    cg.saveGState()
    addClosedSmoothPath(cg, pts)
    cg.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    guard let grad = CGGradient(colorsSpace: space,
                                colors: [topColor, botColor] as CFArray,
                                locations: [0, 1]) else {
        cg.restoreGState(); return
    }
    let top = CGPoint(x: center.x, y: center.y + baseR)
    let bot = CGPoint(x: center.x, y: center.y - baseR)
    cg.drawLinearGradient(grad, start: top, end: bot, options: [])
    cg.restoreGState()
}

/// Render the two flanking blobs into a transparent layer and
/// Gaussian-blur them, so their edges feather into the white like the
/// getcorder.com hero (a hard-clipped fill reads as a solid mass and
/// fights the icons). Returns a pixel-space CGImage to composite.
func blurredBlobLayer(scale: CGFloat) -> CGImage? {
    let pxW = Int(W * scale), pxH = Int(H * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState(); return nil
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: scale, y: scale)

    // Left = brighter accent, right = deeper/cooler green. Both bleed
    // off the side edges; alphas stay low so the blur leaves a soft wash.
    drawBlob(cg,
             centerTop: CGPoint(x: 18, y: 204),
             baseR: 150,
             radii: [1.00, 0.87, 1.13, 0.95, 1.07, 0.89, 1.10, 0.93],
             topColor: rgba(0x83, 0xE2, 0xAD, 0.60),
             botColor: rgba(0x1f, 0x9d, 0x59, 0.32))

    drawBlob(cg,
             centerTop: CGPoint(x: 524, y: 186),
             baseR: 144,
             radii: [1.05, 0.92, 1.09, 0.94, 1.11, 0.88, 1.05, 0.98],
             topColor: rgba(0xA6, 0xE2, 0xC2, 0.54),
             botColor: rgba(0x0e, 0x7c, 0x44, 0.30))
    NSGraphicsContext.restoreGraphicsState()

    guard let base = rep.cgImage else { return nil }
    guard let blur = CIFilter(name: "CIGaussianBlur") else { return base }
    blur.setValue(CIImage(cgImage: base), forKey: kCIInputImageKey)
    blur.setValue(13 * scale, forKey: kCIInputRadiusKey)
    guard let out = blur.outputImage else { return base }
    let ciCtx = CIContext(options: nil)
    let rect = CGRect(x: 0, y: 0, width: pxW, height: pxH)
    return ciCtx.createCGImage(out, from: rect) ?? base
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
    cg.scaleBy(x: scale, y: scale)

    // ── White background.
    WHITE_COLOR.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()

    // ── Two organic brand-green blobs, flanking the icon row and
    //    bleeding off the side edges, Gaussian-blurred into a soft wash
    //    (getcorder.com hero motif) so they decorate without fighting
    //    the icons.
    if let blobs = blurredBlobLayer(scale: scale) {
        cg.saveGState()
        cg.draw(blobs, in: CGRect(x: 0, y: 0, width: W, height: H))
        cg.restoreGState()
    }

    // ── Headline: "Drag to install".
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: HEADLINE_SIZE, weight: .semibold),
        .foregroundColor: HEADLINE_COLOR,
        .paragraphStyle: para,
        .kern: 0.2,
    ]
    let headline = NSAttributedString(string: HEADLINE, attributes: attrs)
    let lineH = ceil(headline.size().height)
    // Rect top sits at HEADLINE_Y_TOP (top-down); origin.y is the rect
    // bottom in AppKit coords.
    let textRect = NSRect(x: 0, y: upY(HEADLINE_Y_TOP) - lineH, width: W, height: lineH)
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
