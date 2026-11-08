//
//  LCGameCloudSaves.swift
//  LiveContainerSwiftUI
//
//  云存档接入（候选 B：复刻 NX2Apple 壳通道）：同步本体是客体引擎自带
//  的 save_sync（dm/host/save_sync.c + iOS 层 SaveSync.m/CloudSaves.m，
//  NX2 引擎与 nxnative main 同源同版），GC 一行文件级同步都不写——本
//  文件只补引擎缺的「配置段」三件事：让玩家选一次文件夹、替他保管
//  security-scoped 书签、每次启动前把文件夹路径递给引擎。
//
//  引擎语义（fork main 8d88b2c7 源码实证，直接据此实现）：
//  - 开关只有环境变量 DM_SAVE_SYNC：值 = 玩家所选文件夹的路径（根文
//    件夹原样，不要自己拼子夹），引擎在 cloud_file() 里自己拼
//    <TITLEID 大写>/save.dmsync（所选夹本身就叫该 TITLEID 时不套第
//    二层）；空 / "0" = 关；"icloud" 是 Mac 专用关键词，iOS 设了只打
//    日志关掉，GC 永不写它。云端布局与 Mac / 单机版 / NX2 壳天然互
//    通，三方选同一个文件夹即共用同一份 save.dmsync。
//  - front_ios.m 的 startGame 在首次存档挂载前无条件调
//    dm_cloud_saves_env()（CloudSaves.m）：DM_SAVE_SYNC 若已由 env
//    文件 / 启动环境给出（且不是它自己上次设的），env 优先、它直接
//    返回不动——依据行 CloudSaves.m: `if (getenv("DM_SAVE_SYNC") &&
//    !fromPick) return;`。所以 GC 经 env.txt 递路径是引擎正路；客体
//    boot_env() 先读容器 Documents/env.txt（NX2 引擎树 main.m 同一
//    实现，行 247/386），时序与 Mod / 金手指维护相同（启动派发前在
//    runApp 漏斗里维护，客体读到时已是维护结果）。
//  - 同步时机全自动、没有手动同步概念：首次存档挂载拉取、每次
//    Commit 后 sender 线程静默 3 秒打包推送、切后台 20 秒刷盘；冲突
//    按 <DM_SAVE>.sync 的 base 哈希三方比对，两边都变了比包内最新
//    mtime、新者赢、输家先整体备份到 <DM_SAVE>-backups（与 GC 导入
//    备份同一个 save-backups 目录，引擎命名为「日期 时间 local|
//    cloud」，GC 的展示 / 清理不要误删）。
//  - iOS 上光有路径不够：文件夹在沙箱外，必须有进程内的 security
//    scope 授予引擎才读写得了。单机版靠启动器选夹的书签由客体自己
//    解析持 scope；壳形态靠壳进程解析持 scope、同进程的引擎使用。
//    GC 与客体同进程直跑，本文件的 envValue 在启动维护时解析书签并
//    在 GC 进程内持有 scope——与壳形态同构。
//
//  书签保管（宿主侧、按游戏一份，与 LCCustomCoverStore 的「宿主
//  Documents 下按 bundleId 一游戏一文件」同法）：
//  Documents/CloudSaves/<bundleId>.plist，内容 {bookmark: Data,
//  folderName: String, off: Bool}。书签与创建它的 App 签名身份绑定：
//  GC 重签（换证书）后旧书签解析失败是机制固有属性（单机版 / 壳同
//  样），本文件一律按「失效」处理——启动维护不写 env 行（视为未配
//  置），设置页提示重新选择，绝不阻塞启动、绝不崩溃。系统报 stale
//  但仍能解析的（同签名下文件夹移动等），解析时顺手以新书签重写
//  记录（与 NX2 BookmarkStore 同法）。玩家在单机版 / 壳里选过的书
//  签不在 GC 的域里、也必然 stale，GC 不读不搬，只用自己进程里选
//  的这一份。
//
//  关闭语义：设置页「关闭云存档」只置 off 标记（书签保留，重新开
//  启不用再选夹）；「移除」删整份记录。两种情形下次启动维护都会删
//  掉 env.txt 的 DM_SAVE_SYNC 行，引擎即关。管理动作只动记录本
//  身、绝不直接写 env.txt——一切效果经启动前维护生效，与 Mod /
//  金手指同一模式。
//
//  env 维护与 Mod / 金手指共用单一写者：LCGameMods.maintainEnvLine
//  是 env.txt 的唯一行级写者，LCGameMods.refreshEnvOverlay 在同一
//  次维护里继 DM_ROMFS_OVERLAY、DM_CHEATS 之后维护 DM_SAVE_SYNC
//  行——本文件只提供 envValue（现解析书签 + 持 scope + 给路径），
//  不碰 env.txt。与 env 锁定逻辑的关系同另两行：这行由 GC 独占维
//  护，玩家手写的同名行在下次启动被维护结果覆盖。
//
//  scope 持有与释放：静态持有一份（同一时刻只跑一款游戏，与串行
//  单开同构）。经典模式下进程随游戏退出被系统回收、新进程回库，
//  持有自然终结（引擎自己的 CloudSaves.m 也是「从不主动停、进程
//  随游戏退出」同法）；下一次启动维护（无论哪款游戏）先释放上一
//  份再解析新的一份（与 NX2 BookmarkStore 的替换语义同法），设置
//  页里关闭 / 移除 / 改选文件夹时也即时释放被替换的那一份。
//

