// Draws AppIcon.icns: dark rounded square, red microphone, three level bars.
// Run once after changing the design: swift make-icon.swift
import AppKit

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let red = NSColor(red: 1.0, green: 0.22, blue: 0.30, alpha: 1)

    // macOS icon grid: the body fills about 80 % of the canvas.
    let body = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(red: 0.17, green: 0.17, blue: 0.21, alpha: 1),
               ending: NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    shape.lineWidth = max(size * 0.004, 1)
    shape.stroke()

    // Soft red glow behind the mic.
    let glow = NSRect(x: size * 0.28, y: size * 0.30, width: size * 0.44, height: size * 0.44)
    NSGradient(starting: red.withAlphaComponent(0.35), ending: red.withAlphaComponent(0))!
        .draw(in: NSBezierPath(ovalIn: glow), relativeCenterPosition: .zero)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.34, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [red]))
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let micSize = mic.size
        mic.draw(in: NSRect(x: (size - micSize.width) / 2, y: size * 0.30, width: micSize.width, height: micSize.height))
    }

    // Level bars under the mic: green, green, yellow.
    let colors = [NSColor.systemGreen, .systemGreen, .systemYellow]
    let barWidth = size * 0.07, gap = size * 0.03
    let left = (size - (3 * barWidth + 2 * gap)) / 2
    for (index, color) in colors.enumerated() {
        let height = size * (0.035 + 0.025 * CGFloat(index))
        let bar = NSRect(x: left + CGFloat(index) * (barWidth + gap), y: size * 0.18, width: barWidth, height: height)
        color.setFill()
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 3, yRadius: barWidth / 3).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "OK AppIcon.icns" : "FAIL iconutil \(task.terminationStatus)")
