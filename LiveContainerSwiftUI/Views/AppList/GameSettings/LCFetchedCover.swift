//
//  LCFetchedCover.swift
//  LiveContainerSwiftUI
//
//  联网获取封面（Phase 19）：没有自定义 / 客体自带 / 内置原画的游戏，按其
//  Switch 标题 ID 联网抓一次官方横版主视觉，存宿主 Documents/FetchedCovers/
//  <bundleId>.jpg，解析链排在内置原画之后、图标兜底之前（见
//  LCGameLibraryInfo.bannerResolution）。
//
//  端点验证结论（2026-11-05 实测，丝之歌 010013C00E930000 / 哈迪斯 II
//  0100A00019DE0000 双 ID 逐个验，只接验通的）：
//  - 接入：ec.nintendo.com/apps/<标题ID>/US（任天堂官方按 ID 跳转）
//    → www.nintendo.com 商品页（约 330–430KB HTML）→ __NEXT_DATA__ 的
//    schema.org linkedData.image（assets.nintendo.com）→ 两款实测均为
//    1920×1080 官方主视觉（带 logo 的 key art）。无效 ID 时该域名直回
//    404，失败干净。桌面 / 移动 UA 返回同一页面。
//  - 不接：img-eshop.cdn.nintendo.net 的 bannerUrl 图本身也是 1920×1080，
//    但标题 ID → 图 URL 的映射只存在于 blawar/titledb 的整包 JSON
//    （US.en.json 约 88MB 且按 nsuid 索引），无按 ID 端点，禁止整包下设备。
//  - 不接：tinfoil.media / tinfoil.io 的 /ti/ /thi/ /i/ 图片端点实测全程
//    503（图片服务停机），无法验通；search.nintendo.jp 仅支持名称检索
//    （按标题 ID 查 0 结果，条目不含标题 ID）；SteamGridDB API 无 key
//    时 401。
//
//  抓取纪律：同一游戏并发只发一发；失败（含商品页无图 / 图不达标）记
//  负缓存时间戳，7 天内不重试；全程静默，失败不打扰用户。抓不到的游戏
//  由主页大卡的无图兜底美化接住（LCGameCoverView.beautifiedFallback）。
//

import ImageIO
import SwiftUI

// MARK: - 存储（宿主 Documents/FetchedCovers/<bundleId>.jpg）

enum LCFetchedCoverStore {
    /// 落盘规格与 LCCustomCoverStore 同款：长边 1600px、JPEG 0.85、原子写
    private static let maxPixelDimension: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.85

    static var directoryURL: URL {
        LCPath.docPath.appendingPathComponent("FetchedCovers", isDirectory: true)
    }

