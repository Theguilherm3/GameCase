//
//  LCGameHomeView.swift
//  LiveContainerSwiftUI
//
//  游戏库主页（NX2Apple 壳式界面，按已批准预览 lc-nxstyle-port/land-v1 实现）：
//  竖屏 = 封面大图 + 你的游戏双列 + 最近游玩 + 底部开始大胶囊；
//  横屏 = 封面色调模糊背景 + 卡片轮播 + 右上按钮排。
//  本视图只负责呈现与聚焦状态，启动 / 设置 / 导入 / 卸载等动作全部走
//  LCAppListView 的既有机制（回调注入），JIT sheet 与错误 alert 仍锚在列表层。
//

import SwiftUI
import GameController

// MARK: - 游戏库配色（自旧 LCGameCardView 抽出的共享常量，设置页 / 导入页也在用）

enum LCGameTheme {
    static let creamColor = Color(red: 0.965, green: 0.929, blue: 0.839)
    static let accentColor = Color(red: 0.788, green: 0.373, blue: 0.263)
    static let cardBackground = Color(red: 0.118, green: 0.118, blue: 0.129)

    // NX 预览取值
    static let pageBackground = Color(red: 10 / 255, green: 10 / 255, blue: 11 / 255)
    static let nxCream = Color(red: 1.0, green: 240 / 255, blue: 214 / 255)
    static let mutedText = Color(red: 158 / 255, green: 158 / 255, blue: 164 / 255)
    static let sectionText = Color(red: 228 / 255, green: 224 / 255, blue: 218 / 255)
    static let readyGreen = Color(red: 64 / 255, green: 214 / 255, blue: 120 / 255)
    static let missingAmber = Color(red: 1.0, green: 176 / 255, blue: 66 / 255)
    /// 已损坏（状态机三态新增，与设置页 LCNXColor.broken 同值）
    static let brokenRed = Color(red: 1.0, green: 0.42, blue: 0.38)
    static let chipBackground = Color(red: 30 / 255, green: 28 / 255, blue: 29 / 255).opacity(0.92)
    static let chipBorder = Color.white.opacity(0.18)
    static let chipIcon = Color(red: 232 / 255, green: 230 / 255, blue: 228 / 255)
}

// MARK: - 封面图（横版封面 → 图标兜底，与旧卡片 coverView 同语义）

struct LCGameCoverView: View {
    let app: LCAppModel
    let darkModeIcon: Bool
    /// 库内容刷新令牌（列表层在设置页 / 导入页关闭后 bump）：封面是 body 里
    /// 现读磁盘算出来的，本视图不观察任何状态，令牌不变 body 就不重跑、
    /// 换完封面仍显示旧图。令牌作为入参变化即触发重解析。
    let refreshToken: Int
    /// 无横图兜底美化（Phase 19）：仅主页大卡（竖屏 hero）与横屏牌组卡
    /// 打开——解析落到图标时不再把图标拉伸充数，改 NX 无横图同款语言
    /// （与设置页头部 Phase 17 的无横图路同源）。小缩略图（最近游玩 /
    /// 网格卡 / 横屏背景晕染）保持旧兜底，不传此旗。
    var beautifiedFallback: Bool = false