import SwiftUI
import UniformTypeIdentifiers

enum LCGameCloudSaves {
    static let envKey = "DM_SAVE_SYNC"

    /// 书签造 / 解的 scope 选项：Swift 侧的 .withSecurityScope
    /// （URL / NSURL 两套 OptionSet 静态成员都是）在本仓的 iOS 15
    /// 部署目标 + CI 的 Xcode 26.2 下被 SDK 标为 iOS unavailable
    /// （PR #32 两轮 CI 实证），只能按 ObjC 头里的公开数值常量用
    /// rawValue 构造——NSURLBookmarkCreationWithSecurityScope
    /// (1<<11) / NSURLBookmarkResolutionWithSecurityScope (1<<9)，
    /// iOS 7 起的 ABI 常量，与引擎 CloudSaves.m 传的是同一个值。
    private static let bookmarkCreateOptions = NSURL.BookmarkCreationOptions(rawValue: 1 << 11)
    private static let bookmarkResolveOptions = NSURL.BookmarkResolutionOptions(rawValue: 1 << 9)

    /// 一款游戏的云存档记录（宿主 Documents/CloudSaves/<bundleId>.plist）
    struct Record: Codable {
        var bookmark: Data
        /// 显示用文件夹名（选夹时取所选夹名，之后不随解析结果变）
        var folderName: String
        /// 已关闭（书签保留、引擎不启用）；false = 开启
        var isOff: Bool
    }

    /// 设置页与启动维护共用的状态判定
    enum State: Equatable {
        /// 没有记录
        case notConfigured
        /// 有书签、已关闭
        case off(folderName: String)
        /// 有书签、开启、当前能解析
        case on(folderName: String)
        /// 有书签、开启、解析失败（多为 GC 换签名后旧书签失效）
        case stale(folderName: String)
    }

    // MARK: 记录存取（宿主侧、按游戏一份 plist）

    static var directoryURL: URL {
        LCPath.docPath.appendingPathComponent("CloudSaves", isDirectory: true)
    }

