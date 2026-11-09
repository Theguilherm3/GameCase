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
    /// 奶油强调色（文字 / 描边 / 选中态）：动态色——深色值与原硬编码
    /// 逐字一致；浅色改深金棕，保证在浅底上作文字可读。恒深色面专用
    /// 的静态版见 creamOnDark（按键布局编辑器的黑底 chip 在用）。
    static let creamColor = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.965, green: 0.929, blue: 0.839, alpha: 1)
            : UIColor(red: 0.55, green: 0.40, blue: 0.16, alpha: 1)
    })
    /// 奶油色静态版（= creamColor 的深色值）：只给恒深色底的面用
    static let creamOnDark = Color(red: 0.965, green: 0.929, blue: 0.839)
    static let accentColor = Color(red: 0.788, green: 0.373, blue: 0.263)
    // 压在页面/卡片底上的诸项随外观翻转（UIColor trait 动态色）：深色值
    // 与原硬编码逐字一致，浅色值见各行后段。只压在封面图 / 固定深色罩
    // 上的浮层色（chipBackground、chipIconOnDark 等）不翻，两模式共用。
    static let cardBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.118, green: 0.118, blue: 0.129, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })

    // NX 预览取值
    static let pageBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1)
            : UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)
    })
    /// 浅色封面头深罩的共享 stops（P1 的主页版形状）：主页 hero 与
    /// 每游戏设置页头共用同一套——峰值 0.47 在标题带、其前 0.42 的
    /// 宽平台罩住整个标题块，尾部两段缓降（0.24 → 0.06 → 0）不留
    /// 硬界。两处只差几何（罩总高 / 帧下下探量），形状禁止各处另
    /// 写：#63 时设置页自带一套陡尾 stops（0.40@0.86 → 0@1），罩在
    /// 帧下缘处仍剩约 0.27 的黑、只用 22pt 就收零，浅底上成一条看
    /// 得出的灰带（用户实测）。尾段较 #63 主页初版再放缓一档
    /// （0.26@0.82 / 0.08@0.93 → 0.24@0.81 / 0.06@0.92），末端更
    /// 早趋零；峰值与标题带数值逐字不动。Phase 30 几何通则：两
    /// 处的 loc 1（alpha 0）都必须正落在各自封面图的绘制下缘、
    /// 罩不探出图外——几何取值见两处调用点注释。
    static let coverScrimStops: [Gradient.Stop] = [
        .init(color: .black.opacity(0), location: 0),
        .init(color: .black.opacity(0.22), location: 0.30),
        .init(color: .black.opacity(0.42), location: 0.52),
        .init(color: .black.opacity(0.47), location: 0.68),
        .init(color: .black.opacity(0.24), location: 0.81),
        .init(color: .black.opacity(0.06), location: 0.92),
        .init(color: .black.opacity(0), location: 1),
    ]
    /// 主操作奶油色（开始按钮 / 聚焦选中线）：动态色——深色值与原硬
    /// 编码逐字一致；浅色略加深饱和，白底上作填充 / 玻璃 tint 不发飘
    static let nxCream = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 240 / 255, blue: 214 / 255, alpha: 1)
            : UIColor(red: 0.96, green: 0.83, blue: 0.55, alpha: 1)
    })
    static let mutedText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 158 / 255, green: 158 / 255, blue: 164 / 255, alpha: 1)
            : UIColor(red: 99 / 255, green: 99 / 255, blue: 104 / 255, alpha: 1)
    })
    static let sectionText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 228 / 255, green: 224 / 255, blue: 218 / 255, alpha: 1)
            : UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    })
    static let readyGreen = Color(red: 64 / 255, green: 214 / 255, blue: 120 / 255)
    static let missingAmber = Color(red: 1.0, green: 176 / 255, blue: 66 / 255)
    /// 已损坏（状态机三态新增，与设置页 LCNXColor.broken 同值）
    static let brokenRed = Color(red: 1.0, green: 0.42, blue: 0.38)
    static let chipBackground = Color(red: 30 / 255, green: 28 / 255, blue: 29 / 255).opacity(0.92)
    /// chip 描边（压封面图上，两模式共用）
    static let chipBorder = Color.white.opacity(0.18)
    /// chip 描边（压页面 / 卡片自适应面上）：深色 = chipBorder 原值，
    /// 浅色改黑 0.12
    static let chipBorderOnSurface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.12)
    })
    /// chip 图标色（玻璃 / 自适应面用）：动态色——深色值与原硬编码逐字
    /// 一致；浅色改深暖灰。固定深底（非玻璃回退的 chipBackground）上
    /// 用 chipIconOnDark 静态浅色，分工见 gcChipIconForeground。
    static let chipIcon = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 232 / 255, green: 230 / 255, blue: 228 / 255, alpha: 1)
            : UIColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
    })
    /// chip 图标静态浅色（= chipIcon 深色值）：只给固定深底用
    static let chipIconOnDark = Color(red: 232 / 255, green: 230 / 255, blue: 228 / 255)
}

extension View {
    /// 图面 chip 的图标 / 文字前景：玻璃分支（玻璃本身随外观自适应）
    /// 用动态 chipIcon；非玻璃回退分支底是固定深色 chipBackground，
    /// 用静态浅色 chipIconOnDark。两分支各自可读、深色逐字不变。
    func gcChipIconForeground() -> some View {
        self.modifier { view in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                view.foregroundColor(LCGameTheme.chipIcon)
            } else {
                view.foregroundColor(LCGameTheme.chipIconOnDark)
            }
        }
    }

    /// 底部开始按钮的底：玻璃开时原生 Liquid Glass（regular + 主操作
    /// nxCream tint + interactive；苹果规范里 tint 只给主操作）；非玻璃
    /// 回退逐字保留实心 nxCream 胶囊。
    func gcStartButtonBackground() -> some View {
        self.modifier { view in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                view.glassEffect(.regular.tint(LCGameTheme.nxCream).interactive(), in: .capsule)
            } else {
                view.background(LCGameTheme.nxCream).clipShape(Capsule())
            }
        }
    }
}

