import AppKit
import AVFoundation
import ApplicationServices
import Accelerate

// ============ 可调参数 ============
// 特效最高点（pt），同时也是底部浮窗的高度。菜单「高度」里可改，选择会记住。
// 所有特效都是按「占满这个高度的百分比」算的，所以改这一个数就整体缩放。
var maxBandHeight: CGFloat = {
    let v = UserDefaults.standard.double(forKey: "bandHeight")
    return v >= 80 ? CGFloat(v) : 180
}()
/// 浮窗在「最高高度」之上额外留出的透明余量（pt）。
/// 横向光斑、顶部光晕都画在带顶之上；不留余量的话满音量时它们会被窗口上沿裁掉，
/// 表现为"这一档特效什么都没画"。
let overlayHeadroom: CGFloat = 56

let noiseFloorDB: Float = -55         // 低于此值当静音（自适应峰值的下限锚点）

// 包络跟随：起得快、落得慢，才像"光升起"而不是"数字跳动"
let attackRate: CGFloat = 0.55
let releaseRate: CGFloat = 0.10

// ============ 特效 ============
enum Style: String, CaseIterable {
    case band, chroma, anamorphic, pixelSort, equalizer, ripple, rain

    var title: String {
        switch self {
        case .band: return "光带"
        case .chroma: return "色差光带（双色错位）"
        case .anamorphic: return "横向镜头光斑"
        case .pixelSort: return "像素拉丝"
        case .equalizer: return "均衡器（真频谱）"
        case .ripple: return "波纹"
        case .rain: return "星雨"
        }
    }
}

// ============ 频谱分析（32 段对数频带） ============
final class SpectrumAnalyzer {
    private let n = 1024
    private let half = 512
    private let bandCount = 32
    private var setup: FFTSetup
    private var window = [Float](repeating: 0, count: 1024)
    private var windowed = [Float](repeating: 0, count: 1024)
    private var real = [Float](repeating: 0, count: 512)
    private var imag = [Float](repeating: 0, count: 512)
    private var mags = [Float](repeating: 0, count: 512)
    private var edges: [Int] = []
    private var smoothed = [Float](repeating: 0, count: 32)

    init(sampleRate: Double) {
        setup = vDSP_create_fftsetup(vDSP_Length(10), FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(n)
        for i in 0...bandCount {
            let f = 60.0 * pow(12000.0 / 60.0, Double(i) / Double(bandCount))
            let b = min(max(Int(f / binHz), 1), half - 1)
            edges.append(b)
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ src: UnsafePointer<Float>, _ count: Int) -> [Float] {
        let m = min(count, n)
        vDSP_vmul(src, 1, window, 1, &windowed, 1, vDSP_Length(m))
        if m < n { for i in m..<n { windowed[i] = 0 } }

        for i in 0..<half {
            real[i] = windowed[2 * i]
            imag[i] = windowed[2 * i + 1]
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                mags.withUnsafeMutableBufferPointer { mp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(10), FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        for i in 0..<bandCount {
            let lo = edges[i], hi = max(edges[i + 1], lo + 1)
            var peak: Float = 0
            for b in lo..<hi { peak = max(peak, mags[b]) }
            let norm = peak / Float(n)
            let db = 20 * log10f(max(norm, 1e-9))
            let v = min(max((db + 60) / 60, 0), 1)
            smoothed[i] = v > smoothed[i] ? v : smoothed[i] * 0.80 + v * 0.20
        }
        return smoothed
    }
}

// ============ 麦克风 ============
final class Mic {
    // 每次启动都新建引擎：复用同一个 AVAudioEngine 反复 start/stop，
    // 几次之后会出现"isRunning 为真但缓冲区全是 0"的哑火状态（实测）。
    private var engine: AVAudioEngine?
    var onLevel: ((Float) -> Void)?
    var onBands: (([Float]) -> Void)?
    private(set) var lastDB: Float = -200
    private var peakDB: Float = -30      // 自适应峰值：跟着你说话的最大音量走
    private var analyzer: SpectrumAnalyzer?
    private(set) var silentSince = Date.distantPast   // 连续静音起点，用于看门狗
    private(set) var restartCount = 0
    private(set) var bufferCount = 0                  // 回调次数：区分"没回调"和"回调全 0"
    private(set) var startedAt = Date.distantPast     // 本次引擎启动时刻
    private(set) var sawAnySignal = false             // 本次启动后是否收到过真实声音

    var isRunning: Bool { engine?.isRunning ?? false }
    /// 引擎在跑但连续吐静音超过这个时长 → 判定哑火
    var stuckSilent: Bool {
        isRunning && lastDB <= -139 && Date().timeIntervalSince(silentSince) > 0.9
    }
    /// 开了很久却一次真实声音都没收到 → 判定哑火（麦克风没被真正打开/设备在睡）
    var neverHeardAnything: Bool {
        isRunning && !sawAnySignal && bufferCount > 8
            && Date().timeIntervalSince(startedAt) > 20
    }

    func start() {
        stop()

        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        analyzer = SpectrumAnalyzer(sampleRate: fmt.sampleRate)
        silentSince = Date()
        startedAt = Date()
        sawAnySignal = false

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }

            var sum: Float = 0
            for i in 0..<n { let s = ch[i]; sum += s * s }
            let rms = sqrtf(sum / Float(n))
            let db = 20 * log10f(max(rms, 1e-7))
            self.lastDB = db
            self.bufferCount += 1
            if db > -139 {
                self.silentSince = Date()
                if db > -110 {
                    self.sawAnySignal = true
                    self.restartCount = 0      // 收到真实声音就说明引擎是活的，自愈次数归零
                }
                self.peakDB = max(db, self.peakDB - 0.08)
                let span = max(self.peakDB - noiseFloorDB, 8)
                self.onLevel?(min(max((db - noiseFloorDB) / span, 0), 1))
            } else {
                self.onLevel?(0)
            }

            if let a = self.analyzer { self.onBands?(a.process(ch, n)) }
        }

        e.prepare()
        do {
            try e.start()
            engine = e
        } catch {
            NSLog("engine start failed: \(error)")
            input.removeTap(onBus: 0)
            lastDB = -200
        }
    }

    func restart() {
        restartCount += 1
        start()
    }

    /// 松手后停掉采集：麦克风占用指示消失，也不再持续吃权限
    func stop() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
        lastDB = -200
        peakDB = -30
    }
}

// ============ 门控：按住 fn（微信语音输入）时才响应 ============
// 踩过的两个坑，记在这里免得重走：
//   1) NSEvent.addGlobalMonitorForEvents 缺「输入监控」授权时，静默地一个事件都收不到
//   2) CGEvent.tapCreate(.listenOnly) 缺授权时**仍然返回一个 CFMachPort**，但它永远不送事件
// 两者共同的毛病是"失败不可见"。所以改成 CGEventSource.flagsState 轮询：
// 它只是读此刻的修饰键状态、不监听事件流，不走 TCC，也就没有权限问题。
enum GateMode: String {
    case fn      // 按住 fn 才响应（不需要任何额外权限）
    case voice   // 检测到人声就响应
}

final class FnGate {
    private var fnDown = false
    private var tailUntil = Date.distantPast
    private(set) var seenAnyEvent = false
    private(set) var lastRawHID: UInt64 = 0
    private(set) var lastRawSession: UInt64 = 0
    /// 最近一次按下 fn 的时刻。人声模式下它不用于门控，只当作"用户马上要说话"的提示，
    /// 供哑火自愈判断：按了键却还是没声音 → 才值得重建引擎。
    private(set) var lastActiveAt = Date.distantPast

    /// 每个 tick 调用一次（60fps），采样当前是否按住 fn。
    /// 两个来源都看：hidSystemState 是硬件层，combinedSessionState 是会话层；
    /// fn 有时只出现在其中一个里，只看 combined 会漏。
    func poll() {
        let hid = CGEventSource.flagsState(.hidSystemState)
        let sess = CGEventSource.flagsState(.combinedSessionState)
        lastRawHID = hid.rawValue
        lastRawSession = sess.rawValue
        let down = hid.contains(.maskSecondaryFn) || sess.contains(.maskSecondaryFn)
        if down {
            seenAnyEvent = true
            lastActiveAt = Date()
        }
        if down && !fnDown { fnDown = true }
        if !down && fnDown {
            fnDown = false
            tailUntil = Date().addingTimeInterval(1.5)   // 松手后留 1.5 秒收尾
        }
    }

