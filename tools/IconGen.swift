import AppKit
import Foundation

// 生成 Updraft 的图标集。用法：swift tools/IconGen.swift <输出目录>
//
// 设计概念「Updraft · 上升气流」：
//   主图形 = 一枚圆润的白色向上箭头（升级），下方两条逐渐变淡的气流托带（上升气流），
//   语义：气流把应用托举到最新版本。
//   底色 = 晴空蓝青三段渐变 + 顶部玻璃高光 + 内侧描边，明亮通透。
// 按每档尺寸重新绘制并逐级简化：小尺寸砍掉高光/描边/阴影和气流带，只保留最核心轮廓。

func drawArrow(in size: CGFloat, cx: CGFloat, scale: CGFloat, alpha: CGFloat) {
    // 箭头：圆头箭杆 + 三角箭头，scale 用于小尺寸加粗
    let shaftWidth = size * 0.10 * scale
    let shaftBottom = size * 0.40
    let shaftTop = size * 0.62
    let shaft = NSRect(
        x: cx - shaftWidth / 2,
        y: shaftBottom,
        width: shaftWidth,
        height: shaftTop - shaftBottom
    )

    let headHalfWidth = size * 0.155 * scale
    let head = NSBezierPath()
    head.move(to: NSPoint(x: cx, y: size * 0.78))
    head.line(to: NSPoint(x: cx - headHalfWidth, y: size * 0.585))
    head.line(to: NSPoint(x: cx + headHalfWidth, y: size * 0.585))
    head.close()

    NSColor.white.withAlphaComponent(alpha).set()
    NSBezierPath(roundedRect: shaft, xRadius: shaftWidth / 2, yRadius: shaftWidth / 2).fill()
    head.fill()
}

func drawBand(in size: CGFloat, cx: CGFloat, apexY: CGFloat, width: CGFloat,
              stroke: CGFloat, alpha: CGFloat) {
    // 气流托带：V 形折线（圆角端点/接头），像一层上升的气流
    let drop = size * 0.115
    let band = NSBezierPath()
    band.move(to: NSPoint(x: cx - width / 2, y: apexY - drop))
    band.line(to: NSPoint(x: cx, y: apexY))
    band.line(to: NSPoint(x: cx + width / 2, y: apexY - drop))
    band.lineWidth = stroke
    band.lineCapStyle = .round
    band.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(alpha).set()
    band.stroke()
}

func drawIcon(in size: CGFloat) {
    let inset = size * 0.055
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.2237
    let cx = size / 2
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // ---- 底色：晴空蓝青三段渐变（顶亮底稳，不沉闷） ----
    let skyTop = NSColor(srgbRed: 0.478, green: 0.851, blue: 1.000, alpha: 1) // #7AD9FF
    let skyMid = NSColor(srgbRed: 0.243, green: 0.655, blue: 0.969, alpha: 1) // #3EA7F7
    let skyBot = NSColor(srgbRed: 0.180, green: 0.482, blue: 0.949, alpha: 1) // #2E7BF2
    let gradient = NSGradient(colors: [skyTop, skyMid, skyBot], atLocations: [0, 0.55, 1], colorSpace: .sRGB)
    gradient?.draw(in: squircle, angle: -90)

    let detailed = size >= 128   // 高光 / 描边 / 阴影只在大尺寸出现
    let twoBands = size >= 64    // 32px 只留一条气流带，16px 只留箭头

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // ---- 顶部玻璃高光：白色渐隐椭圆，通透感来源 ----
    if detailed {
        let gloss = NSBezierPath(ovalIn: NSRect(
            x: body.minX - body.width * 0.15,
            y: body.maxY - body.height * 0.42,
            width: body.width * 1.3,
            height: body.height * 0.72
        ))
        let glossGradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.34),
            NSColor.white.withAlphaComponent(0)
        ])
        glossGradient?.draw(in: gloss, angle: -90)
    }

    // ---- 主图形：柔和投影 + 白色箭头 + 气流托带 ----
    NSGraphicsContext.saveGraphicsState()
    if detailed {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.05, green: 0.25, blue: 0.60, alpha: 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.010)
        shadow.shadowBlurRadius = size * 0.018
        shadow.set()
    }

    if twoBands {
        drawBand(in: size, cx: cx, apexY: size * 0.28, width: size * 0.28,
                 stroke: size * 0.062, alpha: 0.45)
        drawBand(in: size, cx: cx, apexY: size * 0.415, width: size * 0.36,
                 stroke: size * 0.072, alpha: 0.80)
    } else if size >= 32 {
        drawBand(in: size, cx: cx, apexY: size * 0.36, width: size * 0.34,
                 stroke: size * 0.085, alpha: 0.75)
    }
    let arrowScale: CGFloat = size < 32 ? 1.22 : 1.0  // 小尺寸把箭头加粗，保证辨识
    drawArrow(in: size, cx: cx, scale: arrowScale, alpha: 1)
    NSGraphicsContext.restoreGraphicsState()

    // ---- 内侧描边：白色细边勾勒轮廓，精致感来源 ----
    if detailed {
        let lineWidth = max(size * 0.006, 0.75)
        let inner = NSBezierPath(
            roundedRect: body.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: radius - lineWidth / 2, yRadius: radius - lineWidth / 2
        )
        inner.lineWidth = lineWidth
        NSColor.white.withAlphaComponent(0.22).set()
        inner.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
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
