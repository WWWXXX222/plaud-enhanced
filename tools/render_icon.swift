import AppKit

// Vector geometry is rendered at every macOS icon size for crisp small icons.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    graphics.cgContext.scaleBy(x: scale, y: scale)
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.set()
    NSColor(white: 0.09, alpha: 1).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.055, alpha: 1), ending: NSColor(white: 0.20, alpha: 1))!.draw(in: tile, angle: 90)
    let edge = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 192, yRadius: 192)
    NSColor.white.withAlphaComponent(0.19).setStroke(); edge.lineWidth = 2; edge.stroke()
    NSColor(white: 0.99, alpha: 1).setFill()
    let heights: [CGFloat] = [142, 264, 404, 264, 142]
    for (i, height) in heights.enumerated() {
        let rect = NSRect(x: 264 + CGFloat(i) * 108, y: 485 - height/2, width: 64, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 32, yRadius: 32).fill()
    }
    // Compact four-point spark for the added analysis capability.
    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: 744, y: 795))
    spark.curve(to: NSPoint(x: 806, y: 733), controlPoint1: NSPoint(x: 751, y: 753), controlPoint2: NSPoint(x: 765, y: 740))
    spark.curve(to: NSPoint(x: 744, y: 671), controlPoint1: NSPoint(x: 765, y: 726), controlPoint2: NSPoint(x: 751, y: 713))
    spark.curve(to: NSPoint(x: 682, y: 733), controlPoint1: NSPoint(x: 737, y: 713), controlPoint2: NSPoint(x: 723, y: 726))
    spark.curve(to: NSPoint(x: 744, y: 795), controlPoint1: NSPoint(x: 723, y: 740), controlPoint2: NSPoint(x: 737, y: 753))
    spark.close(); spark.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