// MARK: - 封面图（横版封面 → 图标兜底，与旧卡片 coverView 同语义）

struct LCGameCoverView: View {
    let app: LCAppModel
    let darkModeIcon: Bool
    /// 库内容刷新令牌（列表层在设置页 / 导入页关闭后 bump）：封面是 body 里
    /// 现读磁盘算出来的，本视图不观察任何状态，令牌不变 body 就不重跑、
    /// 换完封面仍显示旧图。令牌作为入参变化即触发重解析。
    let refreshToken: Int
    /// 无横图兜底美化（Phase 19）：解析落到图标时不把图标拉伸充数，
    /// 改 NX 无横图同款语言（与设置页头部 Phase 17 的无横图路同源）。
    /// 打开的面：竖屏 hero、横屏牌组卡、竖屏网格卡与最近游玩缩略图
    /// （网格/最近两处 2026-11-08 按 Tiao 要求对齐横屏处理）；仅横屏
    /// 背景晕染保持旧兜底（整幅糊化是其本职）。
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
                .fill(Color.primary.opacity(0.06))
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
    /// 列表层是否有任何弹层 / 面板盖在主页之上（设置面板、隐藏游戏页、
    /// 数据包导入、卸载确认、JIT 流程等）：手柄导航的让位判据，列表层注入
    let overlayPresented: Bool

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
    /// 主页手柄导航输入层（十字键 / 左摇杆移选、A 开始）：handler 的
    /// 装卸由 gamepadGateOpen 判据驱动，见 body 的 onChange
    @StateObject private var gamepadNav = LCGamepadNavHandler()
    /// 横屏布局标志（手柄移动语义分岔：横屏只左右切卡、竖屏走网格
    /// 步进），由 safeSize 方向维护（与 body 的布局判据同向）
    @State private var isLandscapeLayout = false
    /// 手柄移动后的滚动请求令牌：竖屏 ScrollViewReader 观察它把选中
    /// 卡滚入可见区；触摸切换聚焦不 bump、滚动位置不被抢
    @State private var gamepadScrollToken = 0
    @Environment(\.scenePhase) private var scenePhase
    /// 手柄页呈现状态（Phase 22 起统一走 LCSidePanelContainer 自适应
    /// 宿主：横屏 = 右侧面板、竖屏 = 整屏，形态随当前尺寸跟随、旋转
    /// 原地变形；Phase 14 的 sheet / 面板打开时二选一已废除）
    @State private var controllerPanelPresented = false

    @State private var stateHelpTarget: LCGameStateTarget?

    // 库顺序快照（竖屏网格与横屏牌组共用）：Phase 30 起冻结并持久
    // 化——快照落 UserDefaults（LCGameLibraryOrderStore），视图初值
    // 直接读回，主页存活期间与回库（进程重启重建视图）都不再按
    // 「最近游玩」重排；只有游戏集合变化（装 / 卸）时才收敛一次
    // （幸存者相对次序不变、新游戏追加末尾，见 maintainLibraryOrder），
    // 全新安装无快照时才按 LCGameLibraryInfo.libraryOrder（最近
    // 游玩 → 可玩 → 缺数据包 → 已损坏）定序一次。冻结的动因是横屏
    // 回库失同步，查实结论见 snapCarouselToFocus 的 Phase 30 复盘。
    // 竖屏下方的「最近游玩」区是分组第 0 组（玩过的游戏）的独立
    // 呈现，仍走 recentApps，不受本快照影响；聚焦与 hero 也不读
    // 顺序。状态点颜色是现算的、会变，位置不变。
    // carouselOffset 是 >3 张时手势轮播的滚动量（点），静止时恒
    // 等于聚焦序号 × stride；存活期内顺序变化（装 / 卸收敛）时由
    // snapCarouselToFocus 无动画重算（Phase 28 安全网，Phase 30 保留）。
    // carouselDragLogicalOffset 是拖动中的
    // 未钳制逻辑偏移（手指原始位移换算）：显示偏移在两端橡皮筋化，
    // 落点投影按逻辑偏移算，两者只在越界拖动时不同。
    @State private var libraryOrderKeys: [String] = LCGameLibraryOrderStore.load()
    @State private var carouselOffset: CGFloat = 0
    @State private var carouselDragStartOffset: CGFloat = 0
    @State private var carouselDragLogicalOffset: CGFloat = 0
    @State private var carouselDragging = false
    @State private var carouselSettled = true
    @State private var carouselScrollEpoch = 0
    // 横屏牌组点击裁决（Phase 27）：上次裁决时刻（同一触摸被重复投递
    // 时的时间窗去重）与最近一次牌组切换时刻（shelf 没有 carousel 的
    // settled 机制，用它判停稳，deckLastSwitchAt 由 setFocusFromDeck
    // 记录）——见 deckTap 注释。
    @State private var deckTapAdjudicatedAt: Date = .distantPast
    @State private var deckLastSwitchAt: Date = .distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

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

    // MARK: 手柄导航（主页版）

    /// 手柄导航的让位判据：库非空、列表层无弹层 / 面板盖着、主页
    /// 自身的手柄面板与状态帮助页都没开、App 在前台。任一不成立时
    /// 输入层摘掉 handler，手柄事件不落到主页。
    private var gamepadGateOpen: Bool {
        !apps.isEmpty && !overlayPresented && !controllerPanelPresented
            && stateHelpTarget == nil && scenePhase == .active
    }

    private func wireGamepadNav() {
        gamepadNav.onMove = { direction in gamepadMove(direction) }
        gamepadNav.onConfirm = { gamepadConfirm() }
    }

