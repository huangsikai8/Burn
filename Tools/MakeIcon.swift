import AppKit

// Draws the Burn app icon and writes an .iconset ready for `iconutil`.
//
// A flame on a near-white squircle, drawn fresh at each size so small sizes stay
// crisp. Under the flame sit three bars of different lengths — per-app totals —
// which is what the app is about: what each app burns.

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setShouldAntialias(true)

    let inset = size * 0.024
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: body, xRadius: size * 0.165, yRadius: size * 0.165)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.024,
                  color: NSColor.black.withAlphaComponent(0.18).cgColor)
    NSColor.white.setFill()
    squircle.fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [color(254, 253, 252), color(243, 242, 241)])?.draw(in: body, angle: -90)
    ctx.restoreGState()

    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: body.minX + body.width * x, y: body.minY + body.height * y)
    }

    // Bars: per-app totals, the longest in the flame's colour.
    let bars: [(CGFloat, NSColor)] = [
        (0.56, color(245, 110, 40)),
        (0.38, color(250, 170, 70)),
        (0.22, color(210, 206, 202))
    ]
    for (i, bar) in bars.enumerated() {
        let height = body.height * 0.052
        let y = body.minY + body.height * (0.14 + CGFloat(bars.count - 1 - i) * 0.085)
        let rect = NSRect(x: body.minX + body.width * 0.22, y: y, width: body.width * bar.0, height: height)
        bar.1.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
    }

    // Outer flame.
    let flame = NSBezierPath()
    flame.move(to: p(0.50, 0.42))
    flame.curve(to: p(0.30, 0.60), controlPoint1: p(0.38, 0.42), controlPoint2: p(0.30, 0.50))
    flame.curve(to: p(0.44, 0.84), controlPoint1: p(0.30, 0.70), controlPoint2: p(0.40, 0.76))
    flame.curve(to: p(0.47, 0.93), controlPoint1: p(0.46, 0.87), controlPoint2: p(0.47, 0.90))
    flame.curve(to: p(0.70, 0.62), controlPoint1: p(0.60, 0.86), controlPoint2: p(0.70, 0.76))
    flame.curve(to: p(0.50, 0.42), controlPoint1: p(0.70, 0.50), controlPoint2: p(0.62, 0.42))
    flame.close()
    ctx.saveGState()
    flame.addClip()
    NSGradient(colors: [color(236, 64, 36), color(248, 128, 38), color(252, 176, 64)])?
        .draw(in: flame.bounds, angle: 90)
    ctx.restoreGState()

    // Inner flame.
    let inner = NSBezierPath()
    inner.move(to: p(0.50, 0.46))
    inner.curve(to: p(0.40, 0.57), controlPoint1: p(0.44, 0.46), controlPoint2: p(0.40, 0.51))
    inner.curve(to: p(0.51, 0.74), controlPoint1: p(0.40, 0.64), controlPoint2: p(0.47, 0.68))
    inner.curve(to: p(0.60, 0.57), controlPoint1: p(0.57, 0.69), controlPoint2: p(0.60, 0.63))
    inner.curve(to: p(0.50, 0.46), controlPoint1: p(0.60, 0.51), controlPoint2: p(0.56, 0.46))
    inner.close()
    ctx.saveGState()
    inner.addClip()
    NSGradient(colors: [color(255, 214, 120), color(255, 244, 200)])?.draw(in: inner.bounds, angle: 90)
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let image = drawIcon(size: pixels)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try? png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
print("Wrote \(output)")
