#!/usr/bin/env swift
// Draws the CoursLocal icon and writes the macOS and iOS AppIcon sets. Run from the project root:
//     swift Tools/make-icons.swift [style]          writes the icon sets (default style below)
//     swift Tools/make-icons.swift --preview out.png  renders every style side by side
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Style: String, CaseIterable { case livre, onde, bulle, toque, feuille }
let defaultStyle = Style.bulle

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let white = color(0xFFFFFF)

/// Rounded rectangle with continuous (squircle-like) corners, as Apple icons use.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath(), r = min(radius, rect.width / 2.56, rect.height / 2.56), k: CGFloat = 1.28
    let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    path.move(to: CGPoint(x: x0 + r * k, y: y0))
    path.addLine(to: CGPoint(x: x1 - r * k, y: y0))
    path.addCurve(to: CGPoint(x: x1, y: y0 + r * k), control1: CGPoint(x: x1 - r * 0.25, y: y0), control2: CGPoint(x: x1, y: y0 + r * 0.25))
    path.addLine(to: CGPoint(x: x1, y: y1 - r * k))
    path.addCurve(to: CGPoint(x: x1 - r * k, y: y1), control1: CGPoint(x: x1, y: y1 - r * 0.25), control2: CGPoint(x: x1 - r * 0.25, y: y1))
    path.addLine(to: CGPoint(x: x0 + r * k, y: y1))
    path.addCurve(to: CGPoint(x: x0, y: y1 - r * k), control1: CGPoint(x: x0 + r * 0.25, y: y1), control2: CGPoint(x: x0, y: y1 - r * 0.25))
    path.addLine(to: CGPoint(x: x0, y: y0 + r * k))
    path.addCurve(to: CGPoint(x: x0 + r * k, y: y0), control1: CGPoint(x: x0, y: y0 + r * 0.25), control2: CGPoint(x: x0 + r * 0.25, y: y0))
    path.closeSubpath()
    return path
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

/// Drawing helpers in a unit square mapped to `rect`, top-left origin (the context is flipped).
struct Canvas {
    let c: CGContext, rect: CGRect
    var s: CGFloat { rect.width }
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s) }
    func background(_ top: UInt32, _ bottom: UInt32, glow: CGFloat = 0.2) {
        c.saveGState(); c.clip(to: rect)
        c.drawLinearGradient(gradient([color(top), color(bottom)]), start: p(0.2, 0), end: p(0.8, 1), options: extend)
        c.drawRadialGradient(gradient([color(0xFFFFFF, glow), color(0xFFFFFF, 0)]), startCenter: p(0.25, 0.1), startRadius: 0,
                             endCenter: p(0.25, 0.1), endRadius: 0.8 * s, options: [])
        c.restoreGState()
    }
    /// Rounded bars centered on `center`, filled with a gradient running from `from` to `to`.
    func wave(_ heights: [CGFloat], x: CGFloat, center: CGFloat, bar: CGFloat, gap: CGFloat, colors: [CGColor], from: CGPoint, to: CGPoint) {
        let path = CGMutablePath(); var x = x
        for h in heights { path.addPath(squircle(r(x, center - h / 2, bar, h), radius: bar / 2 * s)); x += bar + gap }
        c.saveGState(); c.addPath(path); c.clip()
        c.drawLinearGradient(gradient(colors), start: p(from.x, from.y), end: p(to.x, to.y), options: extend)
        c.restoreGState()
    }
    func fill(_ path: CGPath, _ fill: CGColor, shadow: CGFloat = 0) {
        c.saveGState()
        if shadow > 0 { c.setShadow(offset: CGSize(width: 0, height: 0.02 * s), blur: 0.05 * s, color: color(0x000000, shadow)) }
        c.addPath(path); c.setFillColor(fill); c.fillPath()
        c.restoreGState()
    }
    func line(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: CGColor) {
        self.fill(squircle(r(x, y, w, h), radius: h / 2 * s), fill)
    }
    func path(_ points: [(CGFloat, CGFloat)]) -> CGMutablePath {
        let path = CGMutablePath(); path.addLines(between: points.map { p($0.0, $0.1) }); path.closeSubpath(); return path
    }
}

func baseColor(_ style: Style) -> CGColor {
    switch style {
    case .livre: return color(0xD8336B)
    case .onde: return color(0x0B1026)
    case .bulle: return color(0x0E7C86)
    case .toque: return color(0x1B3B9A)
    case .feuille: return color(0x2B2799)
    }
}