    /// 移动一格：复用现成聚焦状态（focusKey / focusedApp，不另建
    /// 焦点模型），顺序走 orderedApps（竖屏网格与横屏牌组的共同
    /// 视觉序）。横屏单列：左右切卡、上下不接；竖屏双列网格：
    /// 左右 ±1、上下 ±2（列数），到边停住不绕圈。横屏切换走
    /// setFocusFromDeck（牌组动画与停稳计时同触摸口径，轮播偏移
    /// 由其 onChange(focusKey) 自行同步）；竖屏切换后 bump 滚动
    /// 令牌，让 ScrollViewReader 把选中卡滚进可见区。
    private func gamepadMove(_ direction: LCGamepadNavDirection) {
        let list = orderedApps
        guard let current = focusedApp, let idx = list.firstIndex(of: current) else {
            ensureFocus()
            return
        }
        let delta: Int
        if isLandscapeLayout {
            switch direction {
            case .left: delta = -1
            case .right: delta = 1
            case .up, .down: return
            }
        } else {
            switch direction {
            case .left: delta = -1
            case .right: delta = 1
            case .up: delta = -2
            case .down: delta = 2
            }
        }
        let target = idx + delta
        guard list.indices.contains(target) else {
            return
        }
        if isLandscapeLayout {
            setFocusFromDeck(list[target])
        } else {
            setFocus(list[target])
            gamepadScrollToken += 1
        }
    }

    /// A 键 = 开始：与竖屏底部开始按钮同一入口（onRun，列表层
    /// wired 到 runGame）、同一可用条件（有聚焦且没有游戏在跑）；
    /// 横屏侧等价于点已停稳的聚焦卡（deckTap 的启动路）。
    private func gamepadConfirm() {
        guard let app = focusedApp, !app.isAppRunning else {
            return
        }
        onRun(app)
    }

    // MARK: 横屏轮播的顺序与聚焦（NX2 CoverFlow 移植辅助）

    /// 全主页共用的有序数据源（横屏牌组与竖屏「你的游戏」网格同读）：
    /// 顺序快照 ∩ 现有游戏，新游戏追加末尾；快照为空（全新安装、尚未
    /// 定序）时退回入参次序。Phase 30 起快照持久化且冻结：onAppear
    /// 只做集合收敛（maintainLibraryOrder），不再按最近游玩重排。
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

