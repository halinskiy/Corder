#!/usr/bin/env swift
// Render the DMG installer background as PNGs (1× + 2×) via
// AppKit / CoreText — the same rasteriser Finder uses for the
// "Corder" / "Applications" captions under the icons.
//
// Coordinate system: AppKit native (origin bottom-left, Y grows
// upward). All layout constants in this file are written as
// "logical Y from the TOP of the canvas" for readability; we
// translate to AppKit's bottom-up frame by subtracting from `H`
// at draw time. Earlier attempts with a flipped CGContext gave
// upside-down text (NSAttributedString.draw ignores the context
// flip and paints baseline-up).
//
// Output:
//   Resources/dmg-background.png       (700×360, 1×)
//   Resources/dmg-background@2x.png    (1400×720, 2×)

import AppKit

// MARK: - Logical canvas (matches `make-dmg.sh` --window-size).

// Original install-window proportions (540×400) — narrower +
// taller than the brief experiment with 700×300. Icons pulled in
// from the edges so they sit closer together; the dashed arrow
// runs between them on the same Y row.
let W: CGFloat = 540
let H: CGFloat = 400

// Icon centres. Empirically verified that `create-dmg --icon X Y`
// uses TOP-DOWN Y (same convention as this Swift renderer), so
// the two values match: ICON_CY_TOP == create-dmg --icon Y.
// y=130 puts the icon glyph high enough that caption + arrow
// land near the window's vertical centre, not below it.
let LEFT_ICON_CX_TOP:  CGFloat = 145
let RIGHT_ICON_CX_TOP: CGFloat = 395
let ICON_CY_TOP:       CGFloat = 130

// Arrow lives on the icon-centre row, BETWEEN the two icons.
// Icon visual half-width ≈ 50 px; inset 55 px from each centre
// so the dashes never touch the icon glyphs.
let ARROW_Y_TOP:   CGFloat = ICON_CY_TOP             // 130
let ARROW_X_START: CGFloat = LEFT_ICON_CX_TOP  + 55  // 200
let ARROW_X_END:   CGFloat = RIGHT_ICON_CX_TOP - 55  // 340  (chevron tip)

let DASH_COLOR  = NSColor(calibratedRed: 160/255, green: 160/255, blue: 160/255, alpha: 1)
let WHITE_COLOR = NSColor.white

// Helper: map "logical Y from top" → AppKit bottom-up Y.
@inline(__always) func upY(_ topY: CGFloat) -> CGFloat { return H - topY }

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
    rep.size = NSSize(width: W, height: H)   // logical pt size

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create context")
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // Pixel-space scale only — no flip, so NSAttributedString.draw
    // paints text right-side up.
    cg.scaleBy(x: scale, y: scale)

    // ── White background.
    WHITE_COLOR.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()

    // ── Dashed horizontal line ending just shy of the chevron tip.
    // Drawn through the CGContext directly: `NSBezierPath.setLineDash`
    // + `stroke()` was silently producing an EMPTY image under a
    // scaled CG context in the previous take (no visible dashes at
    // all). Going to the CG layer cuts out that whole class of
    // bug — CGContext's dash + stroke is the path Apple's own
    // drawing samples use.
    let arrowY  = upY(ARROW_Y_TOP)
    let lineEnd = ARROW_X_END - 16
    cg.saveGState()
    cg.setStrokeColor(DASH_COLOR.cgColor)
    cg.setLineWidth(3)
    cg.setLineCap(.round)
    let pattern: [CGFloat] = [9, 7]
    cg.setLineDash(phase: 0, lengths: pattern)
    cg.beginPath()
    cg.move(to: CGPoint(x: ARROW_X_START, y: arrowY))
    cg.addLine(to: CGPoint(x: lineEnd, y: arrowY))
    cg.strokePath()
    cg.restoreGState()

    // ── Filled-triangle chevron at the right end. Same CGContext
    // path approach so the chevron + line render through the same
    // code path and we know if one shows the other will too.
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
