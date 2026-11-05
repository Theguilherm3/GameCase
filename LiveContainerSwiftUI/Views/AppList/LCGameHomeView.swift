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

    var body: some View {
        _ = refreshToken
        if let bannerImage = LCGameLibraryInfo.bannerImage(for: app.appInfo) {
            Image(uiImage: bannerImage)
                .resizable()
                .scaledToFill()
        } else if let iconImage = app.appInfo.iconIsDarkIcon(darkModeIcon) {
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
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.06))
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
    @State private var focusKey: String?
    @StateObject private var controllerMonitor = LCControllerMonitor()
    @State private var controllerListPresented = false

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

    private func datapackReady(_ app: LCAppModel) -> Bool {
        // 读 refreshToken 把依赖写明：令牌变化时状态点随 body 按磁盘重算
        _ = refreshToken
        return LCGameLibraryInfo.isDatapackReady(container: LCGameLibraryInfo.defaultContainer(for: app))
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
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            ensureFocus()
        }
        .onChange(of: apps.map { key(of: $0) }) { _ in
            ensureFocus()
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
    /// 监听连接/断开刷新），点击以 sheet 打开手柄页（LCControllersView，复刻 NX 壳
    /// ControllersView 的结构与视觉）。尺寸与位置沿用原常量，只接行为。
    private func gamepadCapsule(height: CGFloat) -> some View {
        Button {
            controllerListPresented = true
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
        .sheet(isPresented: $controllerListPresented) {
            LCControllersView(monitor: controllerMonitor)
        }
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
                LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
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
                        HStack(spacing: 8) {
                            statusDot(color: datapackReady(app) ? LCGameTheme.readyGreen : LCGameTheme.missingAmber, radius: 5)
                            Text(datapackReady(app) ? "随时可玩" : "缺数据包")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(datapackReady(app) ? LCGameTheme.readyGreen : LCGameTheme.missingAmber)
                        }
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
                ForEach(apps, id: \.self) { app in
                    VStack(alignment: .leading, spacing: 8) {
                        LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
                            .frame(width: columnWidth, height: columnWidth * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                statusDot(color: datapackReady(app) ? LCGameTheme.readyGreen : LCGameTheme.missingAmber, radius: 5)
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
        if !datapackReady(app) {
            HStack(spacing: 6) {
                statusDot(color: LCGameTheme.missingAmber, radius: 3.5)
                Text("缺数据包")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(LCGameTheme.missingAmber)
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

    // MARK: 横屏

    private func landscape(size: CGSize, safe: EdgeInsets) -> some View {
        let w = size.width
        let h = size.height
        let m = margin(for: size)
        let focusedW = w * 0.385
        let centerY = h * 0.54
        return ZStack {
            // 封面色调背景：聚焦封面重模糊 + 压暗（照预览取值）
            if let app = focusedApp {
                LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
                    .frame(width: w, height: h)
                    .clipped()
                    .blur(radius: 30)
                    .saturation(1.15)
                    .brightness(-0.16)
                    .overlay(Color.black.opacity(0.28))
            }
            VStack {
                Spacer()
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(0), location: 0),
                        .init(color: Color.black.opacity(0.65), location: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: h * 0.6)
            }
            VStack {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(0.24), location: 0),
                        .init(color: Color.black.opacity(0), location: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: h * 0.2)
                Spacer()
            }

            // 轮播
            carousel(size: size, centerY: centerY)
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            if value.translation.width < -50 {
                                stepFocus(1)
                            } else if value.translation.width > 50 {
                                stepFocus(-1)
                            }
                        }
                )

            // 顶部行：左位置字、右按钮排
            VStack {
                HStack(alignment: .center) {
                    HStack(spacing: 12) {
                        Text("你的游戏")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 206 / 255, green: 200 / 255, blue: 194 / 255))
                        Text("第 \(focusIndex + 1) 个，共 \(apps.count)")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 172 / 255, green: 164 / 255, blue: 158 / 255))
                    }
                    Spacer()
                    chromeRow(diameter: 41, includeSliders: true)
                }
                // 顶排对齐 NX 横屏：钮面约在屏高 4% 处起（图标中心 ≈ 7%）
                .padding(.top, safe.top + size.height * 0.04)
                .padding(.horizontal, m)
                Spacer()
            }

            // 聚焦游戏名 + 状态行（居中于聚焦卡）
            if let app = focusedApp {
                let cardBottom = centerY + focusedW * 9 / 32
                VStack(spacing: 9) {
                    Text(app.displayName)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        statusDot(color: datapackReady(app) ? LCGameTheme.readyGreen : LCGameTheme.missingAmber, radius: 4)
                        Text(datapackReady(app) ? "随时可玩 · 数据包已就绪" : "缺数据包")
                            .font(.system(size: 12))
                            .foregroundColor(datapackReady(app)
                                ? Color(red: 196 / 255, green: 232 / 255, blue: 204 / 255)
                                : Color(red: 1.0, green: 196 / 255, blue: 110 / 255))
                    }
                }
                .position(x: carouselCenterX(for: focusIndex, width: w), y: cardBottom + 40)
            }
        }
    }

    /// 轮播里第 index 张卡的中心 X：聚焦卡左缘在屏宽 20.8% 处，邻卡依次紧贴
    /// （NX 横屏实测：聚焦卡宽 ≈ 38.5%、邻卡 ≈ 30%）
    private func carouselCenterX(for index: Int, width w: CGFloat) -> CGFloat {
        let focusedW = w * 0.385
        let neighborW = w * 0.30
        func cardWidth(_ i: Int) -> CGFloat {
            i == focusIndex ? focusedW : neighborW
        }
        var center = w * 0.208 + focusedW / 2
        if index == focusIndex {
            return center
        }
        var current = focusIndex
        if index > focusIndex {
            while current < index {
                center += (cardWidth(current) + cardWidth(current + 1)) / 2
                current += 1
            }
        } else {
            while current > index {
                center -= (cardWidth(current) + cardWidth(current - 1)) / 2
                current -= 1
            }
        }
        return center
    }

    private func carousel(size: CGSize, centerY: CGFloat) -> some View {
        let w = size.width
        let focusedW = w * 0.385
        let neighborW = w * 0.30
        return ZStack {
            ForEach(apps.indices, id: \.self) { idx in
                let app = apps[idx]
                let isFocused = idx == focusIndex
                let cardW = isFocused ? focusedW : neighborW
                LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
                    .frame(width: cardW, height: cardW * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(isFocused ? 0.14 : 0.12), lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        statusDot(color: datapackReady(app) ? LCGameTheme.readyGreen : LCGameTheme.missingAmber, radius: 5.5)
                            .padding(11)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !isFocused && !datapackReady(app) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(LCGameTheme.missingAmber)
                                    .frame(width: 8, height: 8)
                                Text("缺数据包")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(LCGameTheme.missingAmber)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color(red: 24 / 255, green: 18 / 255, blue: 8 / 255).opacity(0.85)))
                            .padding(10)
                        }
                    }
                    .overlay {
                        if !isFocused {
                            Color.black.opacity(0.28)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // NX 原版横屏没有开始钮：点已聚焦的卡 = 启动，点邻卡只切换聚焦
                        if isFocused {
                            onRun(app)
                        } else {
                            setFocus(app)
                        }
                    }
                    .contextMenu {
                        gameContextMenu(for: app)
                    }
                    .position(x: carouselCenterX(for: idx, width: w), y: centerY)
                    .zIndex(isFocused ? 2 : 1)
                    .animation(.easeInOut(duration: 0.35), value: focusIndex)
            }
        }
        .frame(width: w, height: size.height)
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
