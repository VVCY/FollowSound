// FollowSound 图标渲染器
// 设计语言：白底透明 —— 纯白声波柱，透明画布，只在白色背景前靠极轻的投影找回轮廓。
// 一套几何同时出：App 图标（icns）、菜单栏模板图标、Windows ico、Android mipmap、网页 logo。
//
// 用法：swiftc -O make_icons.swift -o /tmp/make_icons && /tmp/make_icons <输出目录>

import AppKit
import CoreGraphics
import Foundation

// 声波柱：高度比例（0…1）。以中线对称排布，从左到右起-落-收，
// 像一句说完的话，而不是一根镜像对称的杠。
let bars: [CGFloat] = [0.26, 0.54, 0.82, 1.00, 0.76, 0.48, 0.28]
// 菜单栏尺寸下柱子太多会糊成一团，只留 5 根
let statusBars: [CGFloat] = [0.40, 0.74, 1.00, 0.62, 0.34]

func roundedBar(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) {
    let rect = CGRect(x: x, y: y, width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: min(r, w / 2), cornerHeight: min(r, w / 2), transform: nil)
    ctx.addPath(path)
}

/// 画一组柱子。柱子沿中线对称展开（每个都从 centerY 向上下各长 h/2），
/// 这样任何尺寸下都不会出现"顶边对齐像水滴"的错觉。
func drawBars(_ ctx: CGContext, heights: [CGFloat], box: CGRect, centerY: CGFloat,
              maxH: CGFloat, color: NSColor, shadow: Bool, shadowScale: CGFloat) {
    let n = CGFloat(heights.count)
    let gapRatio: CGFloat = 0.62          // 间隙 / 柱宽
    let w = box.width / (n + (n - 1) * gapRatio)
    let gap = w * gapRatio
    let r = w / 2

    func path() {
        for (i, hh) in heights.enumerated() {
            let h = max(w, maxH * hh)
            let x = box.minX + CGFloat(i) * (w + gap)
            roundedBar(ctx, x: x, y: centerY - h / 2, w: w, h: h, r: r)
        }
    }

    ctx.saveGState()
    if shadow {
        // 透明画布上的白色图形放到浅色背景会糊掉，用一层极轻的投影把边缘找回来。
        // 深色背景上这层投影不可见，不破坏"白底透明"。
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * shadowScale),
                      blur: 26 * shadowScale,
                      color: NSColor.black.withAlphaComponent(0.22).cgColor)
    }
    ctx.setFillColor(color.cgColor)
    path()
    ctx.fillPath()
    ctx.restoreGState()
}

func makeContext(_ size: Int) -> CGContext? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // 保持 CoreGraphics 原生坐标（y 向上），柱子围绕中线对称，方向不影响观感，
    // 也就不会再踩"翻转后柱子变成倒挂"的坑。
    return ctx
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

/// App 图标：透明底 + 白色声波柱，柱子占画布 74%，垂直居中略偏下
func appIcon(_ size: Int) -> CGImage? {
    guard let ctx = makeContext(size) else { return nil }
    let S = CGFloat(size)
    let box = CGRect(x: S * 0.13, y: 0, width: S * 0.74, height: S)
    let maxH = S * 0.62
    drawBars(ctx, heights: bars, box: box, centerY: S * 0.5, maxH: maxH,
             color: .white, shadow: true, shadowScale: S / 1024)
    return ctx.makeImage()
}

/// 菜单栏图标：模板图，只画纯白图形（系统按菜单栏明暗自动反色）
func statusIcon(_ size: Int) -> CGImage? {
    guard let ctx = makeContext(size) else { return nil }
    let S = CGFloat(size)
    let box = CGRect(x: S * 0.10, y: 0, width: S * 0.80, height: S)
    drawBars(ctx, heights: statusBars, box: box, centerY: S * 0.5, maxH: S * 0.80,
             color: .white, shadow: false, shadowScale: 1)
    return ctx.makeImage()
}

// MARK: - 输出

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// 1) App 图标全尺寸 → iconset，交给 iconutil 打 icns
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        guard let img = appIcon(px) else { continue }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(img, "\(iconset)/\(name)")
    }
}

// 2) 菜单栏模板图标 18pt @1x/@2x
if let i = statusIcon(18) { writePNG(i, "\(outDir)/StatusIcon.png") }
if let i = statusIcon(36) { writePNG(i, "\(outDir)/StatusIcon@2x.png") }

// 3) 通用 PNG（Windows ico / Android mipmap / 网页 og 图都用它再转）
for s in [16, 32, 48, 64, 128, 256, 512, 1024] {
    if let i = appIcon(s) { writePNG(i, "\(outDir)/icon-\(s).png") }
}

// 4) 深色底预览图，用来肉眼检查图标在深色界面的观感
if let ctx = makeContext(512) {
    ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    if let g = appIcon(512) { ctx.draw(g, in: CGRect(x: 0, y: 0, width: 512, height: 512)) }
    if let img = ctx.makeImage() { writePNG(img, "\(outDir)/preview-dark.png") }
}
print("icons written to \(outDir)")