    static func fileURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        directoryURL.appendingPathComponent("\(bundleIdentifier).jpg")
    }

    static func exists(forBundleIdentifier bundleIdentifier: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forBundleIdentifier: bundleIdentifier).path)
    }

    static func load(forBundleIdentifier bundleIdentifier: String) -> UIImage? {
        let url = fileURL(forBundleIdentifier: bundleIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    static func save(_ image: UIImage, forBundleIdentifier bundleIdentifier: String) throws {
        let resized = resizedForStorage(image)
        guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
            throw LCCustomCoverError.encodeFailed
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let target = fileURL(forBundleIdentifier: bundleIdentifier)
        let tmp = directoryURL.appendingPathComponent(".\(bundleIdentifier).tmp.jpg")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)
    }

    static func remove(forBundleIdentifier bundleIdentifier: String) {
        try? FileManager.default.removeItem(at: fileURL(forBundleIdentifier: bundleIdentifier))
    }

    private static func resizedForStorage(_ image: UIImage) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longEdge = max(pixelSize.width, pixelSize.height)
        guard longEdge > maxPixelDimension else {
            return image
        }
        let ratio = maxPixelDimension / longEdge
        let target = CGSize(width: (pixelSize.width * ratio).rounded(), height: (pixelSize.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - 抓取服务（去重入口：导入预抓与展示懒抓共用）

final class LCCoverFetchService {
    static let shared = LCCoverFetchService()

    /// 任一抓取成功后的全局回调：由 LCAppListView 注册，内部 bump 既有
    /// libraryRefresh 令牌让主页按磁盘重算——不新造通知机制。
    var onCoverUpdated: (() -> Void)?

    /// 负缓存重试间隔：7 天
    private static let negativeCacheInterval: TimeInterval = 7 * 24 * 3600
    /// 验收门槛：只收横版宽图（宽 ≥1280 且宽 > 高），小图 / 方图一律当失败
    private static let minimumLandscapeWidth: CGFloat = 1280
    /// 实测与商品页一致的 UA（桌面 / 移动 UA 返回同一页面，用移动版即可）
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var waiters: [String: [() -> Void]] = [:]

    private init() {}

    // MARK: 负缓存（UserDefaults 记每款上次尝试时刻）

    private static func attemptDefaultsKey(for bundleIdentifier: String) -> String {
        "LCFetchedCover.lastAttempt.\(bundleIdentifier)"
    }

    private func negativeCacheIsFresh(for bundleIdentifier: String) -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.attemptDefaultsKey(for: bundleIdentifier))
        guard last > 0 else {
            return false
        }
        return Date().timeIntervalSince1970 - last < Self.negativeCacheInterval
    }

    private func recordNegativeAttempt(for bundleIdentifier: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: Self.attemptDefaultsKey(for: bundleIdentifier))
    }

    func clearNegativeCache(forBundleIdentifier bundleIdentifier: String) {
        UserDefaults.standard.removeObject(forKey: Self.attemptDefaultsKey(for: bundleIdentifier))
    }

    // MARK: 入口

    /// 去重抓取入口：已有更高优先封面 / 已有抓取缓存 / 负缓存新鲜 / 无标题
    /// ID 时直接返回；同一游戏在飞时只登记等待者，不重复发请求。
    /// completion 仅在本次（或在飞的那次）抓取成功时于主线程回调一次。
    func ensureFetched(appInfo: LCAppInfo, completion: (() -> Void)? = nil) {
        guard let bundleIdentifier = appInfo.bundleIdentifier(),
              let titleId = LCGameLibraryInfo.titleId(from: appInfo) else {
            return
        }
        if LCFetchedCoverStore.exists(forBundleIdentifier: bundleIdentifier) {
            return
        }
        // 解析链在抓取层之前已有结果（自定义 / 客体自带 / 内置原画）就不必抓
        if LCGameLibraryInfo.bannerResolution(for: appInfo).image != nil {
            return
        }
        if negativeCacheIsFresh(for: bundleIdentifier) {
            return
        }

        lock.lock()
        if let completion {
            waiters[bundleIdentifier, default: []].append(completion)
        }
        let alreadyFlying = inFlight.contains(bundleIdentifier)
        if !alreadyFlying {
            inFlight.insert(bundleIdentifier)
        }
        lock.unlock()
        guard !alreadyFlying else {
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            let image = await self.fetchStoreCover(titleId: titleId)
            var saved = false
            if let image {
                saved = (try? LCFetchedCoverStore.save(image, forBundleIdentifier: bundleIdentifier)) != nil
            }
            if !saved {
                self.recordNegativeAttempt(for: bundleIdentifier)
            }
            self.lock.lock()
            self.inFlight.remove(bundleIdentifier)
            let callbacks = self.waiters.removeValue(forKey: bundleIdentifier) ?? []
            self.lock.unlock()
            guard saved else {
                return
            }
            DispatchQueue.main.async {
                callbacks.forEach { $0() }
                self.onCoverUpdated?()
            }
        }
    }

    /// 导入完成时的预抓（无单独回调，成功后走全局 onCoverUpdated 刷新库）
    func prefetch(appInfo: LCAppInfo) {
        ensureFetched(appInfo: appInfo)
    }

    // MARK: 抓取实现（已验通的任天堂官方链）

    /// ec.nintendo.com/apps/<标题ID>/US → 商品页 HTML → linkedData.image → 图。
    /// 任一步失败 / 图不达标都返回 nil（由调用方记负缓存），全程静默。
    private func fetchStoreCover(titleId: String) async -> UIImage? {
        guard let pageURL = URL(string: "https://ec.nintendo.com/apps/\(titleId)/US") else {
            return nil
        }
        var pageRequest = URLRequest(url: pageURL)
        pageRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        pageRequest.timeoutInterval = 30
        guard let (pageData, pageResponse) = try? await URLSession.shared.data(for: pageRequest),
              (pageResponse as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: pageData, encoding: .utf8),
              let imageURL = Self.extractStoreImageURL(fromHTML: html) else {
            return nil
        }

        var imageRequest = URLRequest(url: imageURL)
        imageRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        imageRequest.timeoutInterval = 30
        guard let (imageData, imageResponse) = try? await URLSession.shared.data(for: imageRequest),
              (imageResponse as? HTTPURLResponse)?.statusCode == 200,
              let pixelSize = Self.imagePixelSize(data: imageData),
              pixelSize.width >= Self.minimumLandscapeWidth, pixelSize.width > pixelSize.height,
              let image = UIImage(data: imageData) else {
            return nil
        }
        return image
    }

    /// 商品页主图提取：首选 __NEXT_DATA__ JSON 里的 schema.org linkedData
    /// （VideoGame/Product 条目的 image 字段，实测即官方主视觉）；结构漂移
    /// 时退回正则在整页里找 store/software/switch/<nsuid>/ 路径的 image 值。
    private static func extractStoreImageURL(fromHTML html: String) -> URL? {
        if let open = html.range(of: "id=\"__NEXT_DATA__\""),
           let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
           let close = html.range(of: "</script>", range: tagEnd.upperBound..<html.endIndex) {
            let jsonText = html[tagEnd.upperBound..<close.lowerBound]
            if let data = jsonText.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let props = root["props"] as? [String: Any],
               let pageProps = props["pageProps"] as? [String: Any],
               let linkedData = pageProps["linkedData"] as? [Any] {
                for entry in linkedData {
                    guard let dict = entry as? [String: Any],
                          let image = dict["image"] as? String,
                          let url = URL(string: image),
                          url.host == "assets.nintendo.com" else {
                        continue
                    }
                    return url
                }
            }
        }
        let pattern = "\"image\"\\s*:\\s*\"(https://assets\\.nintendo\\.com/image/upload/[^\"]*/store/software/switch/[0-9]+/[^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return URL(string: String(html[range]))
        }
        return nil
    }

    /// 只读像素尺寸（不整图解码，与 LCGameLibraryInfo 的同名做法一致）
    private static func imagePixelSize(data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else {
            return nil
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }
}
