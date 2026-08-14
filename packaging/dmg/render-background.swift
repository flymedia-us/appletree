#!/usr/bin/env swift
import AppKit

/// Renders the drag-and-drop DMG window background at 1x and 2x.
///
/// Layout is in window points (660×400). Icon positions in
/// `scripts/package-dmg.sh` must stay aligned with the chevron drawn here:
/// AppleTree.app at (168, 190), Applications at (492, 190).

let windowSize = NSSize(width: 660, height: 400)

func drawBackground() {
    let bounds = NSRect(origin: .zero, size: windowSize)

    NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
    bounds.fill()

    let tileColors: [NSColor] = [
        NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.90, alpha: 0.10),
        NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.18, alpha: 0.10),
        NSColor(calibratedRed: 0.48, green: 0.82, blue: 0.28, alpha: 0.09),
        NSColor(calibratedRed: 0.48, green: 0.38, blue: 0.92, alpha: 0.10),
        NSColor(calibratedRed: 0.94, green: 0.85, blue: 0.22, alpha: 0.08),
        NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.27, alpha: 0.09),
        NSColor(calibratedRed: 0.78, green: 0.22, blue: 0.78, alpha: 0.09),
    ]
    let tiles: [NSRect] = [
        NSRect(x: -20, y: 310, width: 150, height: 120),
        NSRect(x: 140, y: 340, width: 90, height: 80),
        NSRect(x: 540, y: 300, width: 160, height: 130),
        NSRect(x: -10, y: -20, width: 110, height: 90),
        NSRect(x: 560, y: -30, width: 140, height: 100),
        NSRect(x: 470, y: -10, width: 80, height: 55),
        NSRect(x: 80, y: -25, width: 70, height: 50),
    ]
    for (rect, color) in zip(tiles, tileColors) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }

    let title = "AppleTree" as NSString
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
    ]
    let titleSize = title.size(withAttributes: titleAttrs)
    // Unflipped AppKit coordinates: y=0 is the bottom of the window.
    title.draw(
        at: NSPoint(x: (windowSize.width - titleSize.width) / 2, y: 352),
        withAttributes: titleAttrs
    )

    let subtitle = "Drag to Applications" as NSString
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
    ]
    let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
    subtitle.draw(
        at: NSPoint(x: (windowSize.width - subtitleSize.width) / 2, y: 328),
        withAttributes: subtitleAttrs
    )

    // 190pt from the top matches --icon / --app-drop-link in package-dmg.sh.
    drawChevron(center: NSPoint(x: 330, y: windowSize.height - 190))
}

func drawChevron(center: NSPoint) {
    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = 8
    path.move(to: NSPoint(x: center.x - 14, y: center.y + 22))
    path.line(to: NSPoint(x: center.x + 16, y: center.y))
    path.line(to: NSPoint(x: center.x - 14, y: center.y - 22))
    NSColor(calibratedWhite: 1, alpha: 0.38).setStroke()
    path.stroke()
}

func writePNG(scale: CGFloat, url: URL) throws {
    let pixelWidth = Int(windowSize.width * scale)
    let pixelHeight = Int(windowSize.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("error: could not create bitmap\n", stderr)
        exit(1)
    }
    rep.size = windowSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("error: could not encode PNG\n", stderr)
        exit(1)
    }
    try data.write(to: url, options: .atomic)
}

let here = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
try writePNG(scale: 1, url: here.appendingPathComponent("background.png"))
try writePNG(scale: 2, url: here.appendingPathComponent("background@2x.png"))

let twoX = here.appendingPathComponent("background@2x.png").path
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
proc.arguments = [
    "-s", "dpiWidth", "144",
    "-s", "dpiHeight", "144",
    twoX,
]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    fputs("warning: sips failed to set 144 dpi on background@2x.png\n", stderr)
}

print("wrote \(here.path)/background.png")
print("wrote \(here.path)/background@2x.png")
