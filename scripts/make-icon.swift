#!/usr/bin/env swift

// Generates Resources/AppIcon.icns.
//
// The icon is drawn from paths rather than reusing the menubar's SF Symbol:
// Apple's SF Symbols license does not permit using symbols in app icons.
//
// Everything is drawn in a 1024x1024 design space and scaled per output size,
// so tweaking a coordinate here changes every resolution at once.
//
// Run: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

import AppKit

let cream = NSColor(srgbRed: 1.00, green: 0.97, blue: 0.92, alpha: 1).cgColor

func draw(_ ctx: CGContext) {
    // Background squircle. 824pt inset in a 1024pt canvas with a 185pt corner
    // radius is the macOS Big Sur icon grid — matching it keeps the icon the
    // same visual weight as system apps in the Dock and Finder.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(srgbRed: 0.76, green: 0.53, blue: 0.35, alpha: 1).cgColor,
                 NSColor(srgbRed: 0.38, green: 0.23, blue: 0.14, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100),
                           options: [])
    ctx.restoreGState()

    // Handle first, so the cup body overlaps where they meet and hides the seam.
    ctx.saveGState()
    ctx.setStrokeColor(cream)
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    // Centre sits left of the cup's right edge on purpose: the arc endpoints
    // must land *inside* the body, or the handle reads as a detached crescent.
    ctx.addArc(center: CGPoint(x: 642, y: 528), radius: 104,
               startAngle: -1.1, endAngle: 1.1, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // Cup body: a tapered vessel, wider at the rim than the base.
    let cup = CGMutablePath()
    cup.move(to: CGPoint(x: 322, y: 616))
    cup.addLine(to: CGPoint(x: 702, y: 616))
    cup.addLine(to: CGPoint(x: 664, y: 424))
    cup.addQuadCurve(to: CGPoint(x: 596, y: 366), control: CGPoint(x: 652, y: 374))
    cup.addLine(to: CGPoint(x: 428, y: 366))
    cup.addQuadCurve(to: CGPoint(x: 360, y: 424), control: CGPoint(x: 372, y: 374))
    cup.closeSubpath()
    ctx.setFillColor(cream)
    ctx.addPath(cup)
    ctx.fillPath()

    // Saucer, overlapping the cup base by 2pt so the two read as one object
    // rather than a cup hovering above a bar.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 252, y: 304, width: 520, height: 62),
                       cornerWidth: 31, cornerHeight: 31, transform: nil))
    ctx.fillPath()

    // Steam. Drawn semi-transparent so it reads as vapour and, more practically,
    // so it recedes at 16pt instead of turning the top half into noise.
    ctx.saveGState()
    ctx.setStrokeColor(cream.copy(alpha: 0.72)!)
    ctx.setLineWidth(36)
    ctx.setLineCap(.round)
    for dx in [-124.0, 0.0, 124.0] {
        let x = 512 + dx
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: 672))
        path.addCurve(to: CGPoint(x: x, y: 822),
                      control1: CGPoint(x: x - 66, y: 718),
                      control2: CGPoint(x: x + 66, y: 776))
        ctx.addPath(path)
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed at \(pixels)px")
    }
    return png
}

// The filenames are fixed by iconutil — it rejects an iconset with unexpected
// names, so this table is a contract, not a preference.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",     32),
    ("icon_32x32",      32), ("icon_32x32@2x",     64),
    ("icon_128x128",   128), ("icon_128x128@2x",  256),
    ("icon_256x256",   256), ("icon_256x256@2x",  512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

let iconset = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: iconset,
                                         withIntermediateDirectories: true)
for variant in variants {
    let path = "\(iconset)/\(variant.name).png"
    try! render(variant.pixels).write(to: URL(fileURLWithPath: path))
}
print("wrote \(variants.count) sizes to \(iconset)")
