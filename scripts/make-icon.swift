#!/usr/bin/env swift
import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let output = args.first ?? "STFU.icns"
let sourceImageURL = args.dropFirst().first.map(URL.init(fileURLWithPath:))
let outputURL = URL(fileURLWithPath: output)
let fileManager = FileManager.default
let workURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("stfu-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = workURL.appendingPathComponent("STFU.iconset", isDirectory: true)

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func drawAspectFill(_ image: NSImage, in rect: NSRect) {
    let imageSize = image.size
    guard imageSize.width > 0, imageSize.height > 0 else {
        return
    }
    let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
    let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let drawRect = NSRect(
        x: rect.midX - drawSize.width / 2,
        y: rect.midY - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
}

func drawIcon(size: Int, sourceImage: NSImage?) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bitmapFormat: [],
        bytesPerRow: size * 4,
        bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "STFUIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap context"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let shape = NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) * 0.22, yRadius: CGFloat(size) * 0.22)
    NSGraphicsContext.current?.cgContext.saveGState()
    shape.addClip()
    if let sourceImage {
        drawAspectFill(sourceImage, in: rect)
        NSColor(calibratedWhite: 0.0, alpha: 0.38).setFill()
        rect.fill(using: .sourceOver)
    } else {
        NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
        shape.fill()
    }
    NSGraphicsContext.current?.cgContext.restoreGState()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let fontSize = CGFloat(size) * 0.285
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .black),
        .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        .strokeColor: NSColor.black.withAlphaComponent(0.35),
        .strokeWidth: -4,
        .paragraphStyle: paragraph
    ]
    let text = NSAttributedString(string: "STFU", attributes: attributes)
    let textHeight = text.size().height
    text.draw(in: NSRect(
        x: CGFloat(size) * 0.06,
        y: CGFloat(size) * 0.49 - textHeight / 2,
        width: CGFloat(size) * 0.88,
        height: textHeight * 1.2
    ))

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "STFUIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render icon"])
    }
    return png
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let sourceImage = sourceImageURL.flatMap { NSImage(contentsOf: $0) }
for (name, size) in specs {
    try drawIcon(size: size, sourceImage: sourceImage).write(to: iconsetURL.appendingPathComponent(name))
}

try? fileManager.removeItem(at: outputURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

try fileManager.removeItem(at: workURL)
if process.terminationStatus != 0 {
    throw NSError(domain: "STFUIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
