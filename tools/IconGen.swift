import AppKit
import Foundation

// 生成 AppUpdater 的图标集。用法：swift tools/IconGen.swift <输出目录>

func drawIcon(in size: CGFloat) {
    let inset = size * 0.055
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.2237

    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.373, green: 0.573, blue: 0.976, alpha: 1),
        NSColor(srgbRed: 0.098, green: 0.286, blue: 0.769, alpha: 1)
    ])
    gradient?.draw(in: squircle, angle: -90)

    NSColor.white.set()

    // 向上的箭头：箭杆 + 箭头
    let shaftWidth = size * 0.098
    let shaftBottom = size * 0.345
    let shaftTop = size * 0.575
    let shaft = NSRect(
        x: (size - shaftWidth) / 2,
        y: shaftBottom,
        width: shaftWidth,
        height: shaftTop - shaftBottom
    )
    NSBezierPath(roundedRect: shaft, xRadius: shaftWidth / 2, yRadius: shaftWidth / 2).fill()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: size * 0.5, y: size * 0.745))
    head.line(to: NSPoint(x: size * 0.5 - size * 0.155, y: size * 0.545))
    head.line(to: NSPoint(x: size * 0.5 + size * 0.155, y: size * 0.545))
    head.close()
    head.fill()

    // 底座托盘
    let trayWidth = size * 0.44
    let trayHeight = size * 0.072
    let tray = NSRect(
        x: (size - trayWidth) / 2,
        y: size * 0.235,
        width: trayWidth,
        height: trayHeight
    )
    NSBezierPath(roundedRect: tray, xRadius: trayHeight / 2, yRadius: trayHeight / 2).fill()
}

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift tools/IconGen.swift <输出目录>\n".utf8))
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
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

for variant in variants {
    guard let data = renderPNG(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("渲染 \(variant.name) 失败\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name))
}

print(iconset.path)
