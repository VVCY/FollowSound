// 配色方案取自 JIZURA (https://github.com/852wa/JIZURA) 的 24 个 style pack，
// MIT License, Copyright (c) 2026 hakoniwa (852wa)。原本是整帧底色/文字色，
// 这里只取每个包里最可见的一支作为光带主色，另一支做副色。

import AppKit

struct Theme {
    let key: String
    let name: String
    let accent: NSColor
    let second: NSColor
    /// 色差错位用的两支"重影"色，取自 JIZURA 各 pack 的 ghostA / ghostB。
    /// 原方案里这两色是画在深色整帧上的，搬到透明悬浮层上偏暗的会直接看不见，
    /// 所以使用时还要过一道提亮/拉开色相的检查（见 StyleView.chromaGhosts）。
    let ghostA: NSColor
    let ghostB: NSColor

    init(key: String, name: String, accent: NSColor, second: NSColor,
         ghostA: String? = nil, ghostB: String? = nil) {
        self.key = key
        self.name = name
        self.accent = accent
        self.second = second
        self.ghostA = NSColor(hex: ghostA ?? "#FFFFFF")
        self.ghostB = NSColor(hex: ghostB ?? "#FFFFFF")
    }

    static let all: [Theme] = [
        Theme(key: "noir", name: "黑金偏色", accent: NSColor(hex: "#F5A50C"), second: NSColor(hex: "#16F4D4"), ghostA: "#F5A50C", ghostB: "#16F4D4"),
        Theme(key: "crimson", name: "深红信号", accent: NSColor(hex: "#FF3D6E"), second: NSColor(hex: "#39F2C8"), ghostA: "#FFFFFF", ghostB: "#39F2C8"),
        Theme(key: "caution", name: "警戒黄黑", accent: NSColor(hex: "#F4D21F"), second: NSColor(hex: "#141414"), ghostA: "#E0231C", ghostB: "#1F3FD8"),
        Theme(key: "magenta", name: "品红波普", accent: NSColor(hex: "#FF8CC8"), second: NSColor(hex: "#2B2BD9"), ghostA: "#FF8CC8", ghostB: "#2B2BD9"),
        Theme(key: "paper", name: "纸与墨", accent: NSColor(hex: "#C2185B"), second: NSColor(hex: "#1B2350"), ghostA: "#C2185B", ghostB: "#1B2350"),
        Theme(key: "hud", name: "暗色 HUD", accent: NSColor(hex: "#F25A2B"), second: NSColor(hex: "#7FD7FF"), ghostA: "#F25A2B", ghostB: "#7FD7FF"),
        Theme(key: "mint", name: "薄荷终端", accent: NSColor(hex: "#9CFF3A"), second: NSColor(hex: "#FF3B6B"), ghostA: "#FF3B6B", ghostB: "#2EE6C8"),
        Theme(key: "specimen", name: "标本", accent: NSColor(hex: "#F2F0EC"), second: NSColor(hex: "#6E6A66"), ghostA: "#6E6A66", ghostB: "#C8B98C"),
        Theme(key: "transit", name: "站牌", accent: NSColor(hex: "#E8C21A"), second: NSColor(hex: "#1A1A1A"), ghostA: "#E8C21A", ghostB: "#1A1A1A"),
        Theme(key: "blueprint", name: "蓝图", accent: NSColor(hex: "#8C8CFF"), second: NSColor(hex: "#000000"), ghostA: "#000000", ghostB: "#8C8CFF"),
        Theme(key: "rouge", name: "胭脂", accent: NSColor(hex: "#E3141F"), second: NSColor(hex: "#FFFFFF"), ghostA: "#D40F1C", ghostB: "#6B6866"),
        Theme(key: "mono", name: "单色 RGB", accent: NSColor(hex: "#FFE34D"), second: NSColor(hex: "#2AFF7A"), ghostA: "#FF2A2A", ghostB: "#2AA8FF"),
        Theme(key: "sakura", name: "樱花", accent: NSColor(hex: "#D93A74"), second: NSColor(hex: "#6F8F4E"), ghostA: "#EC6A9A", ghostB: "#9A8AE6"),
        Theme(key: "ocean", name: "深海", accent: NSColor(hex: "#1FD2E6"), second: NSColor(hex: "#3B5BFF"), ghostA: "#1FD2E6", ghostB: "#3B5BFF"),
        Theme(key: "sunset", name: "晚霞", accent: NSColor(hex: "#FF7A30"), second: NSColor(hex: "#B84BFF"), ghostA: "#FF7A30", ghostB: "#B84BFF"),
        Theme(key: "forest", name: "森之帖", accent: NSColor(hex: "#B7C95A"), second: NSColor(hex: "#C4833F"), ghostA: "#8FB04A", ghostB: "#C4833F"),
        Theme(key: "vapor", name: "蒸汽波", accent: NSColor(hex: "#FF8FD8"), second: NSColor(hex: "#7DF9FF"), ghostA: "#FF71CE", ghostB: "#01CDFE"),
        Theme(key: "newsprint", name: "报纸", accent: NSColor(hex: "#F5D300"), second: NSColor(hex: "#00A0E9"), ghostA: "#E4007F", ghostB: "#00A0E9"),
        Theme(key: "synth80", name: "合成 80s", accent: NSColor(hex: "#22E6FF"), second: NSColor(hex: "#FFE45C"), ghostA: "#22E6FF", ghostB: "#6A3BFF"),
        Theme(key: "kraft", name: "牛皮纸", accent: NSColor(hex: "#B8361B"), second: NSColor(hex: "#2E5E8C"), ghostA: "#C33A1F", ghostB: "#2E5E8C"),
        Theme(key: "candy", name: "糖果", accent: NSColor(hex: "#EE3A88"), second: NSColor(hex: "#8A6BFF"), ghostA: "#FF5FA2", ghostB: "#8A6BFF"),
        Theme(key: "acid", name: "酸液", accent: NSColor(hex: "#FF2BD6"), second: NSColor(hex: "#3D5BFF"), ghostA: "#FF2BD6", ghostB: "#3D5BFF"),
        Theme(key: "sumi", name: "墨与朱", accent: NSColor(hex: "#B83A22"), second: NSColor(hex: "#FFFFFF"), ghostA: "#9A9284", ghostB: "#CC4A2E"),
        Theme(key: "gold", name: "金夜", accent: NSColor(hex: "#D4AF37"), second: NSColor(hex: "#FFFFFF"), ghostA: "#D4AF37", ghostB: "#7A5230"),
    ]

