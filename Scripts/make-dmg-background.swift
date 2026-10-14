#!/usr/bin/env swift
// Renders the DMG window background (660x400 pt).
// Usage: swift Scripts/make-dmg-background.swift <out.png> [scale]
// Icon slots in make-dmg.sh: app at (170,190), Applications at (490,190), top-left origin.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1
let W: CGFloat = 660, H: CGFloat = 400

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
// y helper: convert top-left y to bottom-left.
func Y(_ top: CGFloat) -> CGFloat { H - top }

// 1. Base: soft diagonal wash.
NSGradient(colors: [rgb(246, 244, 255), rgb(226, 232, 252)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)

// 2. Aurora blobs.
func blob(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) {
    NSGradient(colors: [c, c.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: cx, y: Y(cy)), radius: 0, toCenter: NSPoint(x: cx, y: Y(cy)), radius: r, options: [])
}
blob(70, 40, 260, rgb(167, 139, 250, 0.55))   // violet, top-left
blob(600, 70, 240, rgb(96, 165, 250, 0.50))   // blue, top-right
blob(330, 420, 300, rgb(244, 114, 182, 0.30)) // pink, bottom
blob(620, 380, 200, rgb(52, 211, 153, 0.28))  // mint, bottom-right
blob(40, 380, 190, rgb(251, 191, 36, 0.20))   // warm, bottom-left

// 3. Fine dot grid, fading toward the centre.
for gx in stride(from: CGFloat(14), to: W, by: 22) {
    for gy in stride(from: CGFloat(14), to: H, by: 22) {
        let d = hypot(gx - W / 2, gy - H / 2) / (W / 2)
        let a = min(0.22, max(0.0, d * 0.16))
        rgb(80, 70, 160, a).setFill()
        NSBezierPath(ovalIn: NSRect(x: gx - 1, y: gy - 1, width: 2, height: 2)).fill()
    }
}

// 4. Glass cards behind both icon slots.
func card(centerX: CGFloat) {
    let r = NSRect(x: centerX - 100, y: Y(190) - 88, width: 200, height: 170)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: rgb(70, 60, 170, 0.22).cgColor)
    let p = NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28)
    rgb(255, 255, 255, 0.55).setFill(); p.fill()
    ctx.restoreGState()
    let p2 = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
    p2.lineWidth = 1.2
    rgb(255, 255, 255, 0.9).setStroke(); p2.stroke()
    // top sheen
    NSGradient(colors: [rgb(255, 255, 255, 0.55), rgb(255, 255, 255, 0)])!
        .draw(in: NSBezierPath(roundedRect: NSRect(x: r.minX + 2, y: r.midY, width: r.width - 4, height: r.height / 2 - 2), xRadius: 26, yRadius: 26), angle: -90)
}
card(centerX: 170)
card(centerX: 490)

// 5. Arrow: dotted shaft in a violet→blue gradient with a rounded chevron head.
let ay = Y(180)
ctx.saveGState()
let shaft = NSBezierPath()
for i in 0..<9 {
    let x = 262 + CGFloat(i) * 12.5
    shaft.append(NSBezierPath(ovalIn: NSRect(x: x, y: ay - 2.8 + 0, width: 5.6, height: 5.6)))
}
shaft.setClip()
NSGradient(colors: [rgb(139, 92, 246), rgb(59, 130, 246)])!
    .draw(in: NSRect(x: 260, y: ay - 8, width: 130, height: 16), angle: 0)
ctx.restoreGState()
let head = NSBezierPath()
head.lineWidth = 6; head.lineCapStyle = .round; head.lineJoinStyle = .round
head.move(to: NSPoint(x: 378, y: ay + 15)); head.line(to: NSPoint(x: 398, y: ay)); head.line(to: NSPoint(x: 378, y: ay - 15))
rgb(59, 130, 246).setStroke(); head.stroke()

// 6. Title (gradient) + tagline + footer.
func centered(_ s: String, _ font: NSFont, _ color: NSColor, topY: CGFloat, kern: CGFloat = 0) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    (s as NSString).draw(in: NSRect(x: 0, y: Y(topY) - font.pointSize - 6, width: W, height: font.pointSize + 14),
                         withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: kern])
}
// gradient title via text mask
let title = "AI Usage Bar" as NSString
let tfont = NSFont.systemFont(ofSize: 30, weight: .heavy)
let tattrs: [NSAttributedString.Key: Any] = [.font: tfont, .kern: -0.6]
let tsize = title.size(withAttributes: tattrs)
let tx = (W - tsize.width) / 2, ty = Y(30) - tsize.height + 8
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: rgb(90, 70, 200, 0.25).cgColor)
title.draw(at: NSPoint(x: tx, y: ty), withAttributes: tattrs.merging([.foregroundColor: rgb(60, 40, 160)]) { $1 })
ctx.restoreGState()
// overlay gradient clipped to glyphs
let mask = NSImage(size: NSSize(width: W, height: H), flipped: false) { _ in
    title.draw(at: NSPoint(x: tx, y: ty), withAttributes: tattrs.merging([.foregroundColor: NSColor.black]) { $1 })
    return true
}
var rect = CGRect(x: 0, y: 0, width: W, height: H)
if let cg = mask.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
    ctx.saveGState()
    ctx.clip(to: rect, mask: cg)
    NSGradient(colors: [rgb(124, 58, 237), rgb(37, 99, 235), rgb(14, 165, 233)])!
        .draw(in: NSRect(x: tx, y: ty, width: tsize.width, height: tsize.height), angle: 0)
    ctx.restoreGState()
}
centered("Claude · Codex · Antigravity usage, right in your menu bar",
         .systemFont(ofSize: 13, weight: .medium), rgb(70, 70, 110, 0.85), topY: 78)
centered("Drag AI Usage Bar onto Applications to install",
         .systemFont(ofSize: 12, weight: .regular), rgb(90, 90, 130, 0.75), topY: 372, kern: 0.2)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