func drawArtwork(_ k: Canvas, _ style: Style) {
    let c = k.c
    switch style {
    case .livre: // An open book from which a sound wave rises.
        k.background(0xFF9A4D, 0xD8336B)
        let left = CGMutablePath()
        left.move(to: k.p(0.5, 0.47)); left.addCurve(to: k.p(0.15, 0.43), control1: k.p(0.40, 0.41), control2: k.p(0.25, 0.40))
        left.addLine(to: k.p(0.15, 0.80)); left.addCurve(to: k.p(0.5, 0.84), control1: k.p(0.25, 0.77), control2: k.p(0.40, 0.78)); left.closeSubpath()
        let right = CGMutablePath()
        right.move(to: k.p(0.5, 0.47)); right.addCurve(to: k.p(0.85, 0.43), control1: k.p(0.60, 0.41), control2: k.p(0.75, 0.40))
        right.addLine(to: k.p(0.85, 0.80)); right.addCurve(to: k.p(0.5, 0.84), control1: k.p(0.75, 0.77), control2: k.p(0.60, 0.78)); right.closeSubpath()
        k.fill(left, white, shadow: 0.25); k.fill(right, color(0xFFF3EC), shadow: 0.25)
        for i in 0..<3 {
            let y = 0.54 + CGFloat(i) * 0.075
            k.line(0.22, y, 0.21, 0.03, color(0xF2A08A)); k.line(0.57, y, 0.21, 0.03, color(0xF2A08A))
        }
        k.wave([0.08, 0.16, 0.26, 0.34, 0.26, 0.16, 0.08], x: 0.5 - (7 * 0.05 + 6 * 0.032) / 2, center: 0.24, bar: 0.05, gap: 0.032,
               colors: [white, white], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: 1))
    case .onde: // Minimal: a bright sound wave on the night.
        k.background(0x1A1F4A, 0x070A1C, glow: 0.08)
        let heights: [CGFloat] = [0.16, 0.34, 0.56, 0.40, 0.66, 0.44, 0.24]
        let bar: CGFloat = 0.075, gap: CGFloat = 0.04
        k.wave(heights, x: 0.5 - (7 * bar + 6 * gap) / 2, center: 0.5, bar: bar, gap: gap,
               colors: [color(0x35E0FF), color(0x8B5CFF), color(0xFF4F9A)], from: CGPoint(x: 0.12, y: 0.5), to: CGPoint(x: 0.88, y: 0.5))
    case .bulle: // A speech bubble: speech turned into text.
        k.background(0x2BD4B0, 0x0E7C86)
        // Tail and body share one shadow layer so they read as a single shape.
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 0.02 * k.s), blur: 0.05 * k.s, color: color(0x000000, 0.25))
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        k.fill(squircle(k.r(0.15, 0.20, 0.70, 0.52), radius: 0.14 * k.s), white)
        k.fill(k.path([(0.28, 0.64), (0.22, 0.85), (0.46, 0.68)]), white)
        c.endTransparencyLayer(); c.restoreGState()
        c.endTransparencyLayer()
        k.wave([0.06, 0.12, 0.18, 0.11, 0.16, 0.08], x: 0.26, center: 0.36, bar: 0.035, gap: 0.03,
               colors: [color(0x13A89A), color(0x0E7C86)], from: CGPoint(x: 0.26, y: 0), to: CGPoint(x: 0.6, y: 0))
        k.line(0.26, 0.49, 0.48, 0.04, color(0x9FDCD3)); k.line(0.26, 0.57, 0.33, 0.04, color(0x9FDCD3))
    case .toque: // A graduation cap above a sound wave.
        k.background(0x3C8CFF, 0x1B3B9A)
        let yellow = color(0xFFC93C)
        k.fill(k.path([(0.31, 0.36), (0.69, 0.36), (0.69, 0.50), (0.31, 0.50)]), color(0xDCE6FF))
        let base = CGMutablePath(); base.addEllipse(in: k.r(0.31, 0.45, 0.38, 0.10)); k.fill(base, color(0xDCE6FF))
        k.fill(k.path([(0.5, 0.17), (0.88, 0.31), (0.5, 0.45), (0.12, 0.31)]), white, shadow: 0.25)
        c.setStrokeColor(yellow); c.setLineWidth(0.018 * k.s); c.setLineCap(.round)
        c.move(to: k.p(0.5, 0.31)); c.addLine(to: k.p(0.79, 0.37)); c.addLine(to: k.p(0.79, 0.52)); c.strokePath()
        k.fill(squircle(k.r(0.765, 0.50, 0.05, 0.09), radius: 0.02 * k.s), yellow)
        k.wave([0.05, 0.10, 0.16, 0.10, 0.16, 0.09, 0.05], x: 0.5 - (7 * 0.042 + 6 * 0.03) / 2, center: 0.74, bar: 0.042, gap: 0.03,
               colors: [yellow, color(0xFF9F2E)], from: CGPoint(x: 0.25, y: 0), to: CGPoint(x: 0.75, y: 0))
    case .feuille: // The first icon: a note sheet where a sound wave becomes lines of text.
        k.background(0x546BFF, 0x2B2799, glow: 0.22)
        k.fill(squircle(k.r(0.20, 0.17, 0.60, 0.68), radius: 0.075 * k.s), white, shadow: 0.3)
        k.wave([0.06, 0.13, 0.22, 0.30, 0.20, 0.27, 0.14, 0.08], x: 0.275, center: 0.40, bar: 0.036, gap: 0.026,
               colors: [color(0xFF5C54), color(0xFF9E3D)], from: CGPoint(x: 0.27, y: 0.2), to: CGPoint(x: 0.73, y: 0.55))
        for (i, w) in [0.45, 0.38, 0.42, 0.26].enumerated() { k.line(0.275, 0.585 + CGFloat(i) * 0.062, CGFloat(w), 0.03, color(0x5C66C7)) }
        k.c.setFillColor(color(0xFF5C54)); k.c.fillEllipse(in: k.r(0.665, 0.215, 0.06, 0.06))
    }
}