    static func named(_ key: String) -> Theme {
        all.first { $0.key == key } ?? all[0]
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 感知亮度（Rec.709 权重）
    var luma: CGFloat {
        let s = usingColorSpace(.sRGB) ?? self
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }

    /// 色相旋转；色相距离在这里是 0…0.5 的环形距离
    func hueShifted(by delta: CGFloat) -> NSColor {
        let s = usingColorSpace(.sRGB) ?? self
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        s.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        // 灰阶没有色相，直接给个饱和度，否则转了也还是灰的
        return NSColor(hue: (h + delta).truncatingRemainder(dividingBy: 1),
                       saturation: max(sat, 0.55),
                       brightness: min(1, max(b, 0.75)),
                       alpha: a)
    }

    static func hueDistance(_ x: NSColor, _ y: NSColor) -> CGFloat {
        let a = x.usingColorSpace(.sRGB) ?? x
        let b = y.usingColorSpace(.sRGB) ?? y
        var ha: CGFloat = 0, sa: CGFloat = 0, va: CGFloat = 0, aa: CGFloat = 0
        var hb: CGFloat = 0, sb: CGFloat = 0, vb: CGFloat = 0, ab: CGFloat = 0
        a.getHue(&ha, saturation: &sa, brightness: &va, alpha: &aa)
        b.getHue(&hb, saturation: &sb, brightness: &vb, alpha: &ab)
        var d = abs(ha - hb)
        if d > 0.5 { d = 1 - d }
        return d
    }
}
