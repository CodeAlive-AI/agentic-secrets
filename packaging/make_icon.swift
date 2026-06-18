import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "packaging/AgenticSecrets.icns")
let sourcePath = ProcessInfo.processInfo.environment["AGENTIC_SECRETS_ICON_SOURCE_PATH"] ?? "packaging/AgenticSecretsIconSource.png"
let sourceURL = URL(fileURLWithPath: sourcePath)
let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")

guard FileManager.default.fileExists(atPath: sourceURL.path) else {
    fputs("Missing icon source PNG: \(sourceURL.path)\n", stderr)
    exit(1)
}

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fputs("Could not load icon source PNG: \(sourceURL.path)\n", stderr)
    exit(1)
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func sourceBitmap(from image: NSImage) throws -> NSBitmapImageRep {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return bitmap
}

func drawResizedIcon(from image: NSImage, pixelSize: Int) throws -> NSBitmapImageRep {
    let source = try sourceBitmap(from: image)
    let sourceWidth = source.pixelsWide
    let sourceHeight = source.pixelsHigh
    let cropSide = min(sourceWidth, sourceHeight)
    let crop = CGRect(
        x: CGFloat(sourceWidth - cropSide) / 2,
        y: CGFloat(sourceHeight - cropSide) / 2,
        width: CGFloat(cropSide),
        height: CGFloat(cropSide)
    )

    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    output.size = NSSize(width: pixelSize, height: pixelSize)

    guard let context = NSGraphicsContext(bitmapImageRep: output) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)).fill()
    source.draw(
        in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: crop,
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    return output
}

func writePNG(size: Int, scale: Int, name: String) throws {
    let pixelSize = size * scale
    let bitmap = try drawResizedIcon(from: sourceImage, pixelSize: pixelSize)
    guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: iconsetURL.appendingPathComponent(name))
}

try writePNG(size: 16, scale: 1, name: "icon_16x16.png")
try writePNG(size: 16, scale: 2, name: "icon_16x16@2x.png")
try writePNG(size: 32, scale: 1, name: "icon_32x32.png")
try writePNG(size: 32, scale: 2, name: "icon_32x32@2x.png")
try writePNG(size: 128, scale: 1, name: "icon_128x128.png")
try writePNG(size: 128, scale: 2, name: "icon_128x128@2x.png")
try writePNG(size: 256, scale: 1, name: "icon_256x256.png")
try writePNG(size: 256, scale: 2, name: "icon_256x256@2x.png")
try writePNG(size: 512, scale: 1, name: "icon_512x512.png")
try writePNG(size: 512, scale: 2, name: "icon_512x512@2x.png")