    static func fileURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        directoryURL.appendingPathComponent("\(bundleIdentifier).plist")
    }

    static func record(forBundleIdentifier bundleIdentifier: String) -> Record? {
        let url = fileURL(forBundleIdentifier: bundleIdentifier)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? PropertyListDecoder().decode(Record.self, from: data)
    }

    private static func save(_ record: Record, forBundleIdentifier bundleIdentifier: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? PropertyListEncoder().encode(record) else {
            return
        }
        // 临时文件 + 替换，避免写一半被读到（与 LCCustomCoverStore.save 同法）
        let target = fileURL(forBundleIdentifier: bundleIdentifier)
        let tmp = directoryURL.appendingPathComponent(".\(bundleIdentifier).tmp.plist")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else {
            return
        }
        if fm.fileExists(atPath: target.path) {
            try? fm.removeItem(at: target)
        }
        try? fm.moveItem(at: tmp, to: target)
    }

    static func removeRecord(forBundleIdentifier bundleIdentifier: String) {
        releaseHeldScope()
        try? FileManager.default.removeItem(at: fileURL(forBundleIdentifier: bundleIdentifier))
    }

    // MARK: 书签（照 NX2 BookmarkStore / 引擎 CloudSaves.m 的 fresh 口径）

    /// 为刚选的文件夹造书签：必须带 .withSecurityScope 造——不带这
    /// 个选项的书签能解析回路径、却不携带任何沙箱授予，下次启动
    /// startAccessing 返 false、引擎读写文件夹被沙箱拒（首版就栽在
    /// 这里：书签造时 options 传空，设置页显示已开启、env 也递了
    /// 路径，引擎却碰不到文件夹，云端永远不落文件）。造完当场按解
    /// 析口径验一遍：解析得回且授予探针能过才算成。
    private static func freshBookmark(for url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? (url as NSURL).bookmarkData(options: bookmarkCreateOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        var stale: ObjCBool = false
        guard let resolved = try? NSURL(resolvingBookmarkData: data, options: bookmarkResolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale),
              grantsAccess(resolved as URL) else {
            return nil
        }
        return data
    }

    /// 授予探针：解析出的 URL 真持 startAccessing 一次——返 true 才
    /// 说明书签带着 security scope 授予；返 false = 只有路径没有授
    /// 予（无 scope 的旧书签 / 授予已失），按失效处理。探完即停，
    /// 不留持有（真正的持有在启动维护的 envValue 里）。
    private static func grantsAccess(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else {
            return false
        }
        url.stopAccessingSecurityScopedResource()
        return true
    }

    /// 解析书签。resolvable 但系统报 stale 时把新书签回写进记录
    /// （同签名下可自愈）；解析不出返回 nil（签名已变等），记录原样
    /// 保留——状态判定会把它呈现为「失效」等玩家重选或移除。
    private static func resolve(_ record: Record, forBundleIdentifier bundleIdentifier: String) -> URL? {
        var stale: ObjCBool = false
        guard let resolved = try? NSURL(resolvingBookmarkData: record.bookmark, options: bookmarkResolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale),
              grantsAccess(resolved as URL) else {
            return nil
        }
        let url = resolved as URL
        if stale.boolValue, let fresh = freshBookmark(for: url) {
            var updated = record
            updated.bookmark = fresh
            save(updated, forBundleIdentifier: bundleIdentifier)
        }
        return url
    }

    // MARK: 设置页动作

    /// 玩家刚选完文件夹：造书签存记录（开启态）。失败返回 false，
    /// 什么都不存（不能把验不过的书签当好的存下）。
    static func storePickedFolder(_ url: URL, forBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let bookmark = freshBookmark(for: url) else {
            return false
        }
        releaseHeldScope()
        save(Record(bookmark: bookmark, folderName: url.lastPathComponent, isOff: false),
             forBundleIdentifier: bundleIdentifier)
        return true
    }

    /// 关闭 / 重新开启：只翻 off 标记，书签与名字保留
    static func setOff(_ off: Bool, forBundleIdentifier bundleIdentifier: String) {
        guard var record = record(forBundleIdentifier: bundleIdentifier) else {
            return
        }
        record.isOff = off
        save(record, forBundleIdentifier: bundleIdentifier)
        if off {
            releaseHeldScope()
        }
    }

    /// 当前状态：无记录 / 关 / 开 / 失效。解析只为判定，不持 scope
    /// （真正持有在启动维护的 envValue 里）。
    static func state(forBundleIdentifier bundleIdentifier: String) -> State {
        guard let record = record(forBundleIdentifier: bundleIdentifier) else {
            return .notConfigured
        }
        if record.isOff {
            return .off(folderName: record.folderName)
        }
        return resolve(record, forBundleIdentifier: bundleIdentifier) != nil
            ? .on(folderName: record.folderName)
            : .stale(folderName: record.folderName)
    }

    // MARK: 启动维护（scope 持有 + env 值）

    /// 进程内持有的那一份 scope（串行单开，同一时刻至多一款在跑）
    private static var heldScopeURL: URL?

    private static func releaseHeldScope() {
        heldScopeURL?.stopAccessingSecurityScopedResource()
        heldScopeURL = nil
    }

    /// DM_SAVE_SYNC 的值：开启且书签可解析时为所选文件夹的路径
    /// （根文件夹原样——TITLEID 子夹由引擎自己拼），并把这个文件
    /// 夹的 security scope 在 GC 进程内持有到下一次维护 / 进程结
    /// 束（客体同进程，引擎读写云端文件夹靠它）。未配置 / 已关闭 /
    /// 书签失效一律返回 nil（维护方据此删 env 行 = 引擎关），失效
    /// 绝不挡启动。
    static func envValue(forBundleIdentifier bundleIdentifier: String) -> String? {
        releaseHeldScope()
        guard let record = record(forBundleIdentifier: bundleIdentifier), !record.isOff,
              let url = resolve(record, forBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        // resolve 已过授予探针，这里再持一次并认结果：万一授予在两
        // 次调用间失效，返 false 就当未配置（删 env 行），不把一条
        // 引擎碰不到的路径递出去假装在同步
        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }
        heldScopeURL = url
        return url.path
    }
}

