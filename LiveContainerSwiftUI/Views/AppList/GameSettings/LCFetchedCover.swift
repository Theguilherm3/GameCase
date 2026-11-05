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
//  兜底路线（2026-11-06 实测）：标题 ID 在 ec 解析器里没有条目时（区域
//  独立全量包等），ID 路线必然失败，改用客体显示名走 nintendo.com 商店
//  搜索（Algolia，配置取自官网前端公开的仅搜索 key，索引
//  store_game_en_us）→ 名称精确 / 近似全等命中的商品页 → 同一
//  linkedData 提取与验收门槛。以撒 Repentance（010021C000222000，
//  US/JP/GB/DE/FR/AU 六区 ec 跳转全 404）实测：名搜返回 2 条，首条是
//  「Repentance+」(Switch 2 版，nsuid 70010000106369)，次条才是精确
//  命中的 DLC 商品页 nsuid 70050000031296（linkedData 主图
//  1920×1080）；仅给部分名（如「Isaac」）或模糊词时命中一堆但无一
//  全等。故纪律是：只收名称全等命中（见 storeNamesMatch 两档归一），
//  落到商品页后还要用 linkedData 条目自带的 name 再复核一次，两关
//  都过才收图；多义 / 模糊命中一律放弃、静默走原兜底，绝不抓错图。
//  名搜失败与 ID 失败共用同一条负缓存（整链失败才记账），「封面图 →
//  恢复默认」清负缓存后两条路线都会重开重抓。
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