    /// 顺序快照维护（Phase 30 冻结）：root onAppear 调用。
    /// - 无快照（全新安装）：按 libraryOrder 定序一次并落盘——这是
    ///   唯一按最近游玩排序的时点，此刻视图刚建、没有活着的偏移量，
    ///   不会失同步。
    /// - 有快照、集合变了（装 / 卸）：收敛为生效次序（幸存者相对
    ///   次序不变、新游戏追加末尾，即 orderedApps 的推导结果）并
    ///   落盘；变序发生在存活视图上，偏移由顺序签名 snap 兜底。
    /// - 有快照、集合没变（普通出现 / 回库）：什么都不做——次序
    ///   冻结，刚玩的游戏不换位置；焦点由 focusedApp 的缺省推导
    ///   （最近启动款）跟随，牌组 onAppear 的 snap 按冻结序号落位
    ///   （回库有淡入遮罩盖住接缝，落位无动画不可见）。
    private func maintainLibraryOrder() {
        guard !apps.isEmpty else {
            return
        }
        if libraryOrderKeys.isEmpty {
            let seeded = LCGameLibraryInfo.libraryOrder(of: apps).map { key(of: $0) }
            libraryOrderKeys = seeded
            LCGameLibraryOrderStore.save(seeded)
            return
        }
        let effective = orderedApps.map { key(of: $0) }
        if effective != libraryOrderKeys {
            libraryOrderKeys = effective
            LCGameLibraryOrderStore.save(effective)
        }
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

    /// 手柄焦点缩放的弹簧：短 response + 略欠阻尼，与 deck 的短促
    /// 切换同风格、放大落定带一点回弹；减弱动态时同口径降为线性。
    private var gamepadFocusAnimation: Animation {
        reduceMotion ? .linear(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.72)
    }

    private func setFocusFromDeck(_ app: LCAppModel) {
        deckLastSwitchAt = Date()
        withAnimation(deckAnimation) {
            focusKey = key(of: app)
        }
    }

    /// 牌组落点规则（Phase 27，取代 NX CardSnap 的一手势一卡钳制）：
    /// 落点 = 逻辑偏移 + 速度投影后最近的卡。velocity 是朝后一张卡
    /// 方向的速度（pt/ms），投影时长 220ms：慢拖时速度近零、落最近
    /// 卡（不足半张回原位）；快甩时投影把落点推过多张、一次滑多卡。
    /// 只钳列表两端，不再钳手势起始卡的邻位。
    private static func cardSnap(logicalOffset: CGFloat, velocity: CGFloat, stride: CGFloat, count: Int) -> Int {
        let projected = logicalOffset + velocity * 220
        let card = Int((projected / stride).rounded())
        return min(count - 1, max(0, card))
    }

    /// 牌组停稳动画（Phase 27）：与 deckAnimation 同一曲线，时长按
    /// 行程（以 stride 计）放大——一卡内仍是 0.3 的原手感，远行程至
    /// 多 0.55，避免多卡跳变套一卡时长显得硬切。减弱动态时按
    /// deckAnimation 同口径降为 0.2 线性。
    ///
    /// Phase 30（仅拖动松手、且行程 > 1 卡时）：0.55 的定时曲线在
    /// 多卡行程上读作拖尾（用户实测：小幅好评、大幅有延迟感），
    /// 改走插值弹簧——interpolatingSpring(质量 1、刚度 150、阻尼
    /// 24)，阻尼比 ≈0.98 近临界、无过冲；弹簧时标与行程无关
    /// （包络衰减 ζω₀ ≈ 12/s，收敛到 1% 约 0.38s），多卡总时长
    /// 天然次线性、落在约 0.38–0.45s。初速与松手速度连续：把
    /// 「朝落点方向的松手速度（pt/s）÷ 行程（pt）」折算为弹簧的
    /// 相对初速（单位 = 全行程/秒，钳 0–5），不从零速起步。一卡
    /// 内（含小幅慢拖就近落点）与点卡、外部同步（不传速度）仍走
    /// 下面的定时曲线原式，逐字未动。
    private func deckSettleAnimation(distance: CGFloat, stride: CGFloat, releaseVelocity: CGFloat? = nil) -> Animation {
        if reduceMotion {
            return .linear(duration: 0.2)
        }
        let strides = stride > 0 ? Double(abs(distance) / stride) : 0
        if strides > 1, let releaseVelocity {
            // releaseVelocity 是 pt/ms（朝后一张卡为正，与偏移增
            // 加同向）；朝落点方向的速度分量 = 它 × 方向符号
            let towardTarget = Double(releaseVelocity) * 1000 * (distance >= 0 ? 1.0 : -1.0)
            let relative = towardTarget / max(1, Double(abs(distance)))
            return .interpolatingSpring(
                mass: 1,
                stiffness: 150,
                damping: 24,
                initialVelocity: min(5, max(0, relative))
            )
        }
        let duration = min(0.55, 0.3 + 0.09 * max(0, strides - 1))
        return .timingCurve(0.22, 0.61, 0.36, 1, duration: duration)
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
                if gamepadNav.hasController && !apps.isEmpty {
                    gamepadHintBar
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
            maintainLibraryOrder()
            // 游玩时长补结（Phase 18）：主页出现 = 此刻没有客体在本进程跑，
            // 统计文件里还挂着的 openSession 必是闪退/被划掉没结清的局，
            // 按心跳补结后再读快照（回库路径已由客体侧结清，这里是空转）。
            LCPlayStats.reconcileOpenSession()
            playStats = LCPlayStats.allEntries()
            sweepCoverFetches()
            // 手柄导航接线：回调注入 + 按当前判据决定是否装 handler
            wireGamepadNav()
            isLandscapeLayout = safeSize.width > safeSize.height
            gamepadNav.setActive(gamepadGateOpen)
        }
        .onDisappear {
            gamepadNav.setActive(false)
        }
        .onChange(of: refreshToken) { _ in
            playStats = LCPlayStats.allEntries()
            sweepCoverFetches()
        }
        .onChange(of: apps.map { key(of: $0) }) { _ in
            ensureFocus()
            // 库增删后重注回调，闭包捕获的 apps 快照不许过期
            wireGamepadNav()
        }
        .onChange(of: gamepadGateOpen) { open in
            gamepadNav.setActive(open)
        }
        .onChange(of: safeSize) { newSize in
            isLandscapeLayout = newSize.width > newSize.height
        }
    }

    /// 手柄提示条（手柄连着时才出现）：底部安全区上方的小胶囊，
    /// 竖屏避开底部开始栏（浮在其上方）、横屏贴底。样式照安装
    /// 胶囊的两分支（iOS 26 玻璃 / 半透明黑回退）。
    private var gamepadHintBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "dpad")
                    .font(.system(size: 13))
                Text("lc.gameHome.gamepadHint".loc)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .modifier { view in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    view
                        .foregroundColor(.primary)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    view
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .overlay(Capsule().strokeBorder(LCGameTheme.chipBorder, lineWidth: 1))
                }
            }
            .padding(.bottom, isLandscapeLayout ? safeAreaInsets.bottom + 10 : safeAreaInsets.bottom + 76)
        }
        .allowsHitTesting(false)
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

    /// 圆形图面浮钮底：两个调用方（chromeButton、＋导入菜单）都是可点
    /// 控件；iOS 26 + Liquid Glass 可用时换原生玻璃（无 tint——regular
    /// 玻璃本身随外观自适应、interactive 按压反馈，形态照 App Store
    /// 浮动栏），否则逐字保留 chip 填充+描边。
    private func circleChrome(diameter: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            content()
        }
        .frame(width: diameter, height: diameter)
        .modifier { view in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                view
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                view
                    .background {
                        ZStack {
                            Circle()
                                .fill(LCGameTheme.chipBackground)
                            Circle()
                                .strokeBorder(LCGameTheme.chipBorder, lineWidth: 1)
                        }
                    }
            }
        }
    }

    private func chromeButton(diameter: CGFloat, systemImage: String, fontSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleChrome(diameter: diameter) {
                Image(systemName: systemImage)
                    .font(.system(size: fontSize))
                    .gcChipIconForeground()
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
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: height * 0.42))
                Text("\(controllerMonitor.controllers.count)")
                    .font(.system(size: height * 0.4, weight: .bold))
            }
            .gcChipIconForeground()
            .padding(.horizontal, height * 0.32)
            .frame(height: height)
            .fixedSize(horizontal: true, vertical: false)
            .modifier { view in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    view
                        .glassEffect(.regular.interactive(), in: .capsule)
                } else {
                    view
                        .background {
                            ZStack {
                                Capsule()
                                    .fill(LCGameTheme.chipBackground)
                                Capsule()
                                    .strokeBorder(LCGameTheme.chipBorder, lineWidth: 1)
                            }
                        }
                }
            }
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
                    .gcChipIconForeground()
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
                Text("正在安装 \(Int(installProgress * 100))%")
                    .font(.footnote.bold())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier { view in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    // 纯展示胶囊（安装进度）：玻璃不加 interactive、不加
                    // tint（随外观自适应），前景走语义色两模式都可读
                    view
                        .foregroundColor(.primary)
                        .tint(.primary)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    view
                        .foregroundColor(.white)
                        .tint(.white)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .overlay(Capsule().strokeBorder(LCGameTheme.chipBorder, lineWidth: 1))
                }
            }
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
                                .overlay(Capsule().strokeBorder(LCGameTheme.chipBorderOnSurface, lineWidth: 1))
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
            ScrollViewReader { proxy in
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
                // 手柄移动后把选中卡滚入可见区：仅手柄路径 bump 令牌，
                // 触摸点选切聚焦不触发、滚动位置不被抢。锚点是网格卡
                // 的 id（portraitGames 给每张卡打了同名 id）
                .onChange(of: gamepadScrollToken) { _ in
                    if let app = focusedApp {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(key(of: app), anchor: .center)
                        }
                    }
                }
            }
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
            // 浅色专用深罩（用户看预览拍板 P1）：浅色下融合渐变把封面
            // 下部洗成近白页底、白色大标题糊在亮底上。标题文字层之下
            // 加一层深色渐变罩：stops 用 LCGameTheme.coverScrimStops
            // 共享形状。几何（Phase 30 修订）：旧几何罩高 0.62h+24、
            // 下探 12——罩跨出封面图下缘、压在图外纯白页底上，图内
            // 压的却是融合渐变洗过的像素，合成曲线在图缘处折角成
            // 横向台阶（#69 拉长尾巴只能减轻、消不掉）。现罩底边与
            // 图下缘齐平、下探 0，罩高改 0.58h：loc 1（alpha 0）正
            // 落在图下缘，罩不探出图外一像素；图像向页底的融合由
            // 上方既有融合渐变承担（页底色不透明，其「透明黑 → 页
            // 底色」渐变与 alpha 蒙版淡出在合成上等价，故保留融合
            // 渐变、不另加蒙版）。标题带强度按 h≈350 换算与此前同
            // 级：状态行（缘上约 97pt）loc 约 0.52（约 0.42）、标
            // 题（约 61pt）loc 约 0.70（约 0.46）、版本行（约
            // 25pt）loc 约 0.88（约 0.13）。深色模式不加、逐字保
            // 持现状（原渐变已是深色融合）。
            if colorScheme == .light {
                VStack {
                    Spacer()
                    LinearGradient(
                        gradient: Gradient(stops: LCGameTheme.coverScrimStops),
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: height * 0.58)
                }
                .allowsHitTesting(false)
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
                        LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
                            .frame(width: columnWidth, height: columnWidth * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                statusDot(color: gameState(app).themeColor, radius: 5)
                                    .padding(10)
                            }
                            // 手柄焦点表现：手柄连着时聚焦卡整体放大
                            // 1.07 + 柔和投影（tvOS 式焦点）；无手柄时
                            // scale 恒 1、无投影，与现行界面逐字一致。
                            // 防裁剪：缩放施加在封面自身 clipShape 之外
                            // （圆角裁剪随图一起放大），本 cell、LazyVGrid、
                            // 外层 VStack 均无任何裁剪；手柄路径又先把
                            // 聚焦卡滚到视口中央，1.07 的增量（卡宽每侧
                            // 约 6pt）小于网格 15pt 间距，放大边缘完整露出
                            .scaleEffect(gamepadNav.hasController && focusedApp == app ? 1.07 : 1)
                            .shadow(color: .black.opacity(gamepadNav.hasController && focusedApp == app ? 0.35 : 0), radius: 12, x: 0, y: 6)
                            .animation(gamepadFocusAnimation, value: gamepadNav.hasController && focusedApp == app)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                setFocus(app)
                            }
                            .contextMenu {
                                gameContextMenu(for: app)
                            }
                        Text(app.displayName)
                            .font(.system(size: 14))
                            .foregroundColor(LCGameTheme.sectionText)
                            .lineLimit(1)
                        // 聚焦项名下米色线（照预览）
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(focusedApp == app ? LCGameTheme.nxCream : Color.clear)
                            .frame(width: columnWidth, height: 3)
                    }
                    // 手柄滚动锚点（ScrollViewReader.scrollTo 的目标 id）
                    .id(key(of: app))
                    // 聚焦卡放大后抬升绘制层级，压住相邻卡而不是被压
                    .zIndex(gamepadNav.hasController && focusedApp == app ? 1 : 0)
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
                    LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
                        .frame(width: 73, height: 41)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        // 手柄焦点表现（与网格卡同口径）：聚焦游戏在
                        // 最近行里出现时缩略图整体放大 1.08（元素小、
                        // 幅度略大）+ 投影，并抬升层级。防裁剪：缩放
                        // 施加在缩略图自身 clipShape 之外，行内 HStack、
                        // 外层 VStack 均无裁剪；1.08 的增量（宽每侧约
                        // 2.9pt、高每侧约 1.6pt）远小于行上下 10pt
                        // 留白与 12pt 横向间距，完整露出
                        .scaleEffect(gamepadNav.hasController && focusedApp == app ? 1.08 : 1)
                        .shadow(color: .black.opacity(gamepadNav.hasController && focusedApp == app ? 0.35 : 0), radius: 8, x: 0, y: 4)
                        .animation(gamepadFocusAnimation, value: gamepadNav.hasController && focusedApp == app)
                        .zIndex(gamepadNav.hasController && focusedApp == app ? 1 : 0)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.displayName)
                            .font(.system(size: 15))
                            .foregroundColor(LCGameTheme.sectionText)
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
                            .foregroundColor(Color(UIColor { trait in
                                trait.userInterfaceStyle == .dark
                                    ? UIColor(red: 168 / 255, green: 168 / 255, blue: 172 / 255, alpha: 1)
                                    : UIColor(red: 110 / 255, green: 110 / 255, blue: 115 / 255, alpha: 1)
                            }))
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
                        .fill(Color.primary.opacity(0.10))
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
                        .gcStartButtonBackground()
                    }
                    .buttonStyle(.plain)
                    // 手柄焦点表现：手柄连着时开始钮整体放大 1.03 +
                    // 投影，明示 A 键的目标就是它；无手柄时 scale 恒 1、
                    // 无投影，逐字原样。防裁剪：底栏 ZStack、HStack 到
                    // portraitBottomBar 根视图全程无任何裁剪修饰，1.03
                    // 的增量（高每侧约 0.9pt、宽每侧约 5pt）小于与滑杆
                    // 钮的 14pt 间距、上方又有 108pt 渐变区兜底，完整露出
                    .scaleEffect(gamepadNav.hasController ? 1.03 : 1)
                    .shadow(color: .black.opacity(gamepadNav.hasController ? 0.25 : 0), radius: 10, x: 0, y: 4)
                    .animation(gamepadFocusAnimation, value: gamepadNav.hasController)
                    .zIndex(gamepadNav.hasController ? 1 : 0)
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
            // 浅色专用深罩（同竖屏 P1）：浅色下背景晕染收尾是浅色页
            // 底、白色标题只剩阴影撑对比。标题簇之下垫一块模糊深色
            // 斑（圆角矩形 + blur 30,边缘全柔、无硬界），深色不加。
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 60)
                    .fill(Color.black.opacity(0.36))
                    .frame(width: min(640, w - 16), height: metrics.short ? 130 : 168)
                    .blur(radius: 30)
                    .allowsHitTesting(false)
            }
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
    /// stride，每卡按 FlowTilt 变形：缩放 1 - |near|×0.22（near = place
    /// 钳 ±1）、内收 near×卡宽 0.28、压暗 |near|×0.25；远处再多退 far×
    /// 卡宽 0.55、压暗至多 0.1；zIndex = -|place|，近卡恒在上。只构造
    /// |place| ≤ 2 的卡（聚焦 ±2），更远的卡不建视图、不触发封面解析，
    /// 长列表不预载全部封面。
    /// 轮播感（Phase 28）：回转角改由连续 place 驱动、不随 near 在 ±1
    /// 饱和——angle = -clamp(place, ±1.5)×30°（±1 卡 30°、|place|≥1.5
    /// 45° 封顶，coverflow 常见 30°–45° 区间），透视 0.35 → 0.45。旧口径
    /// -near×24° 在 ±1 外角度冻结，后段卡是一面平墙跟着平移、读作整排
    /// 被推走；新口径下每张卡的角度随 place 逐帧插值到 45°，整排像轮盘
    /// 转过去。位置公式（place×stride − 内收 − 远退）与缩放 / 压暗曲线
    /// 逐字未动，命中与落点不经几何反推、不受影响；中心卡 angle 0、
    /// scale 1.0 的终点不变。
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
                    let tilt = max(-1.5, min(1.5, place))
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
                            .degrees(reduceMotion ? 0 : -tilt * 30),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.45
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
        .onAppear {
            snapCarouselToFocus(list: list, stride: stride)
        }
        .onChange(of: focusKey) { _ in
            syncCarouselOffset(list: list, stride: stride)
        }
        // 顺序签名（Phase 28）：库重排 / 增删令聚焦卡在 list 里的序号
        // 变化而 focusKey 不变时，focusKey 的 onChange 不会火——偏移的
        // 同步挂到顺序本身上，见 snapCarouselToFocus 注释。
        .onChange(of: list.map { key(of: $0) }) { _ in
            snapCarouselToFocus(list: list, stride: stride)
        }
        .onChange(of: w) { _ in
            snapCarouselToFocus(list: list, stride: stride)
        }
    }

    /// shelf 的停稳判定：距上次牌组切换 ≥ 切换动画时长（0.3）+ 余量，
    /// 与 carousel 的 0.32 口径对齐（reduceMotion 时动画 0.2，同一
    /// 阈值仍成立）。
    private var deckSettled: Bool {
        Date().timeIntervalSince(deckLastSwitchAt) >= 0.32
    }

    /// 横屏牌组点击的唯一裁决点（Phase 27，取代 Phase 16 的快照裁决）：
    /// 滑动切换走既有手势、不经此；点后面的封面只切换；只有点已经
    /// 停稳在前面的封面才启动。
    ///
    /// Phase 16 的裁决读「手势开始时的聚焦位快照」：快照由一个与点击
    /// 同时识别的 DragGesture(minimumDistance: 0)（deckTouchWatcher）
    /// 在 onChanged 里写，而纯点按（落下即抬起、几乎无位移）时该回调
    /// 不保证赶在点击识别完成之前——观察手势漏写时，本次点按拿的是
    /// 上一触摸序列留下的旧快照裁决（快照从不失效、序列结束也不清；
    /// 旧注释写的「快照缺失时退回现读」只在全程第一次点按成立）。
    /// 旧值恰等于被点卡的典型路径：先前聚焦在该卡上、从它滑走（滑
    /// 动开始时快照 = 该卡），牌组停稳（settled 已翻 true）后再点它
    /// 想切回来——idx 与旧快照相等 → 误入启动分支。偶发与否取决于
    /// 两个手势识别器的回调次序，与实测「大多数时候先切换、偶发直
    /// 接启动」吻合；同一观察手势还独占消费标记的复位，漏写时下一
    /// 次点按会被整口吞掉（点了没反应）。
    ///
    /// 本裁决不再依赖任何快照，判定流程可自证：一次点按内，能改聚
    /// 焦的写入口只有拖动落点提交（点按不构成拖动，不会触发）与另
    /// 一次点按的 focusAction（在本裁决内、裁决之后执行），故裁决时
    /// 现读的聚焦位恒等于触摸开始时的聚焦位——「点未聚焦卡」在结
    /// 构上不可能进入启动分支，与手势识别次序无关。被点卡 = 现聚焦
    /// 卡时再叠停稳门（入参 isSettled，裁决时现读）。同一触摸被多
    /// 个识别器重复投递的防御改用时间窗：0.4s 内只裁决一次（同触
    /// 摸的重复识别相隔仅数毫秒；此窗与停稳窗同量级，窗内连点本
    /// 就被 settled 拦在启动之外，吞掉不改变结果）。
    private func deckTap(app: LCAppModel, index idx: Int, list: [LCAppModel], isSettled: Bool, focusAction: () -> Void) {
        if Date().timeIntervalSince(deckTapAdjudicatedAt) < 0.4 {
            return
        }
        deckTapAdjudicatedAt = Date()
        if idx != landscapeFocusIndex(in: list) {
            focusAction()
        } else if isSettled {
            onRun(app)
        }
    }

    /// 点邻卡只居中、点已聚焦卡在轮播停稳时才启动——裁决统一走
    /// deckTap（裁决时现读聚焦位 + 时间窗去重），此处只提供 carousel
    /// 的切换动作（滚动到该卡 + 落聚焦 + settled 计时；滚动动画按
    /// 行程取时长，见 deckSettleAnimation）。
    private func carouselTap(app: LCAppModel, index idx: Int, list: [LCAppModel], stride: CGFloat) {
        deckTap(app: app, index: idx, list: list, isSettled: carouselSettled && !carouselDragging) {
            beginCarouselScroll()
            withAnimation(deckSettleAnimation(distance: CGFloat(idx) * stride - carouselOffset, stride: stride)) {
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
                    beginCarouselScroll()
                }
                // Phase 27：逻辑偏移 = 手指原始位移的无钳制换算，落点
                // 投影按它算；显示偏移全程 1:1 跟随逻辑偏移、只在两端
                // 橡皮筋化（越界部分 ×0.35），不再硬停在边界。
                let logical = carouselDragStartOffset - value.translation.width
                carouselDragLogicalOffset = logical
                let maxOffset = CGFloat(list.count - 1) * stride
                if logical < 0 {
                    carouselOffset = logical * 0.35
                } else if logical > maxOffset {
                    carouselOffset = maxOffset + (logical - maxOffset) * 0.35
                } else {
                    carouselOffset = logical
                }
                // Phase 27：焦点跟随最近卡——逻辑偏移过相邻中点即提
                // 交（取代 Phase 23 的「拖动中不提交」：连续滚动下标题 /
                // 信息区要跟着走）。setFocusFromDeck 只写 focusKey；
                // syncCarouselOffset 在拖动中被 carouselDragging 守卫
                // 挡下、不反抢偏移；背景 / 名牌的淡化由信息区自己的
                // 动画承接，逐步换不闪。
                let nearest = min(list.count - 1, max(0, Int((logical / stride).rounded())))
                if nearest != landscapeFocusIndex(in: list) {
                    setFocusFromDeck(list[nearest])
                }
            }
            .onEnded { value in
                carouselDragging = false
                // Phase 27 落点：逻辑偏移 + 速度投影（velocity 换成朝
                // 后一张卡为正的 pt/ms，投影时长 220ms，公式见
                // cardSnap）——快甩可越过多张、慢拖落最近卡，不再有
                // NX CardSnap 的一卡钳制。停稳时长按行程放大（见
                // deckSettleAnimation；Phase 30 起松手速度一并传入，
                // 多卡段走带初速的插值弹簧、一卡段原式未动）。落点
                // 卡的聚焦在这一帧补正提
                // 交（拖动中已跟随到最近卡，落点因速度投影更远时在
                // 此对齐；Phase 23 的「背景 / 名牌淡化与吸附动画同帧
                // 起跑」时序不变）。settled 仍由 finishCarouselScroll
                // 在 +0.32 翻（与点邻卡 / 外部同步同一机制），
                // Phase 27 的点击裁决口径不动。
                let velocity = -value.velocity.width / 1000
                let card = Self.cardSnap(
                    logicalOffset: carouselDragLogicalOffset,
                    velocity: velocity,
                    stride: stride,
                    count: list.count
                )
                withAnimation(deckSettleAnimation(distance: CGFloat(card) * stride - carouselOffset, stride: stride, releaseVelocity: velocity)) {
                    carouselOffset = CGFloat(card) * stride
                }
                if list.indices.contains(card) {
                    setFocusFromDeck(list[card])
                }
                finishCarouselScroll(epoch: carouselScrollEpoch)
            }
    }

    /// 偏移按现行焦点无动画落位（Phase 28）：把 carouselOffset 在
    /// 当前 list 下重算为 聚焦序号 × stride，关动画直接落位，并作废
    /// 在途的 settle 计时（epoch +1、settled 直接置真）。
    ///
    /// 根因（回库错位，一直存在）：carouselOffset 是一份以「序号 ×
    /// stride」计价的独立存储量，序号的含义随 orderedApps 的顺序而
    /// 变，但旧同步点只有三处——carousel 自己的 onAppear（触发时父级
    /// onAppear 尚未刷新 libraryOrderKeys、读到的还是旧序，写回的是
    /// 同一个旧值）、onChange(focusKey)（动画跟随）、onChange(宽度)。
    /// 回库时 root onAppear 按最近游玩重排 libraryOrderKeys，聚焦卡
    /// 在新序里的序号变了，focusKey 却没变：没有任何一处再写偏移，
    /// 几何中心停在 list[旧序号]，而标题 / 计数 / 信息区是 focusKey
    /// 的纯推导、逐帧正确——于是中心卡与标题对不上（中心丝之歌、
    /// 标题 Hades II 之类），且聚焦卡本人停在 place ≠ 0 处不达正面
    /// 态，非要用户再点一下（走 carouselTap 现写偏移）才对齐；偶尔
    /// 「自己再滑一下」是迟到的 focusKey 变化触发了 syncCarouselOffset
    /// 的动画跟随。shelf（≤3 张）的位置每帧由 chosen 现算、无这份存
    /// 储量，故只有 carousel 中招。
    ///
    /// Phase 30 复盘（#68 的签名网为何在真机回库路径上没拦住，代码
    /// 查实）：回库不是存活视图上的一次重排，而是**进程重启后整棵
    /// 视图树重建**（LCAppListView 的回库淡入遮罩注释即「盖住进程
    /// 重启接缝」、returnFade 初值在 init 里读标记）。重建后整个重
    /// 排发生在出现级联之内：①牌组是深层子视图，onAppear 自内向
    /// 外送达，先于 root onAppear 写 libraryOrderKeys——本函数那时
    /// 读到的是快照为空的 orderedApps（退回 sharedAppSortManager
    /// 的原始入参序），把偏移写成聚焦卡在**旧序**里的序号；②root
    /// onAppear 随后写新序 + ensureFocus 定焦点，但这两个写都落在
    /// 牌组的 onChange 修饰符**首次提交基线之前**——onChange 只对
    /// 基线确立之后的变化触发，级联内完成的变序与焦点赋值被基线
    /// 吸收，顺序签名与 focusKey 两条 onChange 都不会火；③此后再
    /// 无任何写偏移的路径，几何永久停在旧序号，而信息区是纯推导
    /// 逐帧正确。对照组：横竖旋转时牌组子树在存活视图上重建，本
    /// 函数的 onAppear 读到的是早已提交的现行序，落位正确、可自
    /// 愈——分界正在「重排与重建是否同级联」。Phase 28 的分析默认
    /// 了「重排是存活视图上的事后变化」，对装 / 卸成立、对回库不
    /// 成立。Phase 30 的解法是取消回库重排本身（快照冻结 + 持久
    /// 化，见 maintainLibraryOrder）：级联里不再有变序，本函数的
    /// onAppear 读到的第一份 list 即冻结序，落位天然正确；焦点跟
    /// 随走 focusedApp 缺省推导（最近启动款），其序号全程不变，
    /// syncCarouselOffset 的动画跟随路径（存活期内改 focusKey，
    /// 基线早已确立）不受级联问题影响、逐字未动。
    ///
    /// 本函数的现行职责（Phase 30）：onAppear / 宽度变化时按现行
    /// 冻结序落位；顺序签名 onChange 保留作存活期安全网——装 / 卸
    /// 令 maintainLibraryOrder 收敛快照时，变序是基线确立之后的事
    /// 后变化，签名网正常触发、与重算落在同一次状态更新里。拖动
    /// 中不干预（手势的 list 是手势开始时的快照）。落位后 settled
    /// 即真：回库看到的聚焦卡可直接点启动，与「已停稳的聚焦卡」
    /// 裁决口径一致。
    private func snapCarouselToFocus(list: [LCAppModel], stride: CGFloat) {
        guard !carouselDragging else {
            return
        }
        carouselScrollEpoch += 1
        carouselSettled = true
        let target = CGFloat(landscapeFocusIndex(in: list)) * stride
        guard carouselOffset != target else {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            carouselOffset = target
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
        withAnimation(deckSettleAnimation(distance: target - carouselOffset, stride: stride)) {
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

// MARK: - 库顺序快照持久化

/// 库顺序快照落盘（Phase 30）：回库是进程重启、@State 不跨进程
/// 存活，冻结的次序只能落 UserDefaults。只存相对路径键序列；读
/// 回后仍经 orderedApps 与当前游戏集合求交，落盘值过期（装 / 卸
/// 后未及收敛）不会产生幽灵条目，收敛由 maintainLibraryOrder 负责。
enum LCGameLibraryOrderStore {
    private static let defaultsKey = "gc.libraryOrderSnapshot.v1"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    static func save(_ keys: [String]) {
        UserDefaults.standard.set(keys, forKey: defaultsKey)
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

// MARK: - 手柄导航输入（游戏库主页版）

enum LCGamepadNavDirection {
    case up, down, left, right
}

/// 主页手柄导航的输入层：给每个已连接的 extendedGamepad 装
/// valueChangedHandler，把十字键 / 左摇杆 / A 键翻译成「移动一格 /
/// 确认」的边沿事件，回调给 LCGameHomeView 驱动现成聚焦状态。
/// 只在主页激活（setActive(true)）时装 handler——主页让位（面板 /
/// 弹层打开、切后台、离开主页）即摘除，手柄断开即 hasController
/// 转假（上层据此收起提示条与焦点缩放）。全仓此前没有任何地方装
/// valueChangedHandler（手柄页的按键测试是轮询读值），不存在抢占。
/// 摇杆防抖：触发阈值 0.55、取主导轴向定格方向，回中到 0.3 以内
/// 才重新武装——推住不连发、推一次只动一格。十字键同样只认按下
/// 边沿；v1 不做十字键长按连发。
final class LCGamepadNavHandler: ObservableObject {
    @Published private(set) var hasController = false

    var onMove: ((LCGamepadNavDirection) -> Void)?
    var onConfirm: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var isActive = false
    private var pressedEdges: [String: Bool] = [:]
    private var stickDirection: LCGamepadNavDirection?

    init() {
        refreshConnection()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConnection()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConnection()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        detachHandlers()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            attachHandlers()
        } else {
            detachHandlers()
        }
    }

    private func refreshConnection() {
        hasController = GCController.controllers().contains { $0.extendedGamepad != nil }
        if isActive {
            attachHandlers()
        }
    }

    private func attachHandlers() {
        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else {
                continue
            }
            gamepad.valueChangedHandler = { [weak self] gamepad, _ in
                self?.handle(gamepad)
            }
        }
    }

    private func detachHandlers() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        pressedEdges.removeAll()
        stickDirection = nil
    }

    private func handle(_ gamepad: GCExtendedGamepad) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handle(gamepad)
            }
            return
        }
        guard isActive else {
            return
        }
        if edge("dpad.up", gamepad.dpad.up.isPressed) { onMove?(.up) }
        if edge("dpad.down", gamepad.dpad.down.isPressed) { onMove?(.down) }
        if edge("dpad.left", gamepad.dpad.left.isPressed) { onMove?(.left) }
        if edge("dpad.right", gamepad.dpad.right.isPressed) { onMove?(.right) }
        handleStick(gamepad.leftThumbstick)
        if edge("buttonA", gamepad.buttonA.isPressed) { onConfirm?() }
    }

    /// 按下边沿：只在 false → true 跳变时返回 true
    private func edge(_ name: String, _ pressed: Bool) -> Bool {
        let was = pressedEdges[name] ?? false
        pressedEdges[name] = pressed
        return pressed && !was
    }

    private func handleStick(_ stick: GCControllerDirectionPad) {
        let x = stick.xAxis.value
        let y = stick.yAxis.value
        let magnitude = max(abs(x), abs(y))
        if stickDirection != nil {
            // 已定格：等摇杆回到近中心才重新武装，推住不连发
            if magnitude < 0.3 {
                stickDirection = nil
            }
            return
        }
        guard magnitude > 0.55 else {
            return
        }
        let direction: LCGamepadNavDirection = abs(x) > abs(y)
            ? (x > 0 ? .right : .left)
            : (y > 0 ? .up : .down)
        stickDirection = direction
        onMove?(direction)
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
                                .foregroundColor(LCGameTheme.sectionText)
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
                                .overlay(Capsule().strokeBorder(LCGameTheme.chipBorderOnSurface, lineWidth: 1))
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
    }

    private func iconView(for app: LCAppModel) -> some View {
        Group {
            if let iconImage = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
            }
        }
    }
}