    func allows() -> Bool { fnDown || Date() < tailUntil }
    var isFnDown: Bool { fnDown }
    /// 刚刚按过 fn（2.5 秒内）
    var recentlyActive: Bool { Date().timeIntervalSince(lastActiveAt) < 2.5 }
}

// ============ 特效视图 ============
final class StyleView: NSView {
    private var color: NSColor
    private var second: NSColor
    private var style: Style = .band
    private(set) var currentThemeKey: String = ""

    private let glow = CAGradientLayer()
    private let core = CAGradientLayer()
    private var bars: [CALayer] = []
    private let ripple = CAShapeLayer()
    private let rippleGhost = CAShapeLayer()
    private let rainLayer = CAShapeLayer()      // 拖尾（线）
    private let rainDotLayer = CAShapeLayer()   // 头部亮点（圆）
    private let rainLine = CAShapeLayer()       // 水位线：粒子撞上去回弹的那层"水面"

    // ---- 色差错位（chroma）：算法移植自 JIZURA (https://github.com/852wa/JIZURA) 的 09_render.js
    //      原实现是「两遍 ghost + 一遍 main」的三次重绘，每遍各带一个时间延迟和一个像素偏移；
    //      这里光带本来就是逐帧画的，所以用「延迟的包络值 + 位移」等价实现，视觉一致但不用离屏缓冲。
    //      MIT License，Copyright (c) 2026 hakoniwa (852wa)。----
    private var ghostA: NSColor
    private var ghostB: NSColor
    private var chromaPasses: [ChromaPass] = []
    private var levelHistory: [CGFloat] = []      // 环形包络历史，按帧回看，给 ghost 用
    private var chromaSpike: CGFloat = 0          // 起音爆点，JIZURA 的 ev.amp 衰减曲线
    private var prevLevel: CGFloat = 0
    private var chromaPhase: CGFloat = 0          // 波浪顶边的流动相位

    // ---- 横向镜头光斑（anamorphic）与像素拉丝（pixelSort）
    //      移植自 JIZURA (https://github.com/852wa/JIZURA) 的 11p_fxB.js。
    //      anamorphic 原实现＝横向拉长的径向渐变 + 一条细亮芯 + 热斑 + 三个镜片鬼影，screen 混合；
    //      pixelSort 原实现＝把竖柱切片纵向拉伸（melt）；
    //      底色本来就是黑的，所以这里都用普通 alpha 叠出等价观感。
    //      MIT License，Copyright (c) 2026 hakoniwa (852wa)。----
    private let anaBox = CALayer()
    private var anaHalo = CALayer()
    private var anaCore = CALayer()
    private var anaHot = CALayer()
    private var anaGhosts: [CALayer] = []

    private var meltSlabs: [MeltSlab] = []
    private var meltSpike: CGFloat = 0
    private var meltPhase: CGFloat = 0

    private struct MeltSlab {
        let box: CALayer
        let grad: CAGradientLayer
        let x: CGFloat
        let w: CGFloat
        let seed: CGFloat
    }

    private struct ChromaPass {
        let box: CALayer            // 外层：管位移，遮罩用横向羽化（免得光带在屏幕两端被硬切）
        let inner: CALayer          // 内层：遮罩用波浪顶边，错位就是靠这条边被看见的
        let glow: CAGradientLayer
        let core: CAGradientLayer   // 主带的实心底边，ghost 上透明度为 0
        let shape: CAShapeLayer
        let feather: CAGradientLayer
        let lagFrames: Int          // 回看多少帧的包络
        let dx: CGFloat             // 满强度时的横向错位（pt）
        let dyk: CGFloat            // 纵向错位，按当前带宽的比例
        let hScale: CGFloat         // 相对主带高度：三层错开，带顶才露出彩边
        let amp: CGFloat            // 波幅占带宽比例
        let period: CGFloat         // 波长（pt）
        let phase: CGFloat
        let isGhost: Bool
    }

    // ---- 星雨：粒子从窗口顶部下落，碰到「当前音量高度」这层隐形地板就弹一次。
    //      弹起初速由音头（包络突增）决定：没音头只是轻轻一跳，鼓点上会被顶起一大截。
    //      下落用真实重力，所以弹起是一条抛物线，落回来再掉出画面。----
    private struct Particle {
        var x: CGFloat, y: CGFloat, vy: CGFloat, life: CGFloat, r: CGFloat
        var bounced: Bool = false    // 已经弹过：只弹一次，之后就往下离场
        var kick: CGFloat = 1        // 每颗自己的弹性系数，避免整片雨齐刷刷同步
        var bright: CGFloat = 0      // 刚弹起的高光，逐帧衰减
    }
    private var particles: [Particle] = []
    private var spawnAccum: CGFloat = 0
    private var rainSpike: CGFloat = 0           // 星雨的起音爆点，与 chroma 各自独立
    private var rainPrevLevel: CGFloat = 0
    private var ripplePhase: CGFloat = 0
    private var lastTime: CFTimeInterval = 0
    private let barCount = 32