// MARK: - 设置页「云存档」组（一行：同步文件夹）

/// 门控与「Mod」组同口径：有默认容器才显示（还没容器的游戏先进一
/// 次游戏再回来配）。行形态与 LCSaveDataSectionView 的导航行同语
/// 言：未选择时点开直接选夹；已开启点开是菜单（更换文件夹 / 关闭
/// 云存档）；已关闭可重新开启；书签失效提示重新选择。
struct LCGameCloudSavesSectionView: View {
    let app: LCAppModel
    /// 宿主页面的状态刷新计数（与 Mod / 金手指组同一信号）
    var refreshToken: Int = 0

    @State private var hasContainer = false
    @State private var state: LCGameCloudSaves.State = .notConfigured
    @State private var picking = false
    @State private var resultTitle: String?
    @State private var resultMessage: String?

    // 与 LCSaveDataSectionView / LCGameSettingsView 的 LCNXColor 同值
    private static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    private static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    private static let hairline = Color.white.opacity(0.08)
    private static let attention = Color(red: 1, green: 0.78, blue: 0.24)

    var body: some View {
        // Group 透明包裹：无容器时整组缺席，与「Mod」组自隐同效
        Group {
            if hasContainer {
                section
            }
        }
        .onAppear { reload() }
        .onChange(of: refreshToken) { _ in reload() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                if LCGameCloudSaves.storePickedFolder(url, forBundleIdentifier: app.bundleIdentifier) {
                    reload()
                } else {
                    resultTitle = "lc.cloud.section".loc
                    resultMessage = "lc.cloud.pickFailed".loc
                }
            }
        }
        .alert(resultTitle ?? "", isPresented: resultPresented) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private var resultPresented: Binding<Bool> {
        Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil; resultTitle = nil } }
        )
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lc.cloud.section".loc.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(Self.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                rowWithActions
                Text("lc.cloud.note".loc)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Self.hairline, lineWidth: 1)
            }
        }
    }

    /// 那一行：未配置 = 按钮（点开直接选夹）；其余状态 = 菜单
    /// （动作随状态：更换 / 关闭 / 重新开启 / 重新选择 / 移除）
    @ViewBuilder
    private var rowWithActions: some View {
        switch state {
        case .notConfigured:
            Button {
                picking = true
            } label: {
                row(value: "lc.cloud.notPicked".loc, valueColor: .white.opacity(0.5))
            }
            .buttonStyle(.plain)
        case .on(let folderName):
            Menu {
                Button("lc.cloud.changeFolder".loc) { picking = true }
                Button("lc.cloud.turnOff".loc) {
                    LCGameCloudSaves.setOff(true, forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
            } label: {
                row(value: folderName, valueColor: Self.cream)
            }
        case .off(let folderName):
            Menu {
                Button("lc.cloud.turnOn".loc) {
                    LCGameCloudSaves.setOff(false, forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
                Button("lc.cloud.changeFolder".loc) { picking = true }
                Button("lc.cloud.remove".loc, role: .destructive) {
                    LCGameCloudSaves.removeRecord(forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
            } label: {
                row(value: "lc.cloud.off".loc, valueColor: .white.opacity(0.5), detail: folderName)
            }
        case .stale:
            Menu {
                Button("lc.cloud.repick".loc) { picking = true }
                Button("lc.cloud.remove".loc, role: .destructive) {
                    LCGameCloudSaves.removeRecord(forBundleIdentifier: app.bundleIdentifier)
                    reload()
                }
            } label: {
                row(value: "lc.cloud.stale".loc, valueColor: Self.attention)
            }
        }
    }

    /// NX 导航行同语言：标签 15 medium 白、值 14.5 semibold、chevron
    /// 13 bold 白 0.4、行 minHeight 48（与 LCSaveDataSectionView.row 同规格）
    private func row(value: String, valueColor: Color, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text("lc.cloud.folderRow".loc)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(value)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func reload() {
        hasContainer = LCGameLibraryInfo.defaultContainer(for: app) != nil
        state = LCGameCloudSaves.state(forBundleIdentifier: app.bundleIdentifier)
    }
}
