import AppKit
import Foundation

// 生成 DMG 安装窗口的背景图。用法：swift tools/DmgBackground.swift <输出目录>
//
// 这个窗口的布局是死的：左边 Updraft.app，右边 Applications 软链，中间一个指向右的箭头。
// **箭头和说明文字都得画进背景图里**——Finder 只负责画图标和图标下面的文件名，它不会替你
// 画箭头。所以这里的像素尺寸必须和 scripts/dmg-settings.py 里的 window_rect / icon_locations
// 严格对应，错一个数箭头就和图标对不齐。
//
// 坐标系：AppKit 画布原点在左下角，与 Finder 的 icon_locations 一致（y 从下往上），
// 所以下面的 y 值可以直接照抄 dmg-settings.py，不用换算。
//
// 出两份：dmg-background.png（1x）+ dmg-background@2x.png（2x）。dmgbuild 会自动发现同目录的
// @2x 并调 tiffutil 合成多分辨率 TIFF，retina 屏上才不会糊。所以两份必须成对生成，
// 且文件名严格是 <name>.png / <name>@2x.png。

let designWidth: CGFloat = 660
let designHeight: CGFloat = 420

// 与 dmg-settings.py 的 icon_locations 保持一致
let iconCenterY: CGFloat = 205

func drawBackground(scale: CGFloat) {
    let width = designWidth * scale
    let height = designHeight * scale
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)

    // ---- 底色：极浅的晴空蓝，上浅下深。和图标同色系，但不能抢图标 ----
    let topColor = NSColor(srgbRed: 0.988, green: 0.996, blue: 1.000, alpha: 1)    // #FCFEFF
    let bottomColor = NSColor(srgbRed: 0.925, green: 0.953, blue: 0.996, alpha: 1) // #ECF3FE
    NSGradient(starting: topColor, ending: bottomColor)?.draw(in: canvas, angle: -90)

    // ---- 中间的箭头：杆 + 三角头，一个封闭路径填渐变 ----
    let cy = iconCenterY * scale
    let shaftLeft: CGFloat = 252 * scale
    let shaftRight: CGFloat = 374 * scale
    let tipX: CGFloat = 408 * scale
    let shaftHalf: CGFloat = 7 * scale
    let headHalf: CGFloat = 26 * scale

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: shaftLeft, y: cy - shaftHalf))
    arrow.line(to: NSPoint(x: shaftRight, y: cy - shaftHalf))
    arrow.line(to: NSPoint(x: shaftRight, y: cy - headHalf))
    arrow.line(to: NSPoint(x: tipX, y: cy))
    arrow.line(to: NSPoint(x: shaftRight, y: cy + headHalf))
    arrow.line(to: NSPoint(x: shaftRight, y: cy + shaftHalf))
    arrow.line(to: NSPoint(x: shaftLeft, y: cy + shaftHalf))
    arrow.close()

    let arrowTop = NSColor(srgbRed: 0.588, green: 0.827, blue: 0.996, alpha: 0.90) // #96D3FE
    let arrowBottom = NSColor(srgbRed: 0.310, green: 0.647, blue: 0.949, alpha: 0.90) // #4FA5F2
    NSGraphicsContext.saveGraphicsState()
    arrow.addClip()
    NSGradient(starting: arrowTop, ending: arrowBottom)?.draw(in: arrow.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // ---- 底部说明文字 ----
    let caption = "拖进「应用程序」以完成安装"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13 * scale, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.478, green: 0.529, blue: 0.608, alpha: 1) // #7A879B
    ]
    let text = NSAttributedString(string: caption, attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(
        x: (width - textSize.width) / 2,
        y: 58 * scale - textSize.height / 2
    ))
}

func renderPNG(scale: CGFloat) -> Data? {
    let pixelsWide = Int(designWidth * scale)
    let pixelsHigh = Int(designHeight * scale)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
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
    drawBackground(scale: scale)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift tools/DmgBackground.swift <输出目录>\n".utf8))
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// 1x 与 2x 必须成对产出，dmgbuild 靠 @2x 后缀这一对来合成 HiDPI 背景
for (name, scale) in [("dmg-background.png", CGFloat(1)), ("dmg-background@2x.png", CGFloat(2))] {
    guard let data = renderPNG(scale: scale) else {
        FileHandle.standardError.write(Data("渲染 \(name) 失败\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}

print(outputDirectory.appendingPathComponent("dmg-background.png").path)