    init(frame: NSRect, theme: Theme) {
        self.color = theme.accent
        self.second = theme.second
        self.ghostA = theme.ghostA
        self.ghostB = theme.ghostB
        super.init(frame: frame)
        currentThemeKey = theme.key
        wantsLayer = true
        layer?.masksToBounds = false
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 窗口高度变了：各图层的 frame 都是在 rebuild 里按 bounds 定的，重建一遍最省事。
    /// 代价是正在飞的粒子、包络历史会清空，但调高度是一次性操作，看不出来。
    func refreshLayout() {
        lastTime = 0
        rebuild()
    }

    func applyTheme(_ t: Theme) {
        color = t.accent
        second = t.second
        ghostA = t.ghostA
        ghostB = t.ghostB
        currentThemeKey = t.key
        rebuild()
    }

    func setStyle(_ s: Style) {
        guard s != style else { return }
        style = s
        rebuild()
    }

    /// 把当前图层树渲染成位图，用于自检（没有屏幕录制权限时也能验证视觉效果）
    func snapshot() -> NSImage? {
        guard let l = layer, l.bounds.width > 0, l.bounds.height > 0 else { return nil }
        let w = Int(l.bounds.width), h = Int(l.bounds.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.black.cgColor)   // 透明背景转成黑底，方便看
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        l.render(in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// 光带中段的过渡色：主色向副色偏一点。
    /// 副色太暗、或与主色色相相距太远（>90°）时不混——实测黄混蓝会变成第三种绿，看着像配错了。
    private var midColor: NSColor {
        let a = color.usingColorSpace(.sRGB) ?? color
        let b = second.usingColorSpace(.sRGB) ?? second
        var ha: CGFloat = 0, sa: CGFloat = 0, va: CGFloat = 0, aa: CGFloat = 0
        var hb: CGFloat = 0, sb: CGFloat = 0, vb: CGFloat = 0, ab: CGFloat = 0
        a.getHue(&ha, saturation: &sa, brightness: &va, alpha: &aa)
        b.getHue(&hb, saturation: &sb, brightness: &vb, alpha: &ab)
        let lb = 0.2126 * b.redComponent + 0.7152 * b.greenComponent + 0.0722 * b.blueComponent
        var dh = abs(ha - hb)
        if dh > 0.5 { dh = 1 - dh }
        guard lb > 0.20, dh < 0.25 else { return a }
        let t: CGFloat = 0.45
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                       alpha: 1)
    }

    // 漏光的第二团用副色，但副色太暗时（深海、蓝图这类）会整团看不见，退回主色
    private var leakSecond: NSColor {
        let b = second.usingColorSpace(.sRGB) ?? second
        let l = 0.2126 * b.redComponent + 0.7152 * b.greenComponent + 0.0722 * b.blueComponent
        return l > 0.20 ? second : color
    }

    /// 色差错位要用的两支重影色，两道校正：
    /// 1) 原配色里有些 ghost 是纯黑（蓝图 ghostA=#000000），画在透明层上等于没有，提亮成主色；
    /// 2) 校正后两色太接近就转一个的色相，否则"双色错位"看不出是两色。
    private var chromaGhosts: (NSColor, NSColor) {
        var a = ghostA
        var b = ghostB
        if a.luma < 0.22 { a = color }
        if b.luma < 0.22 { b = color }
        // 两色太接近就转一个的色相。色散的本质是两端色相分开，
        // 深海这种 ghostA/ghostB 同属蓝绿的方案不拉开就完全看不出错位。
        let d = NSColor.hueDistance(a, b)
        if d < 0.20 { b = b.hueShifted(by: 0.20 - d + 0.18) }
        if a.luma < 0.25 && b.luma < 0.25 { a = color.hueShifted(by: -0.16) }
        return (a, b)
    }

    // ---- 横向镜头光斑：椭圆光晕 + 细亮芯 + 热斑 + 三个镜片鬼影，对应 JIZURA anamorphic 的四层。
    //      原版按整帧 1080 高取尺寸，这里底条只有 180pt，按 M=180 的比例缩小。
    //      坑：CAGradientLayer 的 .radial 在 render(in:) 下什么都画不出来（截图是纯黑），
    //      所以这里把径向渐变烘成一张位图当 contents，再用 transform 压成椭圆。----
    private func buildAnamorphic() {
        anaBox.frame = bounds
        anaBox.masksToBounds = false
        layer?.addSublayer(anaBox)

        let w = NSColor.white
        anaHalo = makeGlow([(0, color.withAlphaComponent(0.72)),
                            (0.40, color.withAlphaComponent(0.26)),
                            (1, color.withAlphaComponent(0.0))])
        anaCore = makeGlow([(0, w.withAlphaComponent(0.95)),
                            (0.45, color.withAlphaComponent(0.60)),
                            (1, color.withAlphaComponent(0.0))])
        anaHot = makeGlow([(0, w.withAlphaComponent(0.90)),
                           (1, w.withAlphaComponent(0.0))])
        anaGhosts.removeAll()
        for _ in 0..<3 {
            anaGhosts.append(makeGlow([(0, color.withAlphaComponent(0.22)),
                                       (1, color.withAlphaComponent(0.0))]))
        }
    }

    /// 烘一张径向渐变位图当 layer.contents：从中心亮到边缘透明
    private func makeGlow(_ stops: [(CGFloat, NSColor)], _ n: Int = 256) -> CALayer {
        let l = CALayer()
        l.contentsGravity = .resize
        l.masksToBounds = false
        if let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: stops.map { $0.1.cgColor } as CFArray,
                              locations: stops.map { $0.0 }) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: n / 2, y: n / 2), startRadius: 0,
                                   endCenter: CGPoint(x: n / 2, y: n / 2), endRadius: CGFloat(n) / 2,
                                   options: [])
            l.contents = ctx.makeImage()
        }
        anaBox.addSublayer(l)
        return l
    }

    // ---- 像素拉丝：原版是把竖柱切片纵向拉伸（melt）。光带是横向均匀的，
    //      没有文字那种竖笔画可熔，所以改成从带顶往上拉出的细柱：
    //      柱宽 1.5–6pt、左右硬边、高度由"相邻共用的平滑噪声 × 音量"决定，
    //      音头再整体拔高一次。柱条按固定种子分布，换配色时不会整片跳位。----
    private func buildMelt() {
        let W = bounds.width
        anaBox.frame = bounds
        anaBox.masksToBounds = false
        layer?.addSublayer(anaBox)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let rnd = { () -> CGFloat in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }
        for _ in 0..<120 {
            let r1 = rnd(), r2 = rnd()
            let box = CALayer()
            box.masksToBounds = false
            box.anchorPoint = CGPoint(x: 0.5, y: 0)   // 以底边为锚：拉丝从光带往上长
            anaBox.addSublayer(box)                    // 只借用容器，不参与 anamorphic
            let g = CAGradientLayer()
            g.startPoint = CGPoint(x: 0.5, y: 0)
            g.endPoint = CGPoint(x: 0.5, y: 1)
            g.colors = [color.withAlphaComponent(0.90).cgColor,
                        color.withAlphaComponent(0.62).cgColor,
                        color.withAlphaComponent(0.0).cgColor]
            g.locations = [0, 0.30, 1]
            box.addSublayer(g)
            meltSlabs.append(MeltSlab(box: box, grad: g,
                                      x: W * r1, w: 1.5 + 4.5 * r2, seed: r1))
        }
    }

    private func renderAnamorphic(h: CGFloat, t: CGFloat, level: CGFloat) {
        let W = bounds.width
        let a = min(1, 1.3 * level)                 // 安静时整片收起
        let cy = h + 20                              // 浮在带顶上方：光带本身已是全宽横向光，光斑必须离开带身才看得出来
        let cx = W / 2 + sin(t * 0.33) * W * 0.085   // 缓慢横移，别死钉在正中
        let grow = 1 + 0.30 * level                  // 音量大时光斑张开

        func place(_ l: CALayer, _ rx: CGFloat, _ ry: CGFloat, _ x: CGFloat) {
            let S: CGFloat = 256
            l.bounds = CGRect(x: 0, y: 0, width: S, height: S)
            l.position = CGPoint(x: x, y: cy)
            l.transform = CATransform3DMakeScale(rx * grow / (S / 2), ry * grow / (S / 2), 1)
            l.opacity = Float(a)
        }
        // 光带本身已经是通屏的横向光：光斑跟带子同宽同高就完全重合，看着只是"带子亮了一点"。
        // 所以这里把光斑做窄（0.34W）并抬离带身，让它两头"露头"、自成一层。
        place(anaHalo, W * 0.34, 22.0, cx)
        place(anaCore, W * 0.30, 1.3, cx)   // 细亮芯
        place(anaHot, 15.0, 15.0, cx)       // 热斑
        let f: [CGFloat] = [0.55, 1.1, 1.7]  // 镜片鬼影沿穿过中心的那条线排开
        let r: [CGFloat] = [5.4, 10.8, 3.6]
        for (i, g) in anaGhosts.enumerated() {
            place(g, r[i], r[i], W / 2 + (W / 2 - cx) * f[i])
        }
    }

    private func renderMelt(h: CGFloat, level: CGFloat, dt: CGFloat) {
        // 起音整体拔高一次再回落，对应原实现的 amp 衰减曲线
        let rise = level - prevLevel
        prevLevel = level
        if rise > 0.08 { meltSpike = min(2.2, meltSpike + rise * 3.0) }
        meltSpike *= pow(0.55, dt * 20)
        meltPhase += dt * 0.9
        let boost = 1 + meltSpike
        let master = Float(min(1, 0.18 + 0.95 * level))

        for s in meltSlabs {
            // 相邻柱条共用同一条平滑噪声：各长各的会变成均衡器，共用才有"熔出去"的连贯感
            let n = 0.5 + 0.5 * sin(s.x * 0.011 + meltPhase) * sin(s.x * 0.031 - meltPhase * 0.6)
            let pull = (0.20 + 1.45 * n) * level * boost * maxBandHeight * 0.75
            let len = max(1, min(bounds.height, h * 0.12 + pull))
            s.box.bounds = CGRect(x: 0, y: 0, width: s.w, height: len)
            s.box.position = CGPoint(x: s.x, y: h * 0.10)
            s.grad.frame = CGRect(x: 0, y: 0, width: s.w, height: len)
            s.box.opacity = master * Float(0.40 + 0.60 * n)
        }
    }

    private func rebuild() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        bars.removeAll()
        particles.removeAll()
        rainSpike = 0
        rainPrevLevel = 0
        spawnAccum = 0
        meltSlabs.removeAll()
        anaGhosts.removeAll()

        switch style {
        case .band, .anamorphic, .pixelSort:
            glow.startPoint = CGPoint(x: 0.5, y: 0)
            glow.endPoint = CGPoint(x: 0.5, y: 1)
            glow.colors = [color.withAlphaComponent(0.55).cgColor,
                           midColor.withAlphaComponent(0.28).cgColor,
                           color.withAlphaComponent(0.0).cgColor]
            glow.locations = [0, 0.45, 1]
            layer?.addSublayer(glow)
            core.startPoint = CGPoint(x: 0.5, y: 0)
            core.endPoint = CGPoint(x: 0.5, y: 1)
            core.colors = [color.withAlphaComponent(1.0).cgColor,
                           color.withAlphaComponent(0.0).cgColor]
            core.locations = [0, 1]
            layer?.addSublayer(core)
            if style == .anamorphic { buildAnamorphic() }
            if style == .pixelSort { buildMelt() }

        case .chroma:
            chromaPasses.removeAll()
            levelHistory.removeAll()
            chromaSpike = 0
            prevLevel = 0
            let (gcA, gcB) = chromaGhosts
            // 加层顺序就是层序：ghost 垫底、main 压顶，对应 JIZURA 的 B → A → main 三遍。
            // 三层的高度、波长、相位都不同——光带是横向均匀的，三者的顶边一旦重合，
            // 位移就看不出来；错开之后每一层的波浪边都会露出来，错位才有地方显形。
            let white = NSColor.white.cgColor
            let clear = NSColor.white.withAlphaComponent(0).cgColor
            // hScale 以 0.90 的基准高为 1（见 render），三层都留了顶部余量，
            // 否则满音量时光带已经顶到窗口上沿，彩边会被裁掉。
            let specs: [(NSColor, NSColor, Int, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
                (gcB, gcB,      4, -10.0, -0.008, 1.06, 0.060, 152, 0.0, true),
                (gcA, gcA,      2,   9.0,  0.008, 0.99, 0.050, 128, 1.9, true),
                (color, midColor, 0,   0.0,  0.000, 0.94, 0.015, 215, 0.7, false),
            ]
            for (base, mid, lag, dx, dyk, hs, amp, period, phase, isGhost) in specs {
                let box = CALayer()
                box.masksToBounds = false
                box.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                box.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
                box.position = CGPoint(x: bounds.width / 2, y: 0)
                layer?.addSublayer(box)

                // 横向羽化：光带横跨整屏，不羽化的话左右两端是硬切边
                let fd = CAGradientLayer()
                fd.startPoint = CGPoint(x: 0, y: 0.5)
                fd.endPoint = CGPoint(x: 1, y: 0.5)
                fd.colors = [clear, white, white, clear]
                fd.locations = [0, 0.06, 0.94, 1]
                box.mask = fd

                // 内层挂波浪顶边的遮罩：顶端保留约 0.7 的不透明度再被硬切，
                // 切出来就是一条带颜色的清晰边缘——位移就是在这条边上显形的
                let inner = CALayer()
                inner.masksToBounds = false
                box.addSublayer(inner)

                let g = CAGradientLayer()
                g.startPoint = CGPoint(x: 0.5, y: 0)
                g.endPoint = CGPoint(x: 0.5, y: 1)
                if isGhost {
                    // ghost 只保留贴顶的一条窄光边：下面是透明的，主带透得出来，
                    // 否则三层叠成三块实心色块，看着像剪纸而不是光。
                    // 五档：0.70 开始微微垫底（补住与主带的暗隙），0.99 最亮形成光边，
                    // 顶端再压一点点，避免被波浪遮罩硬切出一条死边
                    g.colors = [base.withAlphaComponent(0.0).cgColor,
                                base.withAlphaComponent(0.0).cgColor,
                                base.withAlphaComponent(0.28).cgColor,
                                base.withAlphaComponent(0.66).cgColor,
                                base.withAlphaComponent(0.36).cgColor]
                    g.locations = [0, 0.70, 0.86, 0.99, 1]
                } else {
                    // 主带沿用 .band 的柔和形态：底部实、中间混副色、顶部收干净
                    g.colors = [base.withAlphaComponent(1.0).cgColor,
                                base.withAlphaComponent(0.92).cgColor,
                                mid.withAlphaComponent(0.52).cgColor,
                                base.withAlphaComponent(0.0).cgColor]
                    g.locations = [0, 0.38, 0.78, 1]
                }
                // 主带的实心底边：只有 glow 的话中段透明度太低，整条带会塌成暗块
                let co = CAGradientLayer()
                co.startPoint = CGPoint(x: 0.5, y: 0)
                co.endPoint = CGPoint(x: 0.5, y: 1)
                co.colors = [base.withAlphaComponent(isGhost ? 0.0 : 1.0).cgColor,
                             base.withAlphaComponent(0.0).cgColor]
                co.locations = [0, 1]
                inner.addSublayer(g)
                inner.addSublayer(co)

                let sh = CAShapeLayer()
                sh.fillColor = NSColor.white.cgColor
                inner.mask = sh

                chromaPasses.append(ChromaPass(box: box, inner: inner, glow: g, core: co, shape: sh,
                                               feather: fd, lagFrames: lag, dx: dx, dyk: dyk,
                                               hScale: hs, amp: amp, period: period,
                                               phase: phase, isGhost: isGhost))
            }


        case .equalizer:
            for _ in 0..<barCount {
                let l = CALayer()
                l.backgroundColor = color.withAlphaComponent(0.85).cgColor
                l.cornerRadius = 1.5
                l.opacity = 0
                layer?.addSublayer(l)
                bars.append(l)
            }
        case .ripple:
            ripple.fillColor = color.withAlphaComponent(0.13).cgColor
            ripple.strokeColor = color.withAlphaComponent(0.95).cgColor
            ripple.lineWidth = 3
            ripple.lineCap = .round
            layer?.addSublayer(ripple)
            rippleGhost.fillColor = nil
            rippleGhost.strokeColor = second.withAlphaComponent(0.45).cgColor
            rippleGhost.lineWidth = 1.5
            layer?.addSublayer(rippleGhost)

        case .rain:
            // 拖尾用描边画线（速度越快拉得越长），头部再叠一层亮点，雨丝才有"星"的感觉。
            // 两者同色相，只靠亮度区分 —— 一蓝一绿会看成两种东西。
            rainLine.fillColor = nil
            rainLine.strokeColor = color.withAlphaComponent(0.55).cgColor
            rainLine.lineWidth = 1
            layer?.addSublayer(rainLine)      // 水面在雨点之下，撞上去的瞬间才像被压出水花
            rainLayer.fillColor = nil
            rainLayer.strokeColor = color.withAlphaComponent(0.62).cgColor
            rainLayer.lineWidth = 2.2
            rainLayer.lineCap = .round
            layer?.addSublayer(rainLayer)
            rainDotLayer.fillColor = (color.blended(withFraction: 0.40, of: .white) ?? color)
                .withAlphaComponent(0.95).cgColor
            rainDotLayer.strokeColor = nil
            layer?.addSublayer(rainDotLayer)
        }
    }

    func render(level: CGFloat, bands: [Float], fixedDt: CGFloat? = nil) {
        let now = CACurrentMediaTime()
        let dt = fixedDt ?? (lastTime == 0 ? 1.0 / 60.0 : CGFloat(min(now - lastTime, 0.05)))
        lastTime = now

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .band, .anamorphic, .pixelSort:
            let h = max(0, maxBandHeight * level)
            glow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
            glow.opacity = Float(0.55 + 0.45 * level)
            core.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(h, max(2, h * 0.30)))
            core.opacity = Float(0.75 + 0.25 * level)
            if style == .anamorphic { renderAnamorphic(h: h, t: CGFloat(now), level: level) }
            if style == .pixelSort { renderMelt(h: h, level: level, dt: dt) }

        case .chroma:
            // 包络历史：错位必须配时间差，只位移就是普通重影，没有"色散"的味道
            levelHistory.append(level)
            if levelHistory.count > 10 { levelHistory.removeFirst(levelHistory.count - 10) }

            // 起音检测 → 对应 JIZURA 的 chroma 事件：只有音头才"炸"一下，
            // 持续说话时慢慢回落到基础强度。衰减式 amp * 0.55^(dt·24) 与原实现一致。
            let rise = level - prevLevel
            prevLevel = level
            if rise > 0.10 { chromaSpike = min(2.6, chromaSpike + rise * 2.4) }
            chromaSpike *= pow(0.55, dt * 24)

            let amount = 0.85 * (1 + chromaSpike)
            let W = bounds.width
            chromaPhase += dt * 0.55           // 波浪本身缓慢流动，静止时也不死板

            for p in chromaPasses {
                let lv: CGFloat
                if p.lagFrames == 0 {
                    lv = level
                } else {
                    let idx = levelHistory.count - 1 - p.lagFrames
                    lv = idx >= 0 ? levelHistory[idx] : level
                }
                // 基准高取 0.90：三层都留出顶部余量，满音量时彩边才不会被窗口上沿裁掉
                let h = max(0, maxBandHeight * lv * 0.90)
                let hh = max(1, h * p.hScale)
                let ox = p.dx * amount
                let oy = p.dyk * h * amount

                p.box.bounds = CGRect(x: 0, y: 0, width: W, height: hh)
                p.box.position = CGPoint(x: W / 2 + ox, y: hh / 2 + oy)
                p.feather.frame = CGRect(x: 0, y: 0, width: W, height: hh)

                p.inner.frame = CGRect(x: 0, y: 0, width: W, height: hh)
                p.glow.frame = CGRect(x: 0, y: 0, width: W, height: hh)
                p.glow.opacity = Float(p.isGhost ? 1.0 : 0.55 + 0.45 * lv)

                // 主带的实心底边：只有 glow 的话中段透明度太低，整条带会塌成暗块
                p.core.frame = CGRect(x: 0, y: 0, width: W, height: min(hh, max(2, hh * 0.30)))
                p.core.opacity = Float(0.75 + 0.25 * lv)

                // 波浪顶边：振幅随强度走，没声音时是一条平线
                let amp = hh * p.amp * (0.35 + 0.65 * lv)
                let ph = p.phase + chromaPhase
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                var x: CGFloat = 0
                while x <= W {
                    let y = hh - amp * (0.5 + 0.5 * sin(x / p.period * 2 * .pi + ph))
                    path.addLine(to: CGPoint(x: x, y: max(0, y)))
                    x += 8
                }
                path.addLine(to: CGPoint(x: W, y: 0))
                path.closeSubpath()
                p.shape.frame = CGRect(x: 0, y: 0, width: W, height: hh)
                p.shape.path = path
            }

        case .equalizer:
            let total = bounds.width
            let gap: CGFloat = 3
            let bw = max(1, (total - gap * CGFloat(barCount - 1)) / CGFloat(barCount))
            for i in 0..<barCount {
                let v = i < bands.count ? CGFloat(bands[i]) : 0
                let h = max(2, v * maxBandHeight)
                bars[i].frame = CGRect(x: CGFloat(i) * (bw + gap), y: 0, width: bw, height: h)
                bars[i].opacity = Float(0.35 + 0.65 * v)
            }

        case .ripple:
            ripplePhase += dt * 2.6
            let amp = 6 + level * 52
            let base = 16 + level * maxBandHeight * 0.55
            let p = CGMutablePath()
            let g = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= bounds.width {
                let fade = 1 - x / bounds.width * 0.35
                p.addLine(to: CGPoint(x: x, y: base + amp * sin(x / 95 + ripplePhase) * fade))
                x += 3
            }
            p.addLine(to: CGPoint(x: bounds.width, y: 0))
            p.closeSubpath()

            x = 0
            g.move(to: CGPoint(x: 0, y: base * 0.55 + amp * 0.5 * sin(ripplePhase * 1.35)))
            while x <= bounds.width {
                let fade = 1 - x / bounds.width * 0.35
                g.addLine(to: CGPoint(x: x, y: base * 0.55 + amp * 0.5 * sin(x / 150 - ripplePhase * 1.35) * fade))
                x += 3
            }
            ripple.path = p
            rippleGhost.path = g
            ripple.opacity = Float(0.40 + 0.60 * level)
            rippleGhost.opacity = Float(0.25 + 0.45 * level)

        case .rain:
            // 起音检测：这一拍有多重，决定雨点撞到带顶时弹回去多快
            let rainRise = level - rainPrevLevel
            rainPrevLevel = level
            if rainRise > 0.07 { rainSpike = min(2.0, rainSpike + rainRise * 3.2) }
            rainSpike *= pow(0.55, dt * 18)

            // 「顶端」就是这一帧光带的顶边：音量越大，这层水面越高，雨点也冲得更急。
            // 留 10pt 底数，小声时也有一层薄薄的雨面，不至于整片贴着屏幕底边爬。
            let top = min(maxBandHeight * level + 10, bounds.height - 4)
            let gravity: CGFloat = 760        // 向上飞时一路吃掉速度，落回来时又加速
            // 恰好够到水面所需的初速：让雨点的劲头始终跟当前音量对得上，
            // 否则音量一低、水面只有十几 pt，粒子却按满音量的速度冲上去，直接穿过水面。
            let vTop = (2 * gravity * max(8, top)).squareRoot()

            // 鼓点一响，带内正在上冲的雨点整个被顶高一头 —— 节奏最直观的表现
            if rainRise > 0.12, top > 8 {
                for j in particles.indices
                where !particles[j].bounced && particles[j].vy > 0 {
                    particles[j].vy += 95 * min(1.5, rainSpike)
                }
            }

            // 生成速率用 level^0.7 而不是线性：小声说话时也有雨，不然轻声几乎什么都看不见
            spawnAccum += pow(max(0, level), 0.7) * 300 * dt
            while spawnAccum >= 1 {
                spawnAccum -= 1
                if particles.count < 220 {
                    // 分成两拨：慢雨到不了水面，只铺在中下段；快雨一路冲到水面撞出回弹，
                    // 那一拨才是节奏的落点。
                    let slow = CGFloat.random(in: 0...1) < 0.38
                    let k = slow ? CGFloat.random(in: 0.36...0.62) : CGFloat.random(in: 0.78...1.12)
                    particles.append(Particle(x: CGFloat.random(in: 0...max(1, bounds.width)),
                                              y: -8,
                                              vy: vTop * k + CGFloat.random(in: 0...40),
                                              life: 1,
                                              r: CGFloat.random(in: 1.5...3.4),
                                              kick: CGFloat.random(in: 0.78...1.28)))
                }
            }

            var keep: [Particle] = []
            keep.reserveCapacity(particles.count)
            var newborn: [Particle] = []       // 回弹溅出的碎星，等循环结束再并进去
            let p = CGMutablePath()            // 拖尾
            let d = CGMutablePath()            // 头部亮点

            for i in particles.indices {
                var pt = particles[i]
                pt.vy -= gravity * dt
                pt.bright = max(0, pt.bright - dt * 4.5)
                var ny = pt.y + pt.vy * dt

                // 撞到带顶 → 回弹一次。弹起初速 = 撞上来的速度 × 弹性，
                // 弹性跟音头走：没有音头只是轻轻退下，鼓点上会被整个弹回去。
                if !pt.bounced, top > 4, pt.vy > 0, ny >= top,
                   particles.count + newborn.count < 320 {
                    ny = top
                    pt.vy = -pt.vy * (0.42 + 0.42 * min(1, rainSpike)) * pt.kick
                    pt.bounced = true
                    pt.bright = 1
                    // 顶到水面时溅出两颗小碎星，向下散开：回弹的"啪"就靠这一下被看见。
                    // 数量别多、位置要散，否则鼓点那一帧会挤成一团噪点。
                    for _ in 0..<2 {
                        newborn.append(Particle(x: pt.x + CGFloat.random(in: -14...14),
                                                y: top - CGFloat.random(in: 0...5),
                                                vy: -(100 + 140 * CGFloat.random(in: 0...1)),
                                                life: 1,
                                                r: CGFloat.random(in: 0.9...1.6),
                                                bounced: true,
                                                kick: 1,
                                                bright: 0.5))
                    }
                }

                pt.y = ny
                pt.life -= dt
                guard pt.life > 0, ny > -16 else { continue }

                // 尾巴在运动的反方向：冲得越快拉得越长，才像雨丝而不像噪点。
                // 必须夹在水面之下，否则弹回来的雨点会把尾巴留在水面上方，看着像穿帮。
                let tail = min(26, abs(pt.vy) * 0.055)
                let tipY = min(max(ny - (pt.vy >= 0 ? tail : -tail), 0), max(top, ny))
                p.move(to: CGPoint(x: pt.x, y: tipY))
                p.addLine(to: CGPoint(x: pt.x, y: ny))

                let rr = pt.r * (1 + pt.bright * 1.1)
                d.addEllipse(in: CGRect(x: pt.x - rr, y: ny - rr, width: rr * 2, height: rr * 2))
                keep.append(pt)
            }

            keep.append(contentsOf: newborn)
            particles = keep
            rainLayer.path = p
            rainLayer.opacity = Float(0.45 + 0.55 * level)
            rainDotLayer.path = d
            rainDotLayer.opacity = Float(0.55 + 0.45 * level)

            // 水位线：就是粒子撞上去回弹的那个平面，跟着音量上下走
            let wl = CGMutablePath()
            wl.move(to: CGPoint(x: 0, y: top))
            wl.addLine(to: CGPoint(x: bounds.width, y: top))
            rainLine.path = wl
            rainLine.opacity = Float(0.30 + 0.38 * level)
        }

        CATransaction.commit()
    }

}