    var body: some View {
        let _ = refreshToken
        if let bannerImage = LCGameLibraryInfo.bannerImage(for: app.appInfo) {
            Image(uiImage: bannerImage)
                .resizable()
                .scaledToFill()
        } else if let iconImage = app.appInfo.iconIsDarkIcon(darkModeIcon) {
            if beautifiedFallback {
                beautifiedIconFallback(iconImage: iconImage)
            } else {
                ZStack {
                    Image(uiImage: iconImage)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 24)
                        .opacity(0.75)
                    Image(uiImage: iconImage)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                }
            }
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.06))
        }
    }

    /// 美化兜底：图标自体放大 1.4 + blur 40 + saturation 1.2 铺满卡面、
    /// 黑 0.38 叠压（NX PaneBanner 无横图底原值），中央叠一张清晰图标，
    /// 边长 = 卡高 55%，圆角 / 描边 / 阴影按 NX CoverThumbnail 规格
    /// （圆角比 0.2、白 0.14 描边、阴影 black 0.4 / r16 / y6）。
    private func beautifiedIconFallback(iconImage: UIImage) -> some View {
        GeometryReader { geo in
            let side = geo.size.height * 0.55
            ZStack {
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(1.4)
                    .blur(radius: 40)
                    .saturation(1.2)
                    .clipped()
                Color.black.opacity(0.38)
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

// MARK: - 游戏库主页

struct LCGameHomeView: View {
    let apps: [LCAppModel]
    let hiddenAppsCount: Int
    let multiLCStatus: Int
    let installProgressVisible: Bool
    let installProgress: Float
    /// 真实安全区：由 LCAppListView 从不忽略安全区的层级读出后注入。
    /// 本视图内部 GeometryReader 带 .ignoresSafeArea()，它读到的
    /// geo.safeAreaInsets 恒为 0，不能直接用作浮钮排的定位依据。
    let safeAreaInsets: EdgeInsets
    /// 安全区尺寸：同一个列表层 GeometryReader 的 size。NX CoverFlow 的
    /// 度量参考系就是安全区 geometry（LibraryView 把 geometry.size 与
    /// safeAreaInsets 一起传给 CoverFlowView），横屏度量按它算。
    let safeSize: CGSize
    /// 库内容刷新令牌：变化即本视图 body 重跑，封面与数据包状态点按磁盘重算
    let refreshToken: Int

    var onRun: (LCAppModel) -> Void
    var onSettings: (LCAppModel) -> Void
    var onOpenDataFolder: (LCAppModel) -> Void
    var onImportDatapack: (LCAppModel) -> Void
    var onUninstall: (LCAppModel) -> Void
    var onImportIPA: () -> Void
    var onImportDatapackGeneric: () -> Void
    var onOpenHiddenApps: () -> Void
    var onOpenContainerSettings: () -> Void

    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    /// 游玩时长快照（Phase 18）：磁盘现读，本视图不观察统计文件，靠出现 /
    /// 刷新令牌两个时点重读（见 body 的 onAppear / onChange）。
    @State private var playStats: [String: LCPlayStats.Entry] = [:]
    @State private var focusKey: String?
    @StateObject private var controllerMonitor = LCControllerMonitor()
    /// 手柄页呈现状态（Phase 22 起统一走 LCSidePanelContainer 自适应
    /// 宿主：横屏 = 右侧面板、竖屏 = 整屏，形态随当前尺寸跟随、旋转
    /// 原地变形；Phase 14 的 sheet / 面板打开时二选一已废除）
    @State private var controllerPanelPresented = false

    @State private var stateHelpTarget: LCGameStateTarget?

    // 库顺序快照（照 NX2 LibraryOrder 的分组排序，竖屏网格与横屏
    // 牌组共用）：主页出现时按「最近游玩 → 可玩 → 缺数据包 →
    // 已损坏」（组内规则见 LCGameLibraryInfo.libraryOrder）定序一次，
    // 浏览期间不重排（新导入的游戏追加在末尾、已卸载的剔除，相对
    // 次序冻结；状态点颜色是现算的、会变，位置不变）。竖屏下方的
    // 「最近游玩」区是分组第 0 组（玩过的游戏）的独立呈现，仍走
    // recentApps，不受本快照影响；聚焦与 hero 也不读顺序。
    // carouselOffset 是 >3 张时手势轮播的滚动量（点），静止时恒
    // 等于聚焦序号 × stride。
    @State private var libraryOrderKeys: [String] = []
    @State private var carouselOffset: CGFloat = 0
    @State private var carouselDragStartOffset: CGFloat = 0
    @State private var carouselGestureStart = 0
    @State private var carouselDragging = false
    @State private var carouselSettled = true
    @State private var carouselScrollEpoch = 0
    // 横屏牌组点击裁决（Phase 16）：手势开始时的聚焦位快照、本次点按的
    // 消费标记、以及「当前触摸序列是否已写过快照」——见 deckTap 注释。
    // shelf 没有 carousel 的 settled 机制，用最近一次牌组切换的时刻判
    // 停稳（deckLastSwitchAt，由 setFocusFromDeck 记录）。
    @State private var deckTapStartFocus: Int? = nil
    @State private var deckTapConsumed = false
    @State private var deckTouchActive = false
    @State private var deckLastSwitchAt: Date = .distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: 聚焦与状态推导

    private func key(of app: LCAppModel) -> String {
        app.appInfo.relativeBundlePath as String
    }

    private var focusedApp: LCAppModel? {
        if let focusKey, let app = apps.first(where: { key(of: $0) == focusKey }) {
            return app
        }
        return defaultFocus
    }

    /// 默认聚焦：最近启动过的一款（lastLaunched 由 LCAppModel.runApp 真实写入），否则列表第一款
    private var defaultFocus: LCAppModel? {
        apps.max { a, b in
            (a.appInfo.lastLaunched ?? .distantPast) < (b.appInfo.lastLaunched ?? .distantPast)
        } ?? apps.first
    }

    private var focusIndex: Int {
        guard let focusedApp, let idx = apps.firstIndex(of: focusedApp) else {
            return 0
        }
        return idx
    }

    private func setFocus(_ app: LCAppModel) {
        withAnimation(.easeInOut(duration: 0.35)) {
            focusKey = key(of: app)
        }
    }

    private func stepFocus(_ delta: Int) {
        let target = focusIndex + delta
        guard apps.indices.contains(target) else {
            return
        }
        setFocus(apps[target])
    }

    private func ensureFocus() {
        if focusedApp == nil, let fallback = defaultFocus {
            focusKey = key(of: fallback)
        }
    }

    // MARK: 横屏轮播的顺序与聚焦（NX2 CoverFlow 移植辅助）

    /// 全主页共用的有序数据源（横屏牌组与竖屏「你的游戏」网格同读）：
    /// 顺序快照 ∩ 现有游戏，新游戏追加末尾；快照为空（首次出现前）时
    /// 退回入参次序。浏览期间相对次序不变，重排只发生在 onAppear
    /// 刷新快照时（快照的生成规则见 LCGameLibraryInfo.libraryOrder）。
    private var orderedApps: [LCAppModel] {
        let byKey = Dictionary(uniqueKeysWithValues: apps.map { (key(of: $0), $0) })
        var result = libraryOrderKeys.compactMap { byKey[$0] }
        let known = Set(libraryOrderKeys)
        result += apps.filter { !known.contains(key(of: $0)) }
        return result.isEmpty ? apps : result
    }

    /// 横屏牌组数据源 = 全主页有序口径（旧名保留，横屏内部读法不变）
    private var landscapeApps: [LCAppModel] {
        orderedApps
    }

    private func landscapeFocusIndex(in list: [LCAppModel]) -> Int {
        guard let focusedApp, let idx = list.firstIndex(of: focusedApp) else {
            return 0
        }
        return idx
    }

    /// NX 的切换动画是 .smooth(duration: 0.3)，部署目标 15 没有该曲线，
    /// 用等价时长的 timingCurve 近似；减弱动态时按 NX 同口径降为 0.2 线性。
    private var deckAnimation: Animation {
        reduceMotion ? .linear(duration: 0.2) : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.3)
    }

    private func setFocusFromDeck(_ app: LCAppModel) {
        deckLastSwitchAt = Date()
        withAnimation(deckAnimation) {
            focusKey = key(of: app)
        }
    }

    /// NX CardSnap 的落点规则（一手势最多一张）：target 是手势放开后按
    /// 惯性会停的偏移，velocity 是朝后一张卡方向的速度（pt/ms），
    /// 超过 0.3 算甩动，落点钳在手势起始卡的相邻一张内；否则落最近卡。
    private static func cardSnap(target: CGFloat, velocity: CGFloat, stride: CGFloat, count: Int, start: Int) -> Int {
        let nearest = Int((target / stride).rounded())
        let card: Int
        if velocity > 0.3 {
            card = max(start + 1, min(nearest, start + 1))
        } else if velocity < -0.3 {
            card = min(start - 1, max(nearest, start - 1))
        } else {
            card = nearest
        }
        return min(count - 1, max(0, card))
    }

    /// 游戏状态求值（主页全部状态呈现的单一入口）：读 refreshToken
    /// 把依赖写明，令牌变化时状态随 body 按磁盘重算。求值走
    /// LCGameLibraryInfo.gameState：先按记录对齐容器快照再查
    /// romfs.img——手动经「文件」App 放的包没有任何 App 内事件来
    /// 对齐快照，直查快照会停在错误容器上长期报缺失（玩家实证）。
    /// 三态与旧二态（LCGameLibraryInfo.datapackReady，导入链复核
    /// 仍在用）的差异只在损坏态：二态把异常文件也算「在」，三态
    /// 把异常单列已损坏。
    private func gameState(_ app: LCAppModel) -> LCGameState {
        _ = refreshToken
        return LCGameLibraryInfo.gameState(for: app)
    }

    /// 横屏信息区状态文案色：可玩 / 缺包沿用旧浅色值（比状态点色浅，
    /// 是横屏信息区原有的排法），损坏用 brokenRed
    private func stateTextColor(_ state: LCGameState) -> Color {
        switch state {
        case .playable: return Color(red: 196 / 255, green: 232 / 255, blue: 204 / 255)
        case .needsDatapack: return Color(red: 1.0, green: 196 / 255, blue: 110 / 255)
        case .broken: return LCGameTheme.brokenRed
        }
    }

    /// 横屏非聚焦卡左下状态胶囊的底色：缺包沿用旧暗琥珀，损坏用暗红
    private func capsuleBackground(_ state: LCGameState) -> Color {
        switch state {
        case .needsDatapack: return Color(red: 24 / 255, green: 18 / 255, blue: 8 / 255).opacity(0.85)
        case .broken: return Color(red: 30 / 255, green: 12 / 255, blue: 10 / 255).opacity(0.85)
        case .playable: return Color.clear
        }
    }

    /// 「最近游玩」排序：lastLaunched 倒序，从未启动过的排后面
    private var recentApps: [LCAppModel] {
        apps.sorted { a, b in
            let da = a.appInfo.lastLaunched ?? .distantPast
            let db = b.appInfo.lastLaunched ?? .distantPast
            if da != db {
                return da > db
            }
            return a.displayName < b.displayName
        }
    }

    /// 游玩时间文案只来自真实的 lastLaunched，没有记录就不显示
    private func playedText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天玩过"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天玩过"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days > 1 && days <= 7 {
            return "\(days) 天前玩过"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return "\(formatter.string(from: date))玩过"
    }

    private func metaText(for app: LCAppModel) -> String {
        var text = "版本 \(app.version)"
        if let lastLaunched = app.appInfo.lastLaunched {
            text += " · \(playedText(for: lastLaunched))"
        }
        return text
    }

    // MARK: 主体

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                LCGameTheme.pageBackground
                    .ignoresSafeArea()
                if apps.isEmpty {
                    emptyState(size: size, safeTop: safeAreaInsets.top, safeBottom: safeAreaInsets.bottom)
                } else if size.width > size.height {
                    landscape(size: size, safe: safeAreaInsets)
                } else {
                    portrait(size: size, safe: safeAreaInsets)
                }
                if installProgressVisible {
                    installPill(safeTop: safeAreaInsets.top)
                }
                // 手柄页自适应宿主（Phase 22）：横屏 = 右侧抽屉面板
                // （主页留在下层被压暗）、竖屏 = 整屏，形态随旋转跟随，
                // 语义与容器设置 / 游戏设置同轨
                // 顶部（Phase 26）：手柄页无 NavigationView，整屏形态的
                // 内容下移由页面自己在背景内侧垫（见 LCControllersView），
                // 宿主不外垫、不裁圆角
                LCSidePanelContainer(isPresented: controllerPanelPresented, onClose: { controllerPanelPresented = false }) {
                    LCControllersView(monitor: controllerMonitor, onClose: { controllerPanelPresented = false })
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        // 状态帮助页：竖屏 hero / 横屏信息区的状态行点开（非可玩态），
        // 内容与导入动作见 LCGameStateHelpSheet；导入走主页既有回调
        .sheet(item: $stateHelpTarget) { target in
            LCGameStateHelpSheet(app: target.app, state: target.state, onImportDatapack: {
                onImportDatapack(target.app)
            })
        }
        .onAppear {
            // 页面出现先把全部游戏的容器快照按记录对齐：主页的状态点
            // 求值虽走共用入口（内含对齐），这里先行一步让封面 / 时长等
            // 其余读快照的面与状态点同口径
            for app in apps {
                app.refreshContainerSelection()
            }
            ensureFocus()
            libraryOrderKeys = LCGameLibraryInfo.libraryOrder(of: apps).map { key(of: $0) }
            // 游玩时长补结（Phase 18）：主页出现 = 此刻没有客体在本进程跑，
            // 统计文件里还挂着的 openSession 必是闪退/被划掉没结清的局，
            // 按心跳补结后再读快照（回库路径已由客体侧结清，这里是空转）。
            LCPlayStats.reconcileOpenSession()
            playStats = LCPlayStats.allEntries()
            sweepCoverFetches()
        }
        .onChange(of: refreshToken) { _ in
            playStats = LCPlayStats.allEntries()
            sweepCoverFetches()
        }
        .onChange(of: apps.map { key(of: $0) }) { _ in
            ensureFocus()
        }
    }

    /// 联网封面懒抓（Phase 19）：主页出现 / 库刷新时逐个过一遍去重入口——
    /// 已有更高优先封面、已有抓取缓存、负缓存新鲜的游戏都在入口内直接
    /// 返回，不发请求；抓取成功后服务回调 bump libraryRefresh，封面随
    /// 令牌变化重解析（本 onChange 会再扫一遍，但那时缓存已落盘、空转）。
    private func sweepCoverFetches() {
        for app in apps {
            LCCoverFetchService.shared.ensureFetched(appInfo: app.appInfo)
        }
    }

    /// 水平边距对齐 NX2 壳真机截图实测：竖屏 ≈ 屏宽 5.9%（393pt 宽 ≈ 23pt），
    /// 横屏顶排左距 ≈ 屏宽 10.2%。旧值 9.3% 是竖屏留白过多的来源。
    private func margin(for size: CGSize) -> CGFloat {
        if size.width > size.height {
            return min(max(size.width * 0.102, 24), 120)
        }
        return min(max(size.width * 0.059, 18), 40)
    }

    // MARK: 通用小件

    private func statusDot(color: Color, radius: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: (radius + 2.5) * 2, height: (radius + 2.5) * 2)
            Circle()
                .fill(color)
                .frame(width: radius * 2, height: radius * 2)
        }
    }

    private func circleChrome(diameter: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            Circle()
                .fill(LCGameTheme.chipBackground)
            Circle()
                .strokeBorder(LCGameTheme.chipBorder, lineWidth: 1)
            content()
        }
        .frame(width: diameter, height: diameter)
    }

    private func chromeButton(diameter: CGFloat, systemImage: String, fontSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleChrome(diameter: diameter) {
                Image(systemName: systemImage)
                    .font(.system(size: fontSize))
                    .foregroundColor(LCGameTheme.chipIcon)
            }
        }
        .buttonStyle(.plain)
    }

    /// 手柄胶囊（对齐 NX 壳语义）：数字 = 当前已连接手柄数（GameController 实时
    /// 监听连接/断开刷新），点击打开手柄页（LCControllersView，复刻 NX 壳
    /// ControllersView 的结构与视觉）：自适应宿主呈现——横屏右侧抽屉
    /// 面板、竖屏整屏，旋转跟随（Phase 22）。尺寸与位置沿用原常量，只接行为。
    private func gamepadCapsule(height: CGFloat) -> some View {
        Button {
            controllerPanelPresented = true
        } label: {
            ZStack {
                Capsule()
                    .fill(LCGameTheme.chipBackground)
                Capsule()
                    .strokeBorder(LCGameTheme.chipBorder, lineWidth: 1)
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: height * 0.42))
                    Text("\(controllerMonitor.controllers.count)")
                        .font(.system(size: height * 0.4, weight: .bold))
                }
                .foregroundColor(LCGameTheme.chipIcon)
                .padding(.horizontal, height * 0.32)
            }
            .frame(height: height)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    /// ＋导入菜单：导入 IPA / 导入数据包（现有两条导入实现），外加隐藏游戏恢复入口
    private func importMenu(diameter: CGFloat) -> some View {
        Menu {
            Button {
                onImportIPA()
            } label: {
                Label("导入 IPA", systemImage: "doc.badge.plus")
            }
            Button {
                onImportDatapackGeneric()
            } label: {
                Label("导入数据包", systemImage: "square.and.arrow.down")
            }
            if hiddenAppsCount > 0 {
                Divider()
                Button {
                    onOpenHiddenApps()
                } label: {
                    Label("隐藏的游戏（\(hiddenAppsCount)）", systemImage: "eye.slash")
                }
            }
        } label: {
            circleChrome(diameter: diameter) {
                Image(systemName: "plus")
                    .font(.system(size: diameter * 0.4, weight: .semibold))
                    .foregroundColor(LCGameTheme.chipIcon)
            }
        }
    }

    /// 右上按钮排：横屏 ＋/滑杆/手柄/齿轮；竖屏封面排 ＋/手柄/齿轮（滑杆在底部开始键旁）
    private func chromeRow(diameter: CGFloat, includeSliders: Bool) -> some View {
        HStack(spacing: 12) {
            if multiLCStatus != 2 {
                importMenu(diameter: diameter)
            }
            if includeSliders {
                chromeButton(diameter: diameter, systemImage: "slider.horizontal.3", fontSize: diameter * 0.44) {
                    if let focusedApp {
                        onSettings(focusedApp)
                    }
                }
            }
            gamepadCapsule(height: diameter)
            chromeButton(diameter: diameter, systemImage: "gearshape", fontSize: diameter * 0.46) {
                onOpenContainerSettings()
            }
        }
    }

    /// 长按动作：与旧卡片 contextMenu 逐项同语义
    @ViewBuilder
    private func gameContextMenu(for app: LCAppModel) -> some View {
        if !app.uiIsShared, app.uiSelectedContainer != nil {
            Button {
                onOpenDataFolder(app)
            } label: {
                Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
            }
        }
        Button {
            onSettings(app)
        } label: {
            Label("游戏设置", systemImage: "gear")
        }
        if !app.uiIsShared {
            Button {
                onImportDatapack(app)
            } label: {
                Label("导入数据包", systemImage: "square.and.arrow.down")
            }
        }
        if !app.uiIsShared {
            Button(role: .destructive) {
                onUninstall(app)
            } label: {
                Label("lc.appBanner.uninstall".loc, systemImage: "trash")
            }
        }
    }

    private func installPill(safeTop: CGFloat) -> some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("正在安装 \(Int(installProgress * 100))%")
                    .font(.footnote.bold())
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(LCGameTheme.chipBorder, lineWidth: 1))
            .padding(.top, safeTop + 8)
            Spacer()
        }
    }

    // MARK: 空库

    private func emptyState(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        ZStack {
            VStack {
                HStack {
                    Spacer()
                    chromeRow(diameter: 40, includeSliders: false)
                }
                Spacer()
            }
            .padding(.top, safeTop + 6)
            .padding(.horizontal, margin(for: size))

            VStack(spacing: 18) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 54))
                    .foregroundColor(.gray)
                Text("还没有导入游戏")
                    .font(.system(.title3, design: .rounded).bold())
                    .foregroundColor(LCGameTheme.creamColor)
                if multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 12) {
                        Button {
                            onImportIPA()
                        } label: {
                            Text("＋ 导入 IPA")
                                .font(.headline)
                                .foregroundColor(.black)
                                .frame(width: 240, height: 50)
                                .background(LCGameTheme.nxCream)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            onImportDatapackGeneric()
                        } label: {
                            Text("＋ 导入数据包")
                                .font(.headline)
                                .foregroundColor(LCGameTheme.chipIcon)
                                .frame(width: 240, height: 50)
                                .overlay(Capsule().strokeBorder(LCGameTheme.chipBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        if hiddenAppsCount > 0 {
                            Button {
                                onOpenHiddenApps()
                            } label: {
                                Text("隐藏的游戏（\(hiddenAppsCount)）")
                                    .font(.footnote)
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, margin(for: size))
        }
    }

    // MARK: 竖屏

    private func portrait(size: CGSize, safe: EdgeInsets) -> some View {
        let w = size.width
        let m = margin(for: size)
        let heroH = max(size.height * 0.39, 280)
        return ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    portraitHero(width: w, height: heroH, safeTop: safe.top, margin: m)
                    portraitGames(margin: m, width: w)
                    portraitRecent(margin: m, width: w)
                    if multiLCStatus == 2 {
                        Text("lc.appList.manageInPrimaryTip".loc)
                            .font(.footnote)
                            .foregroundColor(.gray)
                            .padding(.horizontal, m)
                            .padding(.top, 20)
                    }
                    // 给底部浮动开始栏让位
                    Color.clear.frame(height: 118)
                }
            }
            .ignoresSafeArea(edges: .top)
            portraitBottomBar(margin: m, safeBottom: safe.bottom)
        }
    }

    private func portraitHero(width: CGFloat, height: CGFloat, safeTop: CGFloat, margin m: CGFloat) -> some View {
        ZStack {
            if let app = focusedApp {
                LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
                    .frame(width: width, height: height)
                    .clipped()
            }
            // 底部渐隐到黑、顶部压暗保状态栏可读（照预览 vgrad 取值）
            VStack {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(0.43), location: 0),
                        .init(color: Color.black.opacity(0), location: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height * 0.12)
                Spacer()
            }
            VStack {
                Spacer()
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(0), location: 0),
                        .init(color: LCGameTheme.pageBackground, location: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height * 0.48)
            }
            // 右上浮钮排
            VStack {
                HStack {
                    Spacer()
                    chromeRow(diameter: 40, includeSliders: false)
                }
                // 浮钮排落在真实安全区之下（safeTop 由列表层注入，不再是被
                // .ignoresSafeArea() 归零的值），+6 后约在屏高 7% 处，不碰灵动岛
                .padding(.top, safeTop + 6)
                .padding(.trailing, m)
                Spacer()
            }
            // 左下状态 + 标题 + 版本
            VStack {
                Spacer()
                if let app = focusedApp {
                    VStack(alignment: .leading, spacing: 8) {
                        // 状态行三态呈现（照 NX GameStateView 口径）：非
                        // 可玩时整行可点，打开状态帮助页（怎么修 + 动作）
                        Button {
                            let state = gameState(app)
                            if !state.isPlayable {
                                stateHelpTarget = LCGameStateTarget(app: app, state: state)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                statusDot(color: gameState(app).themeColor, radius: 5)
                                Text(gameState(app).title)
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(gameState(app).themeColor)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(app.displayName)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(metaText(for: app))
                            .font(.system(size: 13.5))
                            .foregroundColor(LCGameTheme.mutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, m)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func portraitGames(margin m: CGFloat, width: CGFloat) -> some View {
        let spacing: CGFloat = 15
        let columnWidth = (width - m * 2 - spacing) / 2
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("你的游戏")
                    .font(.system(size: 14))
                    .foregroundColor(LCGameTheme.sectionText)
                Spacer()
                Text("\(apps.count)")
                    .font(.system(size: 14))
                    .foregroundColor(LCGameTheme.mutedText)
            }
            .padding(.horizontal, m)
            .padding(.top, 20)
            .padding(.bottom, 14)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)], spacing: 18) {
                ForEach(orderedApps, id: \.self) { app in
                    VStack(alignment: .leading, spacing: 8) {
                        LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
                            .frame(width: columnWidth, height: columnWidth * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                statusDot(color: gameState(app).themeColor, radius: 5)
                                    .padding(10)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                setFocus(app)
                            }
                            .contextMenu {
                                gameContextMenu(for: app)
                            }
                        Text(app.displayName)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        // 聚焦项名下米色线（照预览）
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(focusedApp == app ? LCGameTheme.nxCream : Color.clear)
                            .frame(width: columnWidth, height: 3)
                    }
                }
            }
            .padding(.horizontal, m)
        }
    }

    private func portraitRecent(margin m: CGFloat, width: CGFloat) -> some View {
        let rows = Array(recentApps.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            Text("最近游玩")
                .font(.system(size: 14))
                .foregroundColor(LCGameTheme.sectionText)
                .padding(.horizontal, m)
                .padding(.top, 26)
                .padding(.bottom, 6)

            ForEach(rows.indices, id: \.self) { idx in
                let app = rows[idx]
                HStack(spacing: 12) {
                    LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
                        .frame(width: 73, height: 41)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.displayName)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        recentSubtitle(for: app)
                        // 游玩时长行（Phase 18，用户指定只上「最近游玩」）：
                        // 有累计记录才出，文案如「累计 2 小时 5 分钟 · 上次 32 分钟」
                        if let statsText = LCPlayStats.summaryText(for: playStats[app.bundleIdentifier]) {
                            Text(statsText)
                                .font(.system(size: 12.5))
                                .foregroundColor(LCGameTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        onRun(app)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15))
                            .foregroundColor(Color(red: 168 / 255, green: 168 / 255, blue: 172 / 255))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    setFocus(app)
                }
                .contextMenu {
                    gameContextMenu(for: app)
                }
                .padding(.horizontal, m)
                .padding(.vertical, 10)

                if idx < rows.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 0.5)
                        .padding(.leading, m + 73 + 12)
                        .padding(.trailing, m)
                }
            }
        }
    }

    @ViewBuilder
    private func recentSubtitle(for app: LCAppModel) -> some View {
        if !gameState(app).isPlayable {
            HStack(spacing: 6) {
                statusDot(color: gameState(app).themeColor, radius: 3.5)
                Text(gameState(app).title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(gameState(app).themeColor)
            }
        } else if let lastLaunched = app.appInfo.lastLaunched {
            Text(playedText(for: lastLaunched))
                .font(.system(size: 13))
                .foregroundColor(LCGameTheme.mutedText)
        } else {
            Text("版本 \(app.version)")
                .font(.system(size: 13))
                .foregroundColor(LCGameTheme.mutedText)
        }
    }

    private func portraitBottomBar(margin m: CGFloat, safeBottom: CGFloat) -> some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: LCGameTheme.pageBackground.opacity(0), location: 0),
                        .init(color: LCGameTheme.pageBackground.opacity(0.92), location: 0.45),
                        .init(color: LCGameTheme.pageBackground, location: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 108)
                HStack(spacing: 14) {
                    Button {
                        if let focusedApp {
                            onRun(focusedApp)
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if let focusedApp, focusedApp.isSigningInProgress {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17))
                                Text("开始")
                                    .font(.system(size: 19, weight: .bold))
                            }
                        }
                        .foregroundColor(Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255))
                        .frame(height: 56)
                        .frame(maxWidth: .infinity)
                        .background(LCGameTheme.nxCream)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(focusedApp == nil || (focusedApp?.isAppRunning ?? false))

                    chromeButton(diameter: 56, systemImage: "slider.horizontal.3", fontSize: 24) {
                        if let focusedApp {
                            onSettings(focusedApp)
                        }
                    }
                }
                // NX 竖屏实测：开始胶囊下缘距屏底 ≈ 42pt ≈ 安全区 34 + 8
                .padding(.horizontal, m)
                .padding(.bottom, safeBottom + 8)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: 横屏（NX2 CoverFlow 移植：几何与吸附规则照 DmShell CoverFlowView）

    /// 横屏度量：与 NX CoverFlowView 同一度量参考系——全部量在安全区
    /// geometry 内原样计算（safeSize + safeAreaInsets，正是 NX
    /// LibraryView 传给 CoverFlowView 的 geometry.size + screenInsets），
    /// 不再用全屏尺寸做「等值换算」：旧换算的两处宽度封顶（0.54 cap 与
    /// shelf cap）误用全屏宽，卡区锚点也脱离了 NX 的 middle 定义，
    /// 安全区左右留边越大的机型偏得越多（Phase 13）。
    /// 卡高由上下两头反推（下：卡底要给信息区让位；上：卡顶不进顶栏
    /// 区），再被安全区宽 54% 的 16:9 封顶，最后 /1.06 给倾斜留头寸。
    /// short = 安全区高 < 520（手机横屏）。
    private struct LCLandscapeMetrics {
        let short: Bool
        let cover: CGFloat
        let stride: CGFloat
        let cardAreaHeight: CGFloat
        let cardAreaTop: CGFloat
        let gap: CGFloat
        let titleSize: CGFloat
        /// 安全区宽：shelf 的卡宽封顶按它算（NX shelf 的 width 入参）
        let contentWidth: CGFloat

        init(safeSize: CGSize, safe: EdgeInsets) {
            let width = safeSize.width
            let height = safeSize.height
            short = height < 520
            titleSize = short ? 18 : 28
            let words = titleSize * 1.3 * 2 + 8 + 34
            gap = short ? 10 : 24
            let below: CGFloat = short ? 4 : 56
            let barTop: CGFloat = short ? 12 : 16
            // 整屏中点在安全区坐标系里的位置（NX middle 定义原式）
            let middle = (height + safe.top + safe.bottom) / 2 - safe.top
            let byBottom = 2 * (height - middle - gap - words - below)
            let byTop = 2 * (middle - barTop - 44 - (short ? 6 : 16))
            let cardHeight = max(90, min(byBottom, byTop, width * 0.54 * 9 / 16) / 1.06)
            cover = cardHeight * 16 / 9
            stride = cover + cover * 0.04
            cardAreaHeight = cardHeight * 1.06
            // 卡区顶换算回本视图（全屏出血）坐标：安全区原点 + middle
            cardAreaTop = safe.top + middle - cardAreaHeight / 2
            contentWidth = width
        }
    }

    private func landscape(size: CGSize, safe: EdgeInsets) -> some View {
        let w = size.width
        let metrics = LCLandscapeMetrics(safeSize: safeSize, safe: safe)
        let list = landscapeApps
        let focusIdx = landscapeFocusIndex(in: list)
        return ZStack(alignment: .top) {
            landscapeBackdrop(size: size)

            // 卡区 + 信息区：卡区顶按整屏中点定位，信息区跟在卡区下方 gap 处
            VStack(spacing: 0) {
                Group {
                    if list.count <= 3 {
                        landscapeShelf(list: list, metrics: metrics, width: metrics.contentWidth)
                    } else {
                        landscapeCarousel(list: list, metrics: metrics, size: size)
                    }
                }
                .frame(height: metrics.cardAreaHeight)

                if let app = focusedApp {
                    landscapeInfo(app: app, metrics: metrics, width: w)
                        .padding(.top, metrics.gap)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.top, metrics.cardAreaTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // 顶部行：左位置字、右按钮排（LC 现行，位置口径不动）
            VStack {
                HStack(alignment: .center) {
                    HStack(spacing: 12) {
                        Text("你的游戏")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 206 / 255, green: 200 / 255, blue: 194 / 255))
                        Text("第 \(focusIdx + 1) 个，共 \(list.count)")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 172 / 255, green: 164 / 255, blue: 158 / 255))
                    }
                    Spacer()
                    chromeRow(diameter: 41, includeSliders: true)
                }
                // 顶排对齐 NX 横屏：钮面约在屏高 4% 处起（图标中心 ≈ 7%）
                .padding(.top, safe.top + size.height * 0.04)
                .padding(.horizontal, margin(for: size))
                Spacer()
            }
        }
    }

    /// 背景：聚焦游戏封面的色调晕染（NX CoverFlowBackdrop 常量）：原图
    /// 放大 1.3、模糊 60、饱和 1.25、不透明 0.75，切换时 0.45 交叉淡化；
    /// 上面再压径向（中心 0.5/0.4、80→900）与纵向两道渐变收边。
    private func landscapeBackdrop(size: CGSize) -> some View {
        ZStack {
            LCGameTheme.pageBackground
            if let app = focusedApp {
                LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .scaleEffect(1.3)
                    .blur(radius: 60)
                    .saturation(1.25)
                    .opacity(0.75)
                    .id(key(of: app))
                    .transition(.opacity)
            }
            RadialGradient(
                colors: [.clear, LCGameTheme.pageBackground.opacity(0.75)],
                center: UnitPoint(x: 0.5, y: 0.4),
                startRadius: 80,
                endRadius: 900
            )
            LinearGradient(
                colors: [.black.opacity(0.25), .clear, LCGameTheme.pageBackground.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? .linear(duration: 0.2) : .easeInOut(duration: 0.45), value: focusKey)
    }

    /// 聚焦卡下方信息区（NX 布局、LC 语义）：游戏名（字号随 short 取
    /// 18/28、两行预留、切换只交叉淡化不跳高），其下 34pt 定高行放 LC
    /// 自己的数据包状态；开始入口仍是点聚焦卡本身，不搬 NX 的状态文案。
    private func landscapeInfo(app: LCAppModel, metrics: LCLandscapeMetrics, width w: CGFloat) -> some View {
        let state = gameState(app)
        return ZStack(alignment: .top) {
            // 隐藏占位先量好两行标题 + 34 状态行，切换时只有文字淡换
            VStack(spacing: 8) {
                Text("M\nM")
                    .font(.system(size: metrics.titleSize, weight: .bold))
                Color.clear.frame(height: 34)
            }
            .hidden()
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(app.displayName)
                    .font(.system(size: metrics.titleSize, weight: .bold))
                    .tracking(-metrics.titleSize * 0.04)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.35), radius: 10)
                // 状态行三态呈现：文案/色随状态（可玩与缺包沿用旧
                // 文案与浅色值，损坏新增红色「已损坏」）；非可玩时
                // 可点开状态帮助页，与竖屏 hero 同一入口
                Button {
                    if !state.isPlayable {
                        stateHelpTarget = LCGameStateTarget(app: app, state: state)
                    }
                } label: {
                    HStack(spacing: 7) {
                        statusDot(color: state.themeColor, radius: 4)
                        Text(state.isPlayable ? "随时可玩 · 数据包已就绪" : state.title)
                            .font(.system(size: 12))
                            .foregroundColor(stateTextColor(state))
                    }
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .id(key(of: app))
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: focusKey)
        .frame(maxWidth: min(560, w - 48))
        .frame(maxWidth: .infinity)
    }

    /// 一张 16:9 卡（NX CoverView 常量）：圆角 = 卡宽 3%、白色 0.10 描边、
    /// 阴影黑 0.5 / 半径卡宽 5% / y 卡宽 3%；左上状态点直径钳在
    /// 8…14（卡宽 3.4%）、内距 = 点径 0.9。非聚焦卡缺数据包时左下加
    /// LC 自己的琥珀胶囊（LC 语义，NX 无此件）。
    /// transformScale：调用方此前靠外层 scaleEffect 呈现的缩放比（shelf
    /// 邻卡 0.8、聚焦与 carousel 恒 1）。按 cardW 成比例的部件（圆角 /
    /// 阴影）折进渲染尺寸后自动等值，但状态点（带钳制）与琥珀胶囊
    /// （固定字号 / 内距）不成比例，须按缩放比还原旧的有效尺寸；
    /// 默认 1 时与旧口径逐点一致。
    private func landscapeCard(app: LCAppModel, cardW: CGFloat, isFocused: Bool, transformScale: CGFloat = 1) -> some View {
        let state = gameState(app)
        let dot = max(8, min(14, (cardW / transformScale) * 0.034)) * transformScale
        return LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
            .frame(width: cardW, height: cardW * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: cardW * 0.03, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardW * 0.03, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                statusDot(color: state.themeColor, radius: dot / 2)
                    .padding(dot * 0.9)
            }
            .overlay(alignment: .bottomLeading) {
                if !isFocused && !state.isPlayable {
                    HStack(spacing: 6 * transformScale) {
                        Circle()
                            .fill(state.themeColor)
                            .frame(width: 8 * transformScale, height: 8 * transformScale)
                        Text(state.title)
                            .font(.system(size: 10.5 * transformScale, weight: .bold))
                            .foregroundColor(state.themeColor)
                    }
                    .padding(.horizontal, 10 * transformScale)
                    .padding(.vertical, 5 * transformScale)
                    .background(Capsule().fill(capsuleBackground(state)))
                    .padding(10 * transformScale)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: cardW * 0.05, y: cardW * 0.03)
    }

    /// 1…3 张（NX shelf）：一字排开居中，聚焦卡原大、邻卡 0.8 缩放压暗
    /// （brightness -0.22），每张按 (序号 - 中位) × 卡宽 0.78 错位叠放；
    /// 横滑一格切一张（NX 手势门槛：最小距离 24、|dx| > 44 且 > |dy|×1.5），
    /// 两端停住不绕圈。单张时无邻卡、无错位，就是居中一张。
    /// 定位走布局空间（Phase 15）：旧实现所有卡共用同一块居中布局帧、
    /// 只靠 offset / scaleEffect 摆出渲染位置，命中区留在布局帧上——
    /// 聚焦卡（zIndex 10 先命中）的命中矩形比它渲染出的右缘多探约
    /// 0.39×卡宽，罩住邻卡可见区的内侧一大半，点邻卡会误启动聚焦款；
    /// contextMenu 又挂在已变换的视图上，长按预览按布局帧取快照、
    /// 内容被变换推偏裁切。现在缩放直接折进卡的渲染尺寸、落位用
    /// position（布局锚点），每张卡的布局帧即渲染帧：命中形状与
    /// 渲染形状一致、重叠区按 zIndex 归上层（聚焦卡）；菜单挂的就
    /// 是这张未变换的卡，系统长按预览按其真实帧取快照、封面完整
    /// （带 preview 的 contextMenu 写法要 iOS 16、部署目标 15 用不了，
    /// 本法是其等价替代）。几何常量（卡宽封顶、0.78 步距、0.8 缩放、
    /// -0.22 压暗、zIndex 规则）一律未动。
    private func landscapeShelf(list: [LCAppModel], metrics: LCLandscapeMetrics, width w: CGFloat) -> some View {
        let card = min(metrics.cover, w / (1 + CGFloat(list.count - 1) * 0.8))
        let chosen = landscapeFocusIndex(in: list)
        return GeometryReader { geo in
            ZStack {
                ForEach(list.indices, id: \.self) { idx in
                    let app = list[idx]
                    let isChosen = idx == chosen
                    let scale: CGFloat = isChosen ? 1 : 0.8
                    let renderedW = card * scale
                    landscapeCard(app: app, cardW: renderedW, isFocused: isChosen, transformScale: scale)
                        .brightness(isChosen ? 0 : -0.22)
                        .contentShape(RoundedRectangle(cornerRadius: renderedW * 0.03, style: .continuous))
                        .onTapGesture {
                            deckTap(app: app, index: idx, list: list, isSettled: deckSettled) {
                                setFocusFromDeck(app)
                            }
                        }
                        .contextMenu {
                            gameContextMenu(for: app)
                        }
                        .position(
                            x: geo.size.width / 2 + (CGFloat(idx) - CGFloat(list.count - 1) / 2) * card * 0.78,
                            y: geo.size.height / 2
                        )
                        .zIndex(isChosen ? 10 : -Double(abs(idx - chosen)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(deckTouchWatcher(list: list))
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard list.count > 1, abs(dx) > 44, abs(dx) > abs(dy) * 1.5 else {
                            return
                        }
                        let target = min(list.count - 1, max(0, chosen + (dx < 0 ? 1 : -1)))
                        if target != chosen {
                            setFocusFromDeck(list[target])
                        }
                    }
            )
        }
    }

    /// 4 张起（NX carousel 的手势移植）：部署目标 15 用不了 NX 的
    /// ScrollView 吸附 API，改手势驱动同一套几何——place = 序号 - 偏移 /
    /// stride，每卡按 FlowTilt 变形：近处（|place| 钳 ±1）绕 Y 轴回转
    /// 最多 24°（透视 0.35）、缩放 1 - |near|×0.22、内收 near×卡宽 0.28、
    /// 压暗 |near|×0.25；远处再多退 far×卡宽 0.55、压暗至多 0.1；
    /// zIndex = -|place|，近卡恒在上。只构造 |place| ≤ 2 的卡（聚焦 ±2），
    /// 更远的卡不建视图、不触发封面解析，长列表不预载全部封面。
    private func landscapeCarousel(list: [LCAppModel], metrics: LCLandscapeMetrics, size: CGSize) -> some View {
        let w = size.width
        let cover = metrics.cover
        let stride = metrics.stride
        let areaH = metrics.cardAreaHeight
        let focusIdx = landscapeFocusIndex(in: list)
        return ZStack {
            ForEach(list.indices, id: \.self) { idx in
                let place = CGFloat(idx) - carouselOffset / stride
                if abs(place) <= 2 {
                    let app = list[idx]
                    let near = max(-1, min(1, place))
                    let far = place > 1 ? place - 1 : place < -1 ? place + 1 : 0
                    landscapeCard(app: app, cardW: cover, isFocused: idx == focusIdx)
                        // Phase 15 审计：命中走 position 布局落位（见
                        // landscapeShelf 注释），无 shelf 的误启动病；
                        // 菜单原挂在旋转 / 缩放之后的视图上、与 shelf
                        // 的预览病同源，改挂到未变换的卡本体上——
                        // 系统快照源即卡本身，变换全部留在菜单之外。
                        .contextMenu {
                            gameContextMenu(for: app)
                        }
                        .rotation3DEffect(
                            .degrees(reduceMotion ? 0 : -near * 24),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.35
                        )
                        .scaleEffect(1 - abs(near) * 0.22)
                        .brightness(-abs(near) * 0.25 - min(abs(far), 1) * 0.1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            carouselTap(app: app, index: idx, list: list, stride: stride)
                        }
                        .position(
                            x: w / 2 + place * stride - near * cover * 0.28 - far * cover * 0.55,
                            y: areaH / 2
                        )
                        .zIndex(-Double(abs(place)))
                }
            }
        }
        .frame(width: w, height: areaH)
        .contentShape(Rectangle())
        .gesture(carouselDrag(list: list, stride: stride))
        .simultaneousGesture(deckTouchWatcher(list: list))
        .onAppear {
            carouselOffset = CGFloat(focusIdx) * stride
        }
        .onChange(of: focusKey) { _ in
            syncCarouselOffset(list: list, stride: stride)
        }
        .onChange(of: w) { _ in
            carouselOffset = CGFloat(landscapeFocusIndex(in: list)) * stride
        }
    }

    /// 触摸观察手势（Phase 16）：与牌组自身的滑动 / 点击同时识别，
    /// 只在每次触摸序列落下时写一次「手势开始时的聚焦位」快照并复位
    /// 消费标记。裁决只认这张快照，不认裁决时（可能已被切换动画或
    /// asyncAfter 改过的）当前聚焦。
    private func deckTouchWatcher(list: [LCAppModel]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !deckTouchActive else { return }
                deckTouchActive = true
                deckTapConsumed = false
                deckTapStartFocus = landscapeFocusIndex(in: list)
            }
            .onEnded { _ in
                deckTouchActive = false
            }
    }

    /// shelf 的停稳判定：距上次牌组切换 ≥ 切换动画时长（0.3）+ 余量，
    /// 与 carousel 的 0.32 口径对齐（reduceMotion 时动画 0.2，同一
    /// 阈值仍成立）。
    private var deckSettled: Bool {
        Date().timeIntervalSince(deckLastSwitchAt) >= 0.32
    }

    /// 横屏牌组点击的唯一裁决点（Phase 16，NX 三条逻辑的结构性强制）：
    /// 滑动切换走既有手势、不经此；点后面的封面只切换；只有点已经
    /// 停稳在前面的封面才启动。旧实现的两条漏路：① shelf 的
    /// onTapGesture 闭包捕获的是渲染时算好的 isChosen，裁决数据与
    /// 裁决时刻脱钩——切换动画途中视图再渲染，闭包会带着新聚焦位
    /// 重入，手指落下时还是后面的卡、识别完成时已被判成前面的卡；
    /// ② carousel 的 carouselTap 在裁决时现读聚焦位，邻卡路径又在
    /// 同一手势里当场改聚焦、settled 0.32s 后由 asyncAfter 翻回，
    /// 未停稳窗口里的后续识别能赶上新聚焦位 + settled 而误启动。
    /// 本裁决在触摸落下时冻结聚焦位（deckTouchWatcher 的快照），
    /// 点击结束时只裁决一次并消费：被点卡 ≠ 开始时聚焦卡 → 只执行
    /// focusAction（切换），同一次点按绝不二次裁决；被点卡 = 开始时
    /// 聚焦卡且已停稳 → 启动。快照缺失（观察手势未及写下）时退回
    /// 现读聚焦位，仅该一次点按回到旧口径。
    private func deckTap(app: LCAppModel, index idx: Int, list: [LCAppModel], isSettled: Bool, focusAction: () -> Void) {
        guard !deckTapConsumed else { return }
        deckTapConsumed = true
        let startFocus = deckTapStartFocus ?? landscapeFocusIndex(in: list)
        if idx != startFocus {
            focusAction()
        } else if isSettled {
            onRun(app)
        }
    }

    /// 点邻卡只居中、点已聚焦卡在轮播停稳时才启动——裁决统一走
    /// deckTap（手势开始时的聚焦位 + 一次消费），此处只提供 carousel
    /// 的切换动作（滚动到该卡 + 落聚焦 + settled 计时）。
    private func carouselTap(app: LCAppModel, index idx: Int, list: [LCAppModel], stride: CGFloat) {
        deckTap(app: app, index: idx, list: list, isSettled: carouselSettled && !carouselDragging) {
            beginCarouselScroll()
            withAnimation(deckAnimation) {
                carouselOffset = CGFloat(idx) * stride
            }
            setFocusFromDeck(app)
            finishCarouselScroll(epoch: carouselScrollEpoch)
        }
    }

    private func carouselDrag(list: [LCAppModel], stride: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !carouselDragging {
                    carouselDragging = true
                    carouselDragStartOffset = carouselOffset
                    carouselGestureStart = min(list.count - 1, max(0, Int((carouselOffset / stride).rounded())))
                    beginCarouselScroll()
                }
                carouselOffset = min(
                    CGFloat(list.count - 1) * stride,
                    max(0, carouselDragStartOffset - value.translation.width)
                )
            }
            .onEnded { value in
                carouselDragging = false
                // NX CardSnap 的入参：target = 惯性预测落点的偏移，
                // velocity 换成朝后一张卡为正的 pt/ms
                let target = carouselDragStartOffset - value.predictedEndTranslation.width
                let velocity = -value.velocity.width / 1000
                let card = Self.cardSnap(
                    target: target,
                    velocity: velocity,
                    stride: stride,
                    count: list.count,
                    start: carouselGestureStart
                )
                withAnimation(deckAnimation) {
                    carouselOffset = CGFloat(card) * stride
                }
                // Phase 23：落点一决定（手势结束 / 吸附开始这一帧）就
                // 提交聚焦——背景 0.45 淡化与名牌 0.2 淡化由此与吸附
                // 动画同时起跑。旧实现把提交压在吸附之后：asyncAfter
                // (+0.32) 才落聚焦，三层串行，卡停稳后名牌还要再等
                // 0.32 才开始换、背景 0.32+0.45 才换完（录屏实测背景 /
                // 标题慢约半秒跟上）。NX 的选择虽生于滚动 idle，但其
                // 滚动自带减速段、提交与停稳同帧，淡化在停稳帧起跑；
                // 本手势移植以「落点提交」为闸达成同一观感时序。拖拽
                // 进行中（onChanged）不提交——未决定落点的滑动不换
                // 背景 / 名牌，防闪烁原意不变。settled 不在此翻：仍由
                // finishCarouselScroll 在 +0.32 翻（与点邻卡 / 外部同步
                // 同一机制），Phase 16 的点击裁决口径不动。
                if list.indices.contains(card) {
                    setFocusFromDeck(list[card])
                }
                finishCarouselScroll(epoch: carouselScrollEpoch)
            }
    }

    /// 聚焦被外部改动（列表增删、竖屏切歌后转横屏）时把偏移跟上；
    /// 拖动中不干预（手势优先，与 NX 同义）。
    private func syncCarouselOffset(list: [LCAppModel], stride: CGFloat) {
        guard !carouselDragging else {
            return
        }
        let target = CGFloat(landscapeFocusIndex(in: list)) * stride
        guard abs(carouselOffset - target) > 0.5 else {
            return
        }
        beginCarouselScroll()
        withAnimation(deckAnimation) {
            carouselOffset = target
        }
        finishCarouselScroll(epoch: carouselScrollEpoch)
    }

    private func beginCarouselScroll() {
        carouselScrollEpoch += 1
        carouselSettled = false
    }

    private func finishCarouselScroll(epoch: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            if carouselScrollEpoch == epoch {
                carouselSettled = true
            }
        }
    }
}

