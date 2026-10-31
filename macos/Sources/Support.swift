// 应用元信息、受限诊断日志、GitHub 自动更新
// 三块都不依赖 AppKit 的界面代码，单独放一个文件，方便跨端对照实现。

import AppKit
import Foundation

// ============ 元信息 ============
enum AppInfo {
    /// 中文名（界面文案、关于菜单）
    static let name = "随响"
    static let latinName = "FollowSound"
    static let fullName = "随响 FollowSound"

    static let bundleID = "app.followsound.mac"
    /// 改名前的 bundle id：用来把老用户的偏好设置迁过来
    static let legacyBundleID = "com.local.happyvoice"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// 唯一的更新源：GitHub Releases
    static let repo = "VVCY/FollowSound"
    static let repoURL = URL(string: "https://github.com/VVCY/FollowSound")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/VVCY/FollowSound/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/VVCY/FollowSound/releases/latest")!
    static let siteURL = URL(string: "https://vvcy.github.io/FollowSound/")!

    /// 发布资源命名约定，三端共用一套规则（见 docs/RELEASE.md）
    static func assetName(version: String) -> String { "FollowSound-macOS-\(version).zip" }
}

// ============ 偏好设置迁移 ============
enum Prefs {
    /// 改名会换 bundle id，UserDefaults 域跟着换，老用户的特效/配色/高度会一夜清空。
    /// 启动时把旧域里的键搬过来（只搬新域里还没有的，不覆盖用户改名后新调的值）。
    static func migrateFromLegacyIfNeeded() {
        let new = UserDefaults.standard
        guard new.integer(forKey: "prefsMigratedFrom") < 1 else { return }
        guard let old = UserDefaults(suiteName: AppInfo.legacyBundleID) else {
            new.set(1, forKey: "prefsMigratedFrom")
            return
        }
        for key in ["style", "theme", "bandHeight", "gateMode"] {
            if new.object(forKey: key) == nil, let v = old.object(forKey: key) {
                new.set(v, forKey: key)
            }
        }
        new.set(1, forKey: "prefsMigratedFrom")
    }
}

// ============ 诊断日志 ============
/// 只在显式开启时写盘（环境变量 FS_DIAG=1 或开发构建）。
/// 之前是无条件每 2 秒写一行、文件永不回收，一天能长到几十 MB —— 正式版不需要这些。
final class DiagLog {
    static let shared = DiagLog()

    private var handle: FileHandle?
    private let url: URL
    private let maxBytes: UInt64 = 256 * 1024
    private var written: UInt64 = 0
    let enabled: Bool

    private init() {
        #if DEBUGTOOLS
        enabled = true
        #else
        enabled = ProcessInfo.processInfo.environment["FS_DIAG"] == "1"
        #endif

        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Logs/FollowSound", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("diag.log")

        guard enabled else { return }
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: url.path)
        handle?.seekToEndOfFile()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        written = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        if size > maxBytes {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func write(_ s: String) {
        guard enabled, let h = handle else { return }
        let data = (s + "\n").data(using: .utf8) ?? Data()
        h.write(data)
        written += UInt64(data.count)
        // 跑到上限就截断重来，避免长期驻留把磁盘写满
        if written > maxBytes {
            try? h.truncate(atOffset: 0)
            written = 0
        }
    }
}

// ============ 自动更新（GitHub Releases） ============
struct UpdateRelease {
    let version: String
    let notes: String
    let pageURL: URL
    let assetURL: URL?
    let assetName: String?
    let sizeBytes: Int
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(String)          // 远端版本号
    case downloading(Double)        // 0…1
    case ready(String)
    case failed(String)

    static func == (a: UpdateState, b: UpdateState) -> Bool {
        switch (a, b) {
        case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate): return true
        case let (.available(x), .available(y)): return x == y
        case let (.downloading(x), .downloading(y)): return abs(x - y) < 0.001
        case let (.ready(x), .ready(y)): return x == y
        case let (.failed(x), .failed(y)): return x == y
        default: return false
        }
    }
}

/// 版本比较：1.10 > 1.9，允许 v 前缀和任意段数
func versionIsNewer(_ remote: String, than local: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "-").first.map(String.init)?
            .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } ?? []
    }
    let a = parts(remote), b = parts(local)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

final class Updater {
    static let shared = Updater()

    private(set) var state: UpdateState = .idle
    private(set) var latest: UpdateRelease?
    /// 状态变化回调（主线程）
    var onChange: ((UpdateState) -> Void)?

    private var busy = false
    private let lastCheckKey = "lastUpdateCheck"