// ============ 悬浮窗 ============
final class OverlayWindow: NSWindow {
    let view: StyleView

    init(screen: NSScreen, theme: Theme) {
        let rect = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                          width: screen.frame.width, height: maxBandHeight + overlayHeadroom)
        view = StyleView(frame: NSRect(origin: .zero, size: rect.size), theme: theme)
        super.init(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = view
    }

    /// 改高度：底边贴着屏幕底，所以只拔高不挪位。图层是按 bounds 建的，重建一次。
    func setHeight(_ h: CGFloat) {
        guard let scr = screen ?? NSScreen.main else { return }
        var f = frame
        f.origin.y = scr.frame.minY
        f.size.height = h + overlayHeadroom
        setFrame(f, display: true)
        view.frame = NSRect(origin: .zero, size: f.size)
        view.refreshLayout()
    }
}

// ============ App ============
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: OverlayWindow!
    private var statusItem: NSStatusItem?    // 必须强引用，否则图标立刻消失
    private var styleMenuItem: NSMenuItem?
    private var styleMenu: NSMenu?
    private var themeMenu: NSMenu?
    private var gateMenuItem: NSMenuItem?
    private var statusInfoItem: NSMenuItem?
    private var mic = Mic()
    private var gate = FnGate()
    private var timer: Timer?
    private var env: CGFloat = 0
    private var micLevel: CGFloat = 0
    private var bands = [Float](repeating: 0, count: 32)
    private var gateMode: GateMode = .voice
    private var micKeepAliveUntil = Date.distantPast
    private var permissionAsked = false
    private var warnedPermission = false
    private var idleFrames = 0
    private var updateMenuItem: NSMenuItem?
    private var frameCount = 0
    private var lastLoggedFlags: UInt64 = 0
    private var nextMicRetryAt = Date.distantPast
    private var style: Style = .band
    private var heightMenu: NSMenu?
    private var heightMenuItem: NSMenuItem?
    private var heightSlider: NSSlider?
    private var heightSliderLabel: NSTextField?
    /// 已经落盘的高度，用来判断"这次改动要不要写盘"
    private var onDiskHeight: CGFloat = maxBandHeight
    /// 调高度时的满高预览窗口期：菜单开着一直有效，关掉后再留一会儿，
    /// 免得手一松画面就塌回静音状态、看不到刚才调到了多高。
    private var heightPreviewUntil = Date.distantPast
    private var heightTouched = false
    private let heightMin: CGFloat = 80
    private let heightMax: CGFloat = 400
    private var theme = Theme.named("ocean")
    private var syntheticUntil = Date.distantPast
    private var previewKey: String?      // 非 nil = 正在悬浮预览配色
    private var stylePreviewActive = false   // true = 正在悬浮预览某个特效，移开要还原

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 改名换 bundle id：先把老用户的特效/配色/高度搬过来
        Prefs.migrateFromLegacyIfNeeded()
        DiagLog.shared.write("[launch] \(AppInfo.fullName) \(AppInfo.version) build \(AppInfo.build)")

        style = Style(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .band
        theme = Theme.named(UserDefaults.standard.string(forKey: "theme") ?? "ocean")

        // ---- 以下为 QA 专用：正式构建（不带 -D DEBUGTOOLS）整段不参与编译 ----
        #if DEBUGTOOLS
        // 自检用：--style=chroma --shot 直接出图退出，免得每次都去点菜单
        let args = CommandLine.arguments
        if let a = args.first(where: { $0.hasPrefix("--style=") }),
           let s = Style(rawValue: String(a.dropFirst(8))) { style = s }
        if let a = args.first(where: { $0.hasPrefix("--theme=") }) {
            theme = Theme.named(String(a.dropFirst(8)))
        }
        let shotMode = args.contains("--shot")
        // 自检音头：先低电平静置再猛抬，看回弹。--burst=<帧数> 可指定抬起来之后推进几帧
        var burstFrames = 44
        var burstMode = args.contains("--burst")
        if let a = args.first(where: { $0.hasPrefix("--burst=") }), let v = Int(a.dropFirst(8)) {
            burstFrames = v
            burstMode = true
        }
        var shotLevel: CGFloat = 0.95
        if let a = args.first(where: { $0.hasPrefix("--level=") }), let v = Double(a.dropFirst(8)) {
            shotLevel = CGFloat(v)
        }
        // 自检：--height=240 按这个高度出图（不写盘，别覆盖掉用户选的档位）
        if let a = args.first(where: { $0.hasPrefix("--height=") }),
           let v = Double(a.dropFirst(9)), v >= 80, v <= 600 {
            maxBandHeight = CGFloat(v)
            onDiskHeight = CGFloat(v)
        }
        #endif

        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = OverlayWindow(screen: screen, theme: theme)
        window.view.setStyle(style)
        window.orderFrontRegardless()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        applyStatusIcon(to: item)

        let menu = NSMenu()
        #if DEBUGTOOLS
        let testItem = NSMenuItem(title: "测试一下（预览当前特效）", action: #selector(testFlash), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)
        let shotItem = NSMenuItem(title: "导出一张画面（自检）", action: #selector(exportShot), keyEquivalent: "")
        shotItem.target = self
        menu.addItem(shotItem)
        #endif
        let reconnectItem = NSMenuItem(title: "重连麦克风", action: #selector(reconnectMic), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let styleItem = NSMenuItem(title: "特效", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        styleMenu.delegate = self      // 悬浮即预览，见 menu(_:willHighlight:)
        for s in Style.allCases {
            let mi = NSMenuItem(title: s.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.rawValue
            mi.state = (s == style) ? .on : .off
            styleMenu.addItem(mi)
        }

        styleItem.submenu = styleMenu
        styleMenuItem = styleItem
        self.styleMenu = styleMenu
        menu.addItem(styleItem)

        let themeItem = NSMenuItem(title: "配色", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        themeMenu.delegate = self      // 悬浮即预览，见 menu(_:willHighlight:)
        for t in Theme.all {
            let mi = NSMenuItem(title: t.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t.key
            mi.state = (t.key == theme.key) ? .on : .off
            themeMenu.addItem(mi)
        }
        themeItem.submenu = themeMenu
        self.themeMenu = themeMenu
        menu.addItem(themeItem)

        // 高度：整个特效是「按占满这个高度的百分比」算的，改这一个数就整体缩放。
        // 滑块直接嵌在菜单项里（NSMenuItem.view）—— 这是个只有状态栏图标的后台 App，
        // NSAlert 的模态窗口抢不到前台焦点，弹出来也是空的；而菜单里的控件不依赖激活 App。
        let heightItem = NSMenuItem(title: "最大高度", action: nil, keyEquivalent: "")
        let heightMenu = NSMenu()

        let boxW: CGFloat = 268
        let box = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 54))
        let cap = NSTextField(labelWithString: "高度 \(Int(maxBandHeight)) pt")
        cap.frame = NSRect(x: 15, y: 32, width: boxW - 30, height: 16)
        cap.font = .systemFont(ofSize: 11, weight: .medium)
        cap.textColor = .secondaryLabelColor
        box.addSubview(cap)
        let slider = NSSlider(value: Double(maxBandHeight),
                              minValue: Double(heightMin), maxValue: Double(heightMax),
                              target: self, action: #selector(sliderHeight(_:)))
        slider.frame = NSRect(x: 13, y: 8, width: boxW - 26, height: 22)
        slider.controlSize = .small
        slider.isContinuous = true          // 拖到哪就是哪，不用松手才生效
        box.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = box
        heightMenu.addItem(sliderItem)
        heightSlider = slider
        heightSliderLabel = cap

        heightItem.submenu = heightMenu
        self.heightMenu = heightMenu
        heightMenu.delegate = self          // 一展开就进满高预览，拖到哪看到哪
        heightMenuItem = heightItem
        menu.addItem(heightItem)
        menu.addItem(.separator())

        let gateItem = NSMenuItem(title: "触发方式", action: nil, keyEquivalent: "")
        let gateMenu = NSMenu()
        for (mode, title) in [(GateMode.fn, "按住 fn 才响应（微信语音输入）"),
                              (GateMode.voice, "检测到人声就响应（不需要权限）")] {
            let mi = NSMenuItem(title: title, action: #selector(pickGate(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = (mode == gateMode) ? .on : .off
            gateMenu.addItem(mi)
        }
        gateItem.submenu = gateMenu
        gateMenuItem = gateItem
        menu.addItem(gateItem)

        // 这一行直接显示"为什么不动"的原因，不用再翻日志
        let infoItem = NSMenuItem(title: "状态：检查中…", action: #selector(refreshStatus), keyEquivalent: "")
        infoItem.target = self
        statusInfoItem = infoItem
        menu.addItem(infoItem)

        let updateItem = NSMenuItem(title: "检查更新", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateMenuItem = updateItem
        menu.addItem(updateItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 \(AppInfo.fullName) \(AppInfo.version)", action: #selector(openSite), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出 \(AppInfo.name)", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        syncHeightMenu()      // 标题里带上当前高度，自定义之后也能一眼看到

        env = 1.0
        flash()

        // 触发方式会记住。默认用「人声触发」：麦克风常开，有声就亮，
        // 不依赖 fn（遥控器的麦克风键上报不稳定，时有时无）。
        gateMode = GateMode(rawValue: UserDefaults.standard.string(forKey: "gateMode") ?? "") ?? .voice
        syncGateMenu()
        refreshStatus()

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.mic.isRunning else { return }
            self.mic.restart()
        }

        // 插拔显示器 / 改分辨率：窗口要贴回主屏底部，否则会飘在已拔掉的屏幕上
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.relocateWindow() }

        Updater.shared.onChange = { [weak self] st in self?.syncUpdateMenu(st) }
        Updater.shared.autoCheckIfDue()

        #if DEBUGTOOLS
        if shotMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // 停掉帧循环再手动灌一个固定电平，否则截图会被下一帧的静音电平盖掉
                self.timer?.invalidate()
                // 灌一组假的频谱，否则均衡器/整帧滤镜出图时全是空柱，看不出形态
                let fake = (0..<32).map { i in
                    Float(shotLevel) * Float(0.22 + 0.78 * abs(sin(Double(i) * 0.45 + 0.8)))
                }
                // 用固定步长推进：星雨这类有生命周期的特效，否则 dt≈0，
                // 粒子既不会生成也不会移动，出图永远是一片空
                if burstMode {
                    // 先在低电平下攒一批慢雨，再猛抬到目标电平 —— 模拟一个鼓点，
                    // 用来核对回弹有没有被音头顶起来
                    for _ in 0..<52 {
                        self.window.view.render(level: 0.18, bands: fake, fixedDt: 1.0 / 60.0)
                    }
                    for _ in 0..<max(1, burstFrames) {
                        self.window.view.render(level: shotLevel, bands: fake, fixedDt: 1.0 / 60.0)
                    }
                } else {
                    for _ in 0..<96 {
                        self.window.view.render(level: shotLevel, bands: fake, fixedDt: 1.0 / 60.0)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if let img = self.window.view.snapshot(),
                       let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        let tag = self.style.rawValue
                        try? png.write(to: URL(fileURLWithPath: "/tmp/shot-\(tag)-\(self.theme.key).png"))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        #endif

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)

        mic.onLevel = { [weak self] v in
            DispatchQueue.main.async { self?.micLevel = CGFloat(v) }
        }
        mic.onBands = { [weak self] b in
            DispatchQueue.main.async { self?.bands = b }
        }
        writeDiagnostics(tag: "launch")
    }

    // 关键状态写进 ~/Library/Logs/FollowSound/diag.log，用于排查"为什么不亮"。
    // 只在开发构建或 FS_DIAG=1 时开启，正式版不落任何日志（见 DiagLog）。
    private func writeDiagnostics(tag: String) {
        let auth: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: auth = "authorized"
        case .denied: auth = "denied"
        case .restricted: auth = "restricted"
        case .notDetermined: auth = "notDetermined"
        @unknown default: auth = "unknown"
        }
        let line = String(format:
            "[%@] mic=%@ engine=%@ db=%.1f gate=%d fnDown=%d seenFn=%d level=%.2f env=%.2f mode=%@ reMic=%d bufs=%d style=%@ h=%.0f\n",
            tag, auth, mic.isRunning ? "running" : "stopped", mic.lastDB,
            gate.allows() ? 1 : 0, gate.isFnDown ? 1 : 0, gate.seenAnyEvent ? 1 : 0,
            Double(micLevel), Double(env), gateMode.rawValue, mic.restartCount, mic.bufferCount,
            style.rawValue, Double(maxBandHeight))
        DiagLog.shared.write(line.trimmingCharacters(in: .newlines))
        DiagLog.shared.write("[flags-now] hid=0x" + String(gate.lastRawHID, radix: 16)
                             + " session=0x" + String(gate.lastRawSession, radix: 16))
    }

    private func writeRaw(_ s: String) {
        DiagLog.shared.write(s)
    }

    // 麦克风只在需要时开：按住 fn 才启动采集，松手 2 秒后停掉（橙色麦克风指示会消失）。
    // 权限也推迟到第一次真正需要时再问，不在启动时就弹。
    private func updateMic(wanted: Bool) {
        if wanted {
            micKeepAliveUntil = Date().addingTimeInterval(3.0)
            if !mic.isRunning { startMicIfPossible() }
        } else if mic.isRunning && Date() > micKeepAliveUntil {
            mic.stop()
        }
    }

    private func startMicIfPossible() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            mic.start()
        case .notDetermined:
            guard !permissionAsked else { return }
            permissionAsked = true
            // 后台型 App（LSUIElement）不激活时，系统的授权框可能不浮现
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    self.permissionAsked = false
                    if ok { self.mic.start() } else { self.warnPermission() }
                }
            }
        default:
            warnPermission()
        }
    }

    private func warnPermission() {
        guard !warnedPermission else { return }
        warnedPermission = true
        let a = NSAlert()
        a.messageText = "需要麦克风权限"
        a.informativeText = "系统设置 → 隐私与安全性 → 麦克风，勾选「\(AppInfo.name)」后重新打开本 App。"
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "稍后")
        // 后台型 App 不激活的话弹窗会浮在别的空间里，用户根本看不到
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
        }
    }

    private func tick() {
        gate.poll()                       // 每帧采样一次 fn 状态（无权限要求）

        // 修饰键状态一有变化就记一行原始值，用于判定 fn 到底有没有到达系统
        if gate.lastRawHID != lastLoggedFlags {
            lastLoggedFlags = gate.lastRawHID
            writeRaw("[flags] hid=0x" + String(gate.lastRawHID, radix: 16)
                     + " session=0x" + String(gate.lastRawSession, radix: 16)
                     + " fnBit=" + (gate.lastRawHID & 0x0080_0000 != 0 ? "1" : "0"))
        }

        let gated: Bool
        switch gateMode {
        case .fn:
            gated = !gate.allows()
        case .voice:
            gated = false     // 人声门控：麦克风常开，靠包络自身归零
            micKeepAliveUntil = Date().addingTimeInterval(3600)   // 永不自动关麦
        }
        updateMic(wanted: !gated)

        // 哑火自愈（只在"应该有声音却没有"时动手，避免安静时白白重建引擎）：
        //   刚按过 fn（= 遥控器麦克风键）却连续收静音 → 麦克风没被真正打开，重建引擎
        let deaf = mic.stuckSilent && (gateMode == .fn ? gate.allows() : gate.recentlyActive)
        if deaf && mic.restartCount < 3 && Date() > nextMicRetryAt {
            nextMicRetryAt = Date().addingTimeInterval(3.0)
            mic.restart()
            writeRaw("[watchdog] 按了键却静音 → 重建引擎 #\(mic.restartCount)")
        }

        var target: CGFloat = gated ? 0 : micLevel
        var useBands = gated ? [Float](repeating: 0, count: 32) : bands

        // 预览模式：没有声音也能看当前特效。悬浮配色/特效时一直保持，方便慢慢比较。
        // 调高度时是另一套：不打拍子、直接顶到 97% 满高，让你一眼看到「就是这么高」——
        // 否则静音时 heights 恒为 0，拖滑块只会看到一个空窗口。
        let heightPreview = Date() < heightPreviewUntil
        if heightPreview || Date() < syntheticUntil || previewKey != nil || stylePreviewActive {
            let t = Float(CACurrentMediaTime())
            target = heightPreview ? 0.97 : CGFloat(0.45 + 0.35 * abs(sin(t * 7)))
            var fake = [Float](repeating: 0, count: 32)
            for i in 0..<32 {
                let phase = t * 3.1 + Float(i) * 0.45
                fake[i] = min(1, abs(sin(phase)) * 0.85)
            }
            useBands = fake
        }

        let coeff = target > env ? attackRate : releaseRate
        env += (target - env) * coeff

        // 空闲降帧：静音、没有预览时画面就是一片空白，没必要每秒画 60 次。
        // 只在"确实什么都不发生"时降到 15fps，一有声音立刻回到 60fps，肉眼无感。
        let quiet = env < 0.004 && target < 0.004 && micLevel < 0.004
        idleFrames = quiet ? idleFrames + 1 : 0
        if !quiet || idleFrames % 4 == 0 {
            window.view.render(level: env, bands: useBands)
        }

        frameCount += 1
        if frameCount % 30 == 0 {
            writeDiagnostics(tag: "run")
        }
        if frameCount % 120 == 0 { refreshStatus() }
    }

    @objc private func testFlash() { flash() }

    @objc private func exportShot() {
        flash()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let img = self.window.view.snapshot(),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: "/tmp/followsound-shot-\(self.style.rawValue).png"))
        }
    }

    // 已在运行时再次双击 App，也能看到特效，确认它活着
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.orderFrontRegardless()
        flash()
        return false
    }

    private func flash() {
        env = 1.0
        syntheticUntil = Date().addingTimeInterval(1.6)
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = Style(rawValue: raw) else { return }
        style = s
        window.view.setStyle(s)
        UserDefaults.standard.set(raw, forKey: "style")
        for mi in sender.menu?.items ?? [] { mi.state = (mi === sender) ? .on : .off }
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        theme = Theme.named(key)
        window.view.applyTheme(theme)
        UserDefaults.standard.set(theme.key, forKey: "theme")
        for mi in sender.menu?.items ?? [] { mi.state = (mi === sender) ? .on : .off }
    }

    // ---- 高度：改的是全局 maxBandHeight，窗口跟着一起变，选择会记住 ----
    /// 滑块：拖到哪就是哪。拖动过程中只改内存，不写盘也不打日志 ——
    /// 一次拖动会经过几十上百个整数值，逐格写盘既浪费也没意义，松手（菜单关闭）时补一次。
    @objc private func sliderHeight(_ sender: NSSlider) {
        // 菜单里的控件偶尔会被"路过的鼠标"误触发（菜单跟踪模式下会派发鼠标移动），
        // 没有按键按着就不认，免得手一划窗口自己跳到 400。
        guard NSEvent.pressedMouseButtons != 0 else { return }
        heightTouched = true
        applyHeight(CGFloat(sender.doubleValue.rounded()), write: false)
    }

    /// write=false 用于拖动过程：延迟到菜单关闭再落盘。
    private func applyHeight(_ h: CGFloat, write: Bool = true) {
        let clamped = min(max(h, heightMin), heightMax)
        if abs(clamped - maxBandHeight) > 0.1 {
            maxBandHeight = clamped
            window.setHeight(clamped)
            syncHeightMenu()
        }
        guard write, abs(maxBandHeight - onDiskHeight) > 0.1 else { return }
        onDiskHeight = maxBandHeight
        UserDefaults.standard.set(Double(maxBandHeight), forKey: "bandHeight")
        writeRaw("[height] \(Int(maxBandHeight))pt")
    }

    private func syncHeightMenu() {
        // 拖动时不要去写滑块自己的值：高度被四舍五入成整数，回写会让手感和数值互相拉扯
        if let s = heightSlider, abs(s.doubleValue - Double(maxBandHeight)) > 1.0 {
            s.doubleValue = Double(maxBandHeight)
        }
        heightSliderLabel?.stringValue = "高度 \(Int(maxBandHeight.rounded())) pt"
        heightMenuItem?.title = "高度 \(Int(maxBandHeight.rounded())) pt"
    }

    // ---- 配色 / 特效菜单：悬浮即预览 ----
    // 悬浮到某一项就临时套上它，移开或关菜单则退回已保存的那一项。
    // 配色变的是颜色，特效应变的是图层结构，所以特效预览会跑一次 rebuild ——
    // 只在高亮项真的换了才执行，来回划拉同一项不会反复重建。
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if menu === themeMenu {
            guard let key = item?.representedObject as? String else {
                restoreTheme()
                return
            }
            previewTheme(Theme.named(key))
            return
        }

        if menu === heightMenu {
            // 高度菜单里只剩一个滑块，没有"划一下预览"的对象；满高预览由 menuWillOpen 开、
            // menuDidClose 收，这里不用管。
            return
        }

        if menu === styleMenu {
            // 分隔符没有 representedObject。此时 item 为 nil 表示鼠标移出了菜单区域（还原），
            // item 非 nil 只是停在分隔符上，保持现状。
            guard let raw = item?.representedObject as? String else {
                if item == nil { restoreStyle() }
                return
            }
            previewStyle(raw)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === heightMenu else { return }
        // 一展开就顶到满高：静音时 heights 恒为 0，不预览的话拖滑块只能看到空窗口
        heightPreviewUntil = .distantFuture
        heightTouched = false
        writeRaw("[height] preview on")
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === themeMenu { restoreTheme() }
        if menu === styleMenu { restoreStyle() }
        if menu === heightMenu {
            // 拖动滑块期间只改了内存高度，关菜单时补一次落盘
            applyHeight(maxBandHeight, write: true)
            // 真拖过才多留 1.5 秒满高，让人看清"刚才调到了多高"；只是路过菜单就别闪一下
            heightPreviewUntil = heightTouched ? Date().addingTimeInterval(1.5) : .distantPast
            heightTouched = false
        }
    }

    private func previewTheme(_ t: Theme) {
        guard t.key != theme.key else { restoreTheme(); return }
        window.view.applyTheme(t)
        // 静音时特效高度是 0，不把光带临时升起来就看不见颜色变化
        previewKey = t.key
        writeRaw("[preview] \(t.key)")
    }

    private func restoreTheme() {
        guard previewKey != nil || window.view.currentThemeKey != theme.key else { return }
        window.view.applyTheme(theme)
        previewKey = nil
        writeRaw("[preview] restore \(theme.key)")
    }

    private func previewStyle(_ raw: String) {
        guard let s = Style(rawValue: raw) else { return }
        stylePreviewActive = true
        window.view.setStyle(s)
        writeRaw("[preview] style \(raw)")
    }

    private func restoreStyle() {
        guard stylePreviewActive else { return }
        stylePreviewActive = false
        window.view.setStyle(style)
        writeRaw("[preview] restore style \(style.rawValue)")
    }

    @objc private func pickGate(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = GateMode(rawValue: raw) else { return }
        gateMode = m
        UserDefaults.standard.set(raw, forKey: "gateMode")
        syncGateMenu()
        refreshStatus()
        writeDiagnostics(tag: "pickGate")
    }

    /// 手动重连麦克风：万一引擎哑火，不用退出 App 就能救回来
    @objc private func reconnectMic() {
        mic.stop()
        nextMicRetryAt = Date.distantPast
        permissionAsked = false
        mic.start()
        startMicIfPossible()
        writeRaw("[manual] 重连麦克风 → engine=\(mic.isRunning ? "running" : "stopped")")
        refreshStatus()
    }

    private func syncGateMenu() {
        for mi in gateMenuItem?.submenu?.items ?? [] {
            mi.state = ((mi.representedObject as? String) == gateMode.rawValue) ? .on : .off
        }
    }

    /// 菜单里那行状态文字：直接说清"现在为什么不动"
    @objc private func refreshStatus() {
        guard let item = statusInfoItem else { return }
        var parts: [String] = []
        if gateMode == .voice {
            // 直接显示实时电平：一眼能判断"麦在收声"还是"麦哑了"
            if !mic.isRunning {
                parts.append("人声触发 · 麦克风未启动")
            } else if mic.lastDB <= -139 {
                parts.append("人声触发 · 静音中")
            } else {
                parts.append(String(format: "人声触发 · %.0f dB", mic.lastDB))
            }
        } else if gate.isFnDown {
            parts.append("fn 已按下")
        } else if gate.seenAnyEvent {
            parts.append("fn 门控正常 · 待按住")
        } else {
            parts.append("fn 门控正常 · 还没检测到过 fn")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: parts.append("麦克风✓")
        case .notDetermined: parts.append("麦克风待授权")
        default: parts.append("麦克风被拒")
        }
        item.title = "状态：" + parts.joined(separator: " · ")
    }

    /// 退出前放掉麦克风、停掉帧循环：不留一个后台进程继续占着录音设备
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        mic.stop()
        writeRaw("[exit] v\(AppInfo.version)")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // ---- 更新 ----
    @objc private func checkForUpdates() {
        switch Updater.shared.state {
        case .available:
            updateMenuItem?.title = "正在准备下载…"
            Updater.shared.downloadAndInstall()
        case .downloading:
            break   // 已经在下了，别重复点
        default:
            updateMenuItem?.title = "检查更新中…"
            Updater.shared.check()
        }
    }

    private func syncUpdateMenu(_ s: UpdateState) {
        guard let item = updateMenuItem else { return }
        switch s {
        case .idle: item.title = "检查更新"
        case .checking: item.title = "检查更新中…"
        case .upToDate: item.title = "已是最新版本（\(AppInfo.version)）"
        case .available(let v): item.title = "有新版 v\(v)，点击下载并安装"
        case .downloading(let p): item.title = String(format: "下载中 %.0f%%", min(99, p * 100))
        case .ready(let v): item.title = "正在重启到 v\(v)…"
        case .failed(let m): item.title = "更新失败：\(m)"
        }
    }

    @objc private func openSite() { NSWorkspace.shared.open(AppInfo.siteURL) }

    /// 菜单栏图标：白底透明的模板图，系统会按菜单栏明暗自动反色。
    /// 资源缺失时退回 SF Symbol，图标不会整个消失。
    private func applyStatusIcon(to item: NSStatusItem) {
        let img = Bundle.main.image(forResource: "StatusIcon")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: AppInfo.name)
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        item.button?.image = img
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "\(AppInfo.fullName) \(AppInfo.version)"
    }

    private func relocateWindow() {
        guard let scr = NSScreen.main else { return }
        window.setFrame(NSRect(x: scr.frame.minX, y: scr.frame.minY,
                               width: scr.frame.width, height: maxBandHeight + overlayHeadroom), display: true)
        window.view.frame = NSRect(x: 0, y: 0, width: scr.frame.width, height: maxBandHeight + overlayHeadroom)
        window.view.refreshLayout()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