enum Platform { case iOS, macOS }

func context(_ width: Int, _ height: Int, opaque: Bool) -> CGContext {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1); c.interpolationQuality = .high
    return c
}
func png(_ c: CGContext) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, c.makeImage()!, nil); CGImageDestinationFinalize(destination)
    return data as Data
}
/// macOS grid: 824/1024 body, continuous corners, drop shadow.
func drawMacIcon(_ c: CGContext, _ style: Style, in frame: CGRect) {
    let side = frame.width, inset = side * 100 / 1024
    let body = frame.insetBy(dx: inset, dy: inset), shape = squircle(body, radius: body.width * 0.2237)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: side * 0.012), blur: side * 0.03, color: color(0x000000, 0.35))
    c.addPath(shape); c.setFillColor(baseColor(style)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(shape); c.clip(); drawArtwork(Canvas(c: c, rect: body), style); c.restoreGState()
}
func render(_ size: Int, _ platform: Platform, _ style: Style) -> Data {
    // iOS rejects icons with an alpha channel and applies its own mask: full bleed, opaque.
    let c = context(size, size, opaque: platform == .iOS), frame = CGRect(x: 0, y: 0, width: size, height: size)
    if platform == .iOS { drawArtwork(Canvas(c: c, rect: frame), style) } else { drawMacIcon(c, style, in: frame) }
    return png(c)
}
func write(_ data: Data, to path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: path))
}
func json(_ images: [[String: String]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--preview", arguments.count == 2 {
    // Every style as a macOS icon (large), with a 64 px rendering underneath to judge small sizes.
    let tile = 440, small = 64, gap = 40, styles = Style.allCases
    let c = context(styles.count * (tile + gap) + gap, tile + small + 3 * gap, opaque: true)
    c.setFillColor(color(0xECECEF)); c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height))
    for (i, style) in styles.enumerated() {
        let x = CGFloat(gap + i * (tile + gap))
        drawMacIcon(c, style, in: CGRect(x: x, y: CGFloat(gap), width: CGFloat(tile), height: CGFloat(tile)))
        drawMacIcon(c, style, in: CGRect(x: x + CGFloat(tile - small) / 2, y: CGFloat(tile + 2 * gap), width: CGFloat(small), height: CGFloat(small)))
    }
    write(png(c), to: arguments[1]); print("Aperçu : \(styles.map(\.rawValue).joined(separator: ", "))")
    exit(0)
}
guard let style = arguments.first.map({ Style(rawValue: $0) }) ?? defaultStyle else {
    print("Styles : \(Style.allCases.map(\.rawValue).joined(separator: ", "))"); exit(1)
}

// macOS: every size from 16 to 512 points, @1x and @2x.
let mac = "CoursLocal/Assets.xcassets/AppIcon.appiconset"
var macImages: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(points * scale, .macOS, style), to: "\(mac)/\(name)")
        macImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
write(json(macImages), to: "\(mac)/Contents.json")

// iOS: a single 1024 image, resized by Xcode.
let ios = "CoursLocalMobile/Assets.xcassets/AppIcon.appiconset"
write(render(1024, .iOS, style), to: "\(ios)/icon-1024.png")
write(json([["filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]]), to: "\(ios)/Contents.json")

for catalog in ["CoursLocal/Assets.xcassets", "CoursLocalMobile/Assets.xcassets"] {
    write(try! JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted]), to: "\(catalog)/Contents.json")
}
print("Icônes écrites (style \(style.rawValue)).")