// MARK: - 已连接手柄监听（手柄胶囊数据源）

/// 实时维护已连接手柄列表：初始读 GCController.controllers()，之后靠
/// 连接/断开通知刷新。启动一次无线发现，让已配对的无线手柄尽早枚举出来。
/// 主页手柄胶囊与手柄页（LCControllersView）共用同一实例。
final class LCControllerMonitor: ObservableObject {
    @Published var controllers: [GCController] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        GCController.startWirelessControllerDiscovery {}
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func refresh() {
        controllers = GCController.controllers()
    }
}

// MARK: - 隐藏游戏页（＋菜单进入，鉴权后由 LCAppListView 推进来）

struct LCHiddenAppsView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var sharedAppSortManager: LCAppSortManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    var onRun: (LCAppModel) -> Void
    var onSettings: (LCAppModel) -> Void
    var onOpenDataFolder: (LCAppModel) -> Void
    var onImportDatapack: (LCAppModel) -> Void
    var onUninstall: (LCAppModel) -> Void
    var onUnhide: (LCAppModel) -> Void

    private var apps: [LCAppModel] {
        sharedAppSortManager.sortedHiddenApps
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("这些游戏被隐藏，不出现在游戏库里。长按一行可启动、打开设置或卸载；点「取消隐藏」即恢复显示。")
                    .font(.footnote)
                    .foregroundColor(.gray)
                if apps.isEmpty {
                    Text("没有隐藏的游戏")
                        .foregroundColor(.gray)
                        .padding(.top, 24)
                }
                ForEach(apps, id: \.self) { app in
                    HStack(spacing: 12) {
                        iconView(for: app)
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text("版本 \(app.version)")
                                .font(.system(size: 12.5))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Button {
                            onUnhide(app)
                        } label: {
                            Text("取消隐藏")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(LCGameTheme.creamColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .overlay(Capsule().strokeBorder(LCGameTheme.chipBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(LCGameTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            onRun(app)
                        } label: {
                            Label("启动", systemImage: "play.fill")
                        }
                        Button {
                            onSettings(app)
                        } label: {
                            Label("游戏设置", systemImage: "gear")
                        }
                        if !app.uiIsShared, app.uiSelectedContainer != nil {
                            Button {
                                onOpenDataFolder(app)
                            } label: {
                                Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
                            }
                        }
                        if !app.uiIsShared {
                            Button {
                                onImportDatapack(app)
                            } label: {
                                Label("导入数据包", systemImage: "square.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                onUninstall(app)
                            } label: {
                                Label("lc.appBanner.uninstall".loc, systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LCGameTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("隐藏的游戏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 本页以 sheet 呈现（列表层包 NavigationView）：右上给显式关闭钮，
            // 也可以下滑关掉弹层。放 confirmationAction 位——与数据包导入页
            // 「取消」的 cancellationAction 正好成对，同为素 Button 无自加样式，
            // 新系统渲染成与标题同行的圆角胶囊钮。
            ToolbarItem(placement: .confirmationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func iconView(for app: LCAppModel) -> some View {
        Group {
            if let iconImage = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
            }
        }
    }
}
