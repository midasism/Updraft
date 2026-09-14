import AppKit
import Foundation

// 多尺寸预览图：把 iconset 里各档 PNG 排在浅色画布上，输出 docs/icon-preview.png
// 用法：swift tools/IconPreview.swift <项目根目录>

let root = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: root).appendingPathComponent("dist/AppIcon.iconset")
let out = URL(fileURLWithPath: root).appendingPathComponent("docs/icon-preview.png")

let entries: [(file: String, label: String)] = [
    ("icon_512x512.png", "512"),
    ("icon_256x256.png", "256"),
    ("icon_128x128.png", "128"),
    ("icon_32x32@2x.png", "64"),
    ("icon_32x32.png", "32"),
    ("icon_16x16.png", "16")
]

let pad: CGFloat = 60
let labelH: CGFloat = 34
let colW: CGFloat = 560
let canvasW = pad * 2 + colW * CGFloat(entries.count)
let canvasH: CGFloat = 640

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvasW), pixelsHigh: Int(canvasH),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

NSColor(srgbRed: 0.955, green: 0.965, blue: 0.985, alpha: 1).set()
NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()

for (i, entry) in entries.enumerated() {
    let url = iconset.appendingPathComponent(entry.file)
    guard let img = NSImage(contentsOf: url) else { continue }
    let s = CGFloat(img.size.width)
    let x = pad + colW * CGFloat(i) + (colW - s) / 2
    let y = labelH + pad + (canvasH - labelH - pad * 2 - s) / 2
    img.draw(in: NSRect(x: x, y: y, width: s, height: s))

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.35, green: 0.42, blue: 0.55, alpha: 1)
    ]
    let str = NSAttributedString(string: entry.label, attributes: attrs)
    let strSize = str.size()
    str.draw(at: NSPoint(x: pad + colW * CGFloat(i) + (colW - strSize.width) / 2, y: 20))
}

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])?.write(to: out)
print(out.path)
