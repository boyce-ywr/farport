import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let outline = NSBezierPath(roundedRect: NSRect(x: 85, y: 85, width: 854, height: 854), xRadius: 190, yRadius: 190)
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
        NSColor(red: 0.07, green: 0.11, blue: 0.13, alpha: 1).setFill(); outline.fill()
        let noShadow = NSShadow(); noShadow.shadowColor = .clear; noShadow.set()
        NSGradient(colors: [NSColor(red: 0.15, green: 0.23, blue: 0.25, alpha: 1), NSColor(red: 0.035, green: 0.07, blue: 0.09, alpha: 1)])!.draw(in: outline, angle: -70)
        NSColor.white.withAlphaComponent(0.10).setStroke(); outline.lineWidth = 3; outline.stroke()
        let prompt = NSBezierPath(); prompt.move(to: NSPoint(x: 284, y: 653)); prompt.line(to: NSPoint(x: 456, y: 510)); prompt.line(to: NSPoint(x: 284, y: 367)); prompt.lineWidth = 62; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
        NSColor(red: 0.35, green: 0.9, blue: 0.74, alpha: 1).setStroke(); prompt.stroke()
        let cursor = NSBezierPath(); cursor.move(to: NSPoint(x: 542, y: 371)); cursor.line(to: NSPoint(x: 730, y: 371)); cursor.lineWidth = 55; cursor.lineCapStyle = .round; cursor.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
}
