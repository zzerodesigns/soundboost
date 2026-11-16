import AppKit
import Foundation

// Generates a 1024x1024 Retina PNG master icon for SoundBoost:
// dark macOS squircle with subtle rim lighting and layered blue speaker waves.
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let canvasSize = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to allocate bitmap context.\n", stderr)
    exit(1)
}
bitmap.size = NSSize(width: canvasSize, height: canvasSize)

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Failed to create graphics context.\n", stderr)
    exit(1)
}
NSGraphicsContext.current = ctx

let cg = ctx.cgContext
cg.setAllowsAntialiasing(true)
cg.setShouldAntialias(true)

// Clear transparent canvas
cg.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

// Standard macOS squircle inset (824x824 centered inside 1024x1024)
let inset: CGFloat = 100
let squircleRect = CGRect(
    x: inset,
    y: inset,
    width: CGFloat(canvasSize) - inset * 2,
    height: CGFloat(canvasSize) - inset * 2
)
let cornerRadius: CGFloat = 185
let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)

// Soft ambient drop shadow beneath the squircle
cg.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.45)
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.shadowBlurRadius = 32
shadow.set()
NSColor(calibratedWhite: 0.08, alpha: 1.0).setFill()
squirclePath.fill()
cg.restoreGState()

// Clip interior of squircle
cg.saveGState()
squirclePath.addClip()

// Dark slate gradient background (#1E2430 top -> #0D1017 bottom)
let bgGradient = NSGradient(
    starting: NSColor(calibratedRed: 0.125, green: 0.150, blue: 0.200, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.047, green: 0.059, blue: 0.086, alpha: 1.0)
)
bgGradient?.draw(in: squircleRect, angle: -90)

// Centered radial blue glow inside the squircle (startRadius: 0 prevents an unfilled center hole)
let glowColors = [
    NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.98, alpha: 0.26).cgColor,
    NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.90, alpha: 0.0).cgColor
] as CFArray
if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
   let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
    let center = CGPoint(x: 512, y: 512)
    cg.drawRadialGradient(
        glowGradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: 420,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

// Crisp rim border inside the squircle
let borderRect = squircleRect.insetBy(dx: 2.0, dy: 2.0)
let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius - 2, yRadius: cornerRadius - 2)
borderPath.lineWidth = 4.0
NSColor(calibratedWhite: 1.0, alpha: 0.13).setStroke()
borderPath.stroke()

// Render SF Symbol speaker.wave.3.fill with layered cool-white body and vibrant blue waves
let paletteColors = [
    NSColor(calibratedRed: 0.93, green: 0.96, blue: 1.00, alpha: 1.0),
    NSColor(calibratedRed: 0.38, green: 0.65, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.96, alpha: 1.0)
]
let config = NSImage.SymbolConfiguration(pointSize: 360, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: paletteColors))

if let symbol = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symSize = symbol.size
    let drawRect = NSRect(
        x: (CGFloat(canvasSize) - symSize.width) / 2.0,
        y: (CGFloat(canvasSize) - symSize.height) / 2.0,
        width: symSize.width,
        height: symSize.height
    )
    symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
} else {
    fputs("Warning: speaker.wave.3.fill symbol unavailable.\n", stderr)
}

cg.restoreGState()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG.\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