/// 内部可变状态（inFlight / waiters）全部由 NSLock 守护，故声明 @unchecked Sendable
final class LCCoverFetchService: @unchecked Sendable {
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
    /// nintendo.com 商店搜索的 Algolia 配置：官网前端 JS 里公开发布的
    /// 仅搜索 key（只能查、不能写）。官方轮换 / 失效时名搜路线静默失败，
    /// 行为退回只有 ID 路线，不影响既有游戏。
    private static let storeSearchAppId = "U3B6GR4UA3"
    private static let storeSearchApiKey = "a29c6927638bfd8cee23993e51e721c9"
    private static let storeSearchIndex = "store_game_en_us"
    /// 名搜命中里最多逐个落页验证几条（全等命中通常只有一条）
    private static let maxNameSearchCandidates = 3

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
            let image = await self.fetchStoreCover(titleId: titleId, displayName: appInfo.displayName())
            var saved = false
            if let image {
                saved = (try? LCFetchedCoverStore.save(image, forBundleIdentifier: bundleIdentifier)) != nil
            }
            let callbacks = self.completeFetch(bundleIdentifier: bundleIdentifier, saved: saved)
            guard saved else {
                return
            }
            DispatchQueue.main.async {
                callbacks.forEach { $0() }
                self.onCoverUpdated?()
            }
        }
    }

    /// 抓取收尾（同步方法）：失败记负缓存，账本（inFlight / waiters）的
    /// 增删都在锁内完成——NSLock 不可直接用于 async 上下文，故收口在此。
    private func completeFetch(bundleIdentifier: String, saved: Bool) -> [() -> Void] {
        if !saved {
            recordNegativeAttempt(for: bundleIdentifier)
        }
        lock.lock()
        inFlight.remove(bundleIdentifier)
        let callbacks = waiters.removeValue(forKey: bundleIdentifier) ?? []
        lock.unlock()
        return callbacks
    }

    /// 导入完成时的预抓（无单独回调，成功后走全局 onCoverUpdated 刷新库）
    func prefetch(appInfo: LCAppInfo) {
        ensureFetched(appInfo: appInfo)
    }

    // MARK: 抓取实现（已验通的任天堂官方链）

    /// 抓取编排：ID 路线先行（ec.nintendo.com/apps/<标题ID>/US → 商品页 →
    /// linkedData.image → 图，本来就通的游戏行为与改前逐字一致）；ID 路线
    /// 失败（404 / 页内无合格图）才走按名搜索兜底。任一路线成功即返回；
    /// 整链失败返回 nil（由调用方记负缓存），全程静默。
    private func fetchStoreCover(titleId: String, displayName: String) async -> UIImage? {
        if let pageURL = URL(string: "https://ec.nintendo.com/apps/\(titleId)/US"),
           let image = await fetchCoverImage(fromProductPage: pageURL, requiredPageName: nil) {
            return image
        }
        return await fetchStoreCoverByName(displayName)
    }

    /// 商品页 → 主图 → 下载验收（宽 ≥1280 且横版）的共用管线。
    /// requiredPageName 为 nil 时走既有提取（含正则兜底）；非 nil 时只认
    /// linkedData 里 name 与目标名精确 / 近似全等的条目（见
    /// extractVerifiedStoreImageURL），名搜落页的防抓错复核在此生效。
    private func fetchCoverImage(fromProductPage pageURL: URL, requiredPageName: String?) async -> UIImage? {
        var pageRequest = URLRequest(url: pageURL)
        pageRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        pageRequest.timeoutInterval = 30
        guard let (pageData, pageResponse) = try? await URLSession.shared.data(for: pageRequest),
              (pageResponse as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: pageData, encoding: .utf8) else {
            return nil
        }
        let imageURL: URL?
        if let requiredPageName {
            imageURL = Self.extractVerifiedStoreImageURL(fromHTML: html, expectedName: requiredPageName)
        } else {
            imageURL = Self.extractStoreImageURL(fromHTML: html)
        }
        guard let imageURL else {
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

    // MARK: 按名搜索兜底（仅 ID 路线失败时）

    /// 用客体显示名查 nintendo.com 商店（Algolia store_game_en_us），只收
    /// 名称精确 / 近似全等的命中，按返回顺序最多落页验证
    /// maxNameSearchCandidates 条；落页时再以商品页 linkedData 自带的
    /// name 复核一次（fetchCoverImage 的 requiredPageName）。无全等命中 /
    /// 全部落页失败 → nil，与 ID 失败共用同一条负缓存记账（整链失败才记，
    /// 「恢复默认」清负缓存时两条路线一并重开）。
    private func fetchStoreCoverByName(_ displayName: String) async -> UIImage? {
        let query = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2,
              let searchURL = URL(string: "https://\(Self.storeSearchAppId)-dsn.algolia.net/1/indexes/\(Self.storeSearchIndex)/query"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query, "hitsPerPage": 10]) else {
            return nil
        }
        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue(Self.storeSearchAppId, forHTTPHeaderField: "X-Algolia-Application-Id")
        request.setValue(Self.storeSearchApiKey, forHTTPHeaderField: "X-Algolia-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = root["hits"] as? [[String: Any]] else {
            return nil
        }
        var tried = 0
        for hit in hits {
            guard tried < Self.maxNameSearchCandidates,
                  let title = hit["title"] as? String,
                  let path = hit["url"] as? String,
                  path.hasPrefix("/us/store/products/"),
                  Self.storeNamesMatch(title, query),
                  let pageURL = URL(string: "https://www.nintendo.com\(path)") else {
                continue
            }
            tried += 1
            if let image = await fetchCoverImage(fromProductPage: pageURL, requiredPageName: query) {
                return image
            }
        }
        return nil
    }

    /// 名搜落页复核提取：只认 __NEXT_DATA__ 的 linkedData 里同时带
    /// assets.nintendo.com 主图与 name 的条目，且 name 须与目标名精确 /
    /// 近似全等（storeNamesMatch）。没有正则兜底——名搜路线的风险全在
    /// 抓错页，宁可不收也不能靠整页正则蒙中一张图。
    private static func extractVerifiedStoreImageURL(fromHTML html: String, expectedName: String) -> URL? {
        guard let open = html.range(of: "id=\"__NEXT_DATA__\""),
              let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: tagEnd.upperBound..<html.endIndex) else {
            return nil
        }
        let jsonText = html[tagEnd.upperBound..<close.lowerBound]
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let linkedData = pageProps["linkedData"] as? [Any] else {
            return nil
        }
        for entry in linkedData {
            guard let dict = entry as? [String: Any],
                  let name = dict["name"] as? String,
                  storeNamesMatch(name, expectedName),
                  let image = dict["image"] as? String,
                  let url = URL(string: image),
                  url.host == "assets.nintendo.com" else {
                continue
            }
            return url
        }
        return nil
    }

    // MARK: 名称全等护栏

    /// 商店名全等判定：两档归一任一档全等即算命中；绝不做前缀 / 子串 /
    /// 编辑距离式的模糊匹配。
    /// - 严格档：大小写与重音折叠、去 ™®©、空白折叠后逐字相等；
    /// - 压平档：再把 + 读作 plus、& 读作 and，删尽一切非字母数字字符
    ///   后逐字相等（收「NieR:Automata」对「NieR Automata」这类标点差）。
    /// 反例必须不等：「The Binding of Isaac: Repentance」与
    /// 「…Repentance+」——压平档下后者多出 plus，正好挡住商店里同名
    /// 近似款（Switch 2 版）排在精确命中前面的情况。
    static func storeNamesMatch(_ a: String, _ b: String) -> Bool {
        normalizedStoreName(a, squashed: false) == normalizedStoreName(b, squashed: false)
            || normalizedStoreName(a, squashed: true) == normalizedStoreName(b, squashed: true)
    }

    private static func normalizedStoreName(_ name: String, squashed: Bool) -> String {
        // ™®© 先剥再折叠：免得任何折叠实现把 ™ 展开成 TM 之类的残留
        var result = name
        for symbol in ["™", "®", "©"] {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        result = result.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if squashed {
            result = result.replacingOccurrences(of: "+", with: " plus ")
            result = result.replacingOccurrences(of: "&", with: " and ")
            return result.filter { $0.isLetter || $0.isNumber }
        }
        return result.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