    private func set(_ s: UpdateState) {
        state = s
        onChange?(s)
    }

    /// 每天自动查一次；启动后也会静默查一次（不弹窗，只在菜单里挂一行）
    func autoCheckIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last > 24 * 3600 else { return }
        check(silent: true)
    }

    func check(silent: Bool = false) {
        guard !busy else { return }
        busy = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        set(.checking)

        var req = URLRequest(url: AppInfo.releasesAPI)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FollowSound-macOS/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            func fail(_ msg: String) {
                DispatchQueue.main.async {
                    self.busy = false
                    // 静默检查失败不打扰用户，直接回到 idle
                    self.set(silent ? .idle : .failed(msg))
                }
            }
            if let err { return fail(err.localizedDescription) }
            guard let http = resp as? HTTPURLResponse else { return fail("网络无响应") }
            guard http.statusCode == 200, let data else {
                return fail(http.statusCode == 404 ? "还没有发布过版本" : "GitHub 返回 \(http.statusCode)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return fail("版本信息解析失败") }

            let ver = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let notes = (obj["body"] as? String) ?? ""
            let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesPage
            let assets = (obj["assets"] as? [[String: Any]]) ?? []
            // 优先取命名约定里的那个 zip；没有就退回第一个 zip
            let wanted = AppInfo.assetName(version: ver)
            let picked = assets.first { ($0["name"] as? String) == wanted }
                ?? assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip") }

            let rel = UpdateRelease(
                version: ver,
                notes: notes,
                pageURL: page,
                assetURL: (picked?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                assetName: picked?["name"] as? String,
                sizeBytes: (picked?["size"] as? Int) ?? 0
            )

            DispatchQueue.main.async {
                self.busy = false
                self.latest = rel
                if versionIsNewer(ver, than: AppInfo.version) {
                    self.set(.available(ver))
                } else {
                    self.set(.upToDate)
                }
            }
        }.resume()
    }

    /// 下载 zip → 解包 → 用一个脱离的脚本替换 App → 重新拉起
    func downloadAndInstall() {
        guard let rel = latest, let assetURL = rel.assetURL else {
            set(.failed("没有可下载的安装包"))
            return
        }
        set(.downloading(0))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FollowSound-\(rel.version).zip")
        try? FileManager.default.removeItem(at: tmp)

        let task = URLSession.shared.downloadTask(with: assetURL) { [weak self] location, _, err in
            guard let self else { return }
            guard let location, err == nil else {
                DispatchQueue.main.async { self.set(.failed("下载失败：\(err?.localizedDescription ?? "未知错误")")) }
                return
            }
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.moveItem(at: location, to: tmp)
                try self.install(zip: tmp, version: rel.version)
            } catch {
                DispatchQueue.main.async { self.set(.failed("安装失败：\(error.localizedDescription)")) }
            }
        }
        // 进度：只做粗略百分比，包体只有几百 KB，够用
        let obs = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.set(.downloading(p.fractionCompleted)) }
        }
        progressObserver = obs
        task.resume()
    }

    private var progressObserver: NSKeyValueObservation?

    private func install(zip: URL, version: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("FollowSound-update-\(version)")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, work.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "FollowSound", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "解压失败"]) }

        // 解出来的 .app 可能在顶层，也可能套了一层目录
        let items = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = items.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "FollowSound", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "压缩包里没有 .app"])
        }
        guard let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              (plist["CFBundleIdentifier"] as? String) == AppInfo.bundleID else {
            throw NSError(domain: "FollowSound", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "包内 App 身份不符，已中止"])
        }

        // 自己在运行时没法安全地覆盖自己：写一个脱离的脚本，等本进程退出后再替换
        let dest = Bundle.main.bundleURL
        let script = fm.temporaryDirectory.appendingPathComponent("followsound-update.sh")
        let body = """
        #!/bin/sh
        # 等旧进程退出
        for i in $(seq 1 60); do
          pgrep -f "\(dest.path)/Contents/MacOS/" >/dev/null 2>&1 || break
          sleep 0.2
        done
        rm -rf "\(dest.path).old"
        mv "\(dest.path)" "\(dest.path).old" || exit 1
        cp -R "\(newApp.path)" "\(dest.path)" || { mv "\(dest.path).old" "\(dest.path)"; exit 2; }
        /usr/bin/xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
        rm -rf "\(dest.path).old" "\(work.path)" "\(zip.path)"
        /usr/bin/open "\(dest.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = [script.path]
        try runner.run()

        DispatchQueue.main.async {
            self.set(.ready(version))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
        }
    }
}
