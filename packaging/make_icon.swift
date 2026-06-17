import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "packaging/AgenticFortress.icns")
let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.11, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.22, yRadius: size * 0.22).fill()

    NSColor(calibratedRed: 0.18, green: 0.68, blue: 0.56, alpha: 1).setFill()
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: size * 0.5, y: size * 0.86))
    shield.curve(to: NSPoint(x: size * 0.22, y: size * 0.72), controlPoint1: NSPoint(x: size * 0.4, y: size * 0.82), controlPoint2: NSPoint(x: size * 0.31, y: size * 0.77))
    shield.curve(to: NSPoint(x: size * 0.34, y: size * 0.2), controlPoint1: NSPoint(x: size * 0.22, y: size * 0.48), controlPoint2: NSPoint(x: size * 0.26, y: size * 0.3))
    shield.curve(to: NSPoint(x: size * 0.5, y: size * 0.1), controlPoint1: NSPoint(x: size * 0.39, y: size * 0.15), controlPoint2: NSPoint(x: size * 0.45, y: size * 0.12))
    shield.curve(to: NSPoint(x: size * 0.66, y: size * 0.2), controlPoint1: NSPoint(x: size * 0.55, y: size * 0.12), controlPoint2: NSPoint(x: size * 0.61, y: size * 0.15))
    shield.curve(to: NSPoint(x: size * 0.78, y: size * 0.72), controlPoint1: NSPoint(x: size * 0.74, y: size * 0.3), controlPoint2: NSPoint(x: size * 0.78, y: size * 0.48))
    shield.curve(to: NSPoint(x: size * 0.5, y: size * 0.86), controlPoint1: NSPoint(x: size * 0.69, y: size * 0.77), controlPoint2: NSPoint(x: size * 0.6, y: size * 0.82))
    shield.close()
    shield.fill()

    NSColor.white.withAlphaComponent(0.92).setFill()
    let font = NSFont.systemFont(ofSize: size * 0.28, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let text = "AF" as NSString
    let textSize = text.size(withAttributes: attributes)
    text.draw(
        at: NSPoint(x: (size - textSize.width) / 2, y: size * 0.42 - textSize.height / 2),
        withAttributes: attributes
    )

    return image
}

func writePNG(size: Int, scale: Int, name: String) throws {
    let pixelSize = size * scale
    let image = drawIcon(size: CGFloat(pixelSize))
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
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
