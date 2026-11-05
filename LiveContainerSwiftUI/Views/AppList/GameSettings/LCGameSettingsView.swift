//
//  LCGameSettingsView.swift
//  LiveContainerSwiftUI
//
//  每游戏设置页（样式按已批准预览 lc-settings-silk-v1）：改动写进这个游戏在容器里的
//  偏好 plist，与游戏内启动器、按键编辑器共用一份，下次启动生效。分组沿预览：
//  游戏（数据包 / 存档，只读信息 + 入口）、显示（档案 Game 组）、按键（档案 Controls
//  组，皮肤与按键布局排在最前）、性能（档案 Performance 组）；档案由 LCGameProfile
//  从客体自带的 dm/launcher.json 解析，没有档案的游戏给通用提示。
//

import SwiftUI
import UniformTypeIdentifiers

/// 裁剪页呈现载荷（fullScreenCover item）
private struct LCCoverCropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct LCGameSettingsView: View {
    @ObservedObject var app: LCAppModel
    var onOpenDataFolder: () -> Void
    /// 横屏侧面板呈现时的关闭回调（Phase 14，列表层注入）：面板不是
    /// 系统呈现，dismiss 环境无效，关闭走此回调；nil = sheet 呈现，
    /// 左上角「取消」用 dismiss 环境关闭（列表层包 NavigationView 供
    /// 页内子页推进），与原来一致。
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    /// 横屏侧面板内标记（面板容器注入）：面板内边距按 NX 口径 24，
    /// 其余形态沿用本页既有 16（见 body 内容列的 padding）
    @Environment(\.lcInSidePanel) private var inSidePanel

    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    @State private var prefs: LCGamePrefs?
    @State private var settings: [LCLauncherSetting] = []
    @State private var hasProfile = false
    @State private var lockedValues: [String: String] = [:]
    /// env → 当前生效值（已保存选择 ?? env 固定值 ?? 档案默认值），驱动所有行显示
    @State private var currentValues: [String: String] = [:]
    @State private var datapackRequest: LCDatapackRequest?
    @State private var statusRefresh = 0 // 数据包导入完成后 bump，刷新状态点
    @State private var confirmReset = false

    // 自定义封面流程（选图 → 16:9 裁剪 → 存宿主 Documents/CustomCovers）
    @State private var coverRefresh = 0 // 换/删自定义封面后 bump，刷新本页封面条与封面行
    @State private var coverMenuPresented = false
    @State private var photoPickerPresented = false
    @State private var filePickerPresented = false
    @State private var cropItem: LCCoverCropItem?
    @State private var coverErrorPresented = false

    private static let cardBackground = Color(red: 0.118, green: 0.118, blue: 0.129)
    private static let pageBackground = Color(red: 0.055, green: 0.055, blue: 0.059)

    private var knownGame: LCKnownGame? {
        LCKnownGame.from(bundleIdentifier: app.bundleIdentifier)
    }

    private var container: LCContainer? {
        LCGameLibraryInfo.defaultContainer(for: app)
    }

    var body: some View {
        // 横屏收窄加在容器本体（ScrollView）上：LCSettingsColumn 在页面根层
        // 读自身尺寸，横屏时把 ScrollView 显式定宽 640 并居中，封面/标题/
        // 全部分组随之一起收进列内；竖屏时 ScrollView 仍是全宽全高，与原来
        // 逐点一致。PR #10 把 .frame(maxWidth: 640) 加在滚动内容 VStack 上，
        // 真机落点 ≈669pt 且各页不一致——内容的帧不治理滚动视口宽度，本轮
        // 改到视口层（详见 LCSettingsColumn.swift 的注释）。
        LCSettingsColumn { _ in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header()
                    .fullScreenCover(item: $cropItem) { item in
                        NavigationView {
                            LCCoverCropView(image: item.image) { cropped in
                                saveCroppedCover(cropped)
                            }
                        }
                    }
                gameInfoSection
                    .confirmationDialog("封面图", isPresented: $coverMenuPresented, titleVisibility: .visible) {
                        Button("从相册选择") { photoPickerPresented = true }
                        Button("从文件选择") { filePickerPresented = true }
                        if coverHasCustom {
                            Button("恢复默认", role: .destructive) { removeCustomCover() }
                        }
                        Button("lc.common.cancel".loc, role: .cancel) {}
                    } message: {
                        Text("自定义封面只替换游戏库里的显示图，存在本机，不影响游戏本体。")
                    }
                    .sheet(isPresented: $photoPickerPresented) {
                        LCPhotoImagePicker(
                            onPick: { image in
                                photoPickerPresented = false
                                presentCrop(for: image)
                            },
                            onFail: {
                                photoPickerPresented = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    coverErrorPresented = true
                                }
                            },
                            onCancel: { photoPickerPresented = false }
                        )
                        .ignoresSafeArea()
                    }
                    .fileImporter(isPresented: $filePickerPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                        handleCoverFileImport(result)
                    }
                    .alert("无法使用这张图片", isPresented: $coverErrorPresented) {
                        Button("好", role: .cancel) {}
                    } message: {
                        Text("所选内容不是有效的图片，或保存失败，请换一张再试。")
                    }
                if !hasProfile {
                    noProfileHint
                } else if prefs == nil {
                    noContainerHint
                } else {
                    profileSections
                    if hasSavedValues {
                        resetRow
                    }
                }
                advancedSection
                footerNote
            }
            // 横向边距只由这一处 padding 决定（横向 safe inset 的处理
            // 见 LCSettingsColumn 的 Phase 16 注释）：面板内按 NX 面板
            // 口径 24，其余形态 16（本页原值）
            .padding(.horizontal, inSidePanel ? 24 : 16)
            .padding(.bottom, 40)
            // 展开到 ScrollView 视口全宽（横屏即 640 列、竖屏即屏宽）；
            // 定宽本身由外层 LCSettingsColumn 给 ScrollView 本体，内容层
            // 不再加 maxWidth（PR #10 在这里加 640 未生效，见上）。
            .frame(maxWidth: .infinity)
        }
        }
        .background(Self.pageBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // 工具栏不设标题（Phase 16D）：页内头部已有游戏名大标题，工具栏
        // 再挂内联标题是两处重复——只留左上「取消」。sheet 与侧面板
        // 共用本 body，两形态一并生效。
        .toolbar {
            // 工具栏只留左上角一个「取消」：与数据包导入页的取消同位
            // （.cancellationAction）同型（素 Button + dismiss），系统渲染为
            // 标题行左端的胶囊钮。页内不再设回库/启动动作——关闭靠它与下滑，
            // 启动走主页的开始钮。
            ToolbarItem(placement: .cancellationAction) {
                Button("lc.common.cancel".loc) {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // 每次进页都按磁盘现状重解析封面与数据包状态（两个计数器被封面条 /
            // 封面行 / 数据包行读取，bump 即重算），不依赖上一次会话的快照
            coverRefresh += 1
            statusRefresh += 1
            loadState()
        }
        // onDismiss 覆盖导入页的全部退出路径：原先刷新只挂在导入视图的
        // onFinished 上，而它仅由「完成」钮触发——用工具栏「取消」或下滑关页
        // 时状态行不重算（导入失败 / 取消同理要回到与磁盘一致的状态）。
        .sheet(item: $datapackRequest, onDismiss: {
            statusRefresh += 1
            // 导入可能伴随容器注册变化，关页后整页按磁盘重读（含偏好值）
            loadState()
        }) { request in
            LCDatapackImportView(request: request, apps: [app])
        }
        .confirmationDialog("恢复默认设置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                resetAll()
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("清掉这个游戏在库里保存的全部启动器选择，回到打包时的默认值。按键布局不受影响。")
        }
    }

    // MARK: 头部（全形态统一：应用图标行——桌面图标靠左、右侧游戏名与副标题；
    // 关闭走工具栏左上角「取消」，见 body 的 toolbar）

    private func header() -> some View {
        // 横竖屏（含横屏侧面板）统一图标头，不再用 16:9 宽封面条（用户定，
        // Phase 14 追加）：图标 62pt、圆角 14、图文间距 14，iOS 设置页规格
        HStack(spacing: 14) {
            appIconHeader
            titleBlock
        }
        .padding(.top, 8)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(app.displayName)
                .font(.title2.bold())
                .foregroundColor(LCGameTheme.creamColor)
            Text("\(knownGame?.shortName ?? app.displayName) · \(app.version) · 设置写入游戏容器，下次启动生效")
                .font(.footnote)
                .foregroundColor(.gray)
        }
    }

    /// 头部图标：游戏的桌面图标原图（与主页图标同源），62pt、圆角 14。
    /// 白边归因（Phase 16，用户 17:28 真机放大图为据）：亮边严格沿圆角
    /// 边框走、宽度均匀、下缘与右下角最亮，而图标 artwork 本身四角是
    /// 深色——不是源图方角漏出（Phase 14 的第一版判断）。主因是上一版
    /// 叠的那圈白色 strokeBorder（0.12）本身：它就是沿圆角画的一圈
    /// 白线，深色页底上处处可见，图标下半 artwork 偏亮更把它衬亮；
    /// 次因是素材边缘可能带的重采样亮边 / 垫色。本版改法：① 描边换
    /// 黑色低透明（只压边、不提亮）；② 图像过扫填充——内容放大
    /// 1.08 倍再硬裁到 62pt 圆角，素材自带的边缘垫色落在裁剪之外。
    /// 本组件是本页私有实现、非共享组件；仓内其他图标渲染（共享的
    /// IconImageView、数据包导入页 gameIcon、隐藏游戏页 iconView）
    /// 都是纯裁剪、无白色描边叠方角图标的组合，无此病，未动。
    private var appIconHeader: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Group {
            if let icon = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 62)
                    .scaleEffect(1.08)
                    .clipShape(shape)
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
                    .frame(width: 62, height: 62)
                    .clipShape(shape)
            }
        }
        .overlay {
            shape.strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
        }
    }

    // MARK: 游戏（只读信息行）

    private var datapackReady: Bool {
        _ = statusRefresh
        return LCGameLibraryInfo.isDatapackReady(container: container)
    }

    private var gameInfoSection: some View {
        sectionCard(title: "游戏") {
            Button {
                datapackRequest = LCDatapackRequest(app: app)
            } label: {
                HStack(spacing: 10) {
                    Text("数据包 romfs.img")
                        .foregroundColor(.primary)
                    Spacer()
                    Circle()
                        .fill(datapackReady ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                    Text(datapackReady ? "已就绪" : "未导入")
                        .foregroundColor(.gray)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
            Divider().background(Color.white.opacity(0.08))
            Button {
                coverMenuPresented = true
            } label: {
                HStack(spacing: 10) {
                    Text("封面图")
                        .foregroundColor(.primary)
                    Spacer()
                    coverRowThumbnail
                    Text(coverResolution.source.displayName)
                        .foregroundColor(.gray)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
            Divider().background(Color.white.opacity(0.08))
            Button {
                onOpenDataFolder()
            } label: {
                HStack {
                    Text("存档")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("在本机")
                        .foregroundColor(.gray)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: 自定义封面（来源/缩略图/选图与保存）

    /// 当前封面解析结果（来源 + 图）：读 coverRefresh 使换图后本行立即刷新
    private var coverResolution: (image: UIImage?, source: LCGameLibraryInfo.BannerSource) {
        _ = coverRefresh
        return LCGameLibraryInfo.bannerResolution(for: app.appInfo)
    }

    private var coverHasCustom: Bool {
        LCCustomCoverStore.exists(forBundleIdentifier: app.bundleIdentifier)
    }

    @ViewBuilder
    private var coverRowThumbnail: some View {
        Group {
            if let image = coverResolution.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let icon = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: 44, height: 25)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipped()
    }

    /// 选图器关掉后再呈现裁剪页（错开两个呈现，避免同帧抢呈现失败）
    private func presentCrop(for image: UIImage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            cropItem = LCCoverCropItem(image: image)
        }
    }

    private func handleCoverFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            coverErrorPresented = true
            return
        }
        presentCrop(for: image)
    }

    private func saveCroppedCover(_ cropped: UIImage) {
        do {
            try LCCustomCoverStore.save(cropped, forBundleIdentifier: app.bundleIdentifier)
            coverRefresh += 1
        } catch {
            coverErrorPresented = true
        }
    }

    private func removeCustomCover() {
        LCCustomCoverStore.remove(forBundleIdentifier: app.bundleIdentifier)
        coverRefresh += 1
    }

    // MARK: 档案分组

    private var hasSavedValues: Bool {
        guard let prefs else { return false }
        return prefs.hasLauncherValues(settings)
    }

    @ViewBuilder
    private var profileSections: some View {
        let groups = groupedSettings()
        ForEach(groups, id: \.title) { group in
            sectionCard(title: group.title) {
                ForEach(group.rows) { setting in
                    if setting.id != group.rows.first?.id {
                        Divider().background(Color.white.opacity(0.08))
                    }
                    settingRow(setting)
                    // 按键组：皮肤行之后紧跟按键布局入口（与预览一致）
                    if group.title == "按键", setting.env == knownGame?.skinEnv, let prefs, let knownGame {
                        Divider().background(Color.white.opacity(0.08))
                        padLayoutRow(prefs: prefs, knownGame: knownGame)
                    }
                }
                // 按键组没有皮肤行（或皮肤行不在本组）时，布局入口挂在组尾
                if group.title == "按键", !group.rows.contains(where: { $0.env == knownGame?.skinEnv }),
                   let prefs, let knownGame {
                    if !group.rows.isEmpty {
                        Divider().background(Color.white.opacity(0.08))
                    }
                    padLayoutRow(prefs: prefs, knownGame: knownGame)
                }
            }
        }
    }

    /// 档案分组 → 预览分组：Game 显示 / Controls 按键 / Performance 性能；
    /// 按键组内皮肤行排最前，其余行保持档案顺序；needs 不满足的行隐藏
    private func groupedSettings() -> [(title: String, rows: [LCLauncherSetting])] {
        let titles: [(String, String)] = [("Game", "显示"), ("Controls", "按键"), ("Performance", "性能")]
        var result: [(title: String, rows: [LCLauncherSetting])] = []
        for (rawSection, title) in titles {
            var rows = settings.filter { $0.section == rawSection && isVisible($0) }
            if rawSection == "Controls", let skinEnv = knownGame?.skinEnv,
               let i = rows.firstIndex(where: { $0.env == skinEnv }) {
                let skin = rows.remove(at: i)
                rows.insert(skin, at: 0)
            }
            if !rows.isEmpty {
                result.append((title: title, rows: rows))
            }
        }
        // 档案里未认得的分组原样排在最后
        let knownSections = Set(titles.map { $0.0 })
        for section in settings.map({ $0.section }).filter({ !knownSections.contains($0) }) {
            let rows = settings.filter { $0.section == section && isVisible($0) }
            if !rows.isEmpty && !result.contains(where: { $0.title == section }) {
                result.append((title: section, rows: rows))
            }
        }
        return result
    }

    private func isVisible(_ setting: LCLauncherSetting) -> Bool {
        guard let needs = setting.needs, let eq = needs.firstIndex(of: "=") else { return true }
        let key = String(needs[..<eq])
        let want = String(needs[needs.index(after: eq)...])
        guard let current = currentValues[key] else { return true }
        return current == want
    }

    // MARK: 行

    @ViewBuilder
    private func settingRow(_ setting: LCLauncherSetting) -> some View {
        let locked = lockedValues[setting.env] != nil
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(setting.label)
                    .foregroundColor(.primary)
                Spacer()
                rowControl(setting, locked: locked)
            }
            if !setting.note.isEmpty || locked {
                Text(locked ? "由 env 文件固定，在这里改不了" : setting.note)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rowControl(_ setting: LCLauncherSetting, locked: Bool) -> some View {
        let value = currentValues[setting.env] ?? setting.defaultValue
        switch setting.kind {
        case "choice":
            Menu {
                ForEach(setting.options, id: \.value) { option in
                    Button {
                        apply(setting, option.value)
                    } label: {
                        if option.value == value {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(setting.optionLabel(for: value))
                        .foregroundColor(locked ? .gray : LCGameTheme.creamColor)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .disabled(locked)
        case "toggle":
            Toggle("", isOn: Binding(
                get: { value == setting.onValue },
                set: { apply(setting, $0 ? setting.onValue : setting.offValue) }
            ))
            .labelsHidden()
            .disabled(locked)
        case "range":
            HStack(spacing: 12) {
                Button {
                    stepRange(setting, by: -1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                Text(LCLauncherSetting.formatRange(Double(value) ?? setting.minValue))
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 44)
                Button {
                    stepRange(setting, by: 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(locked ? .gray : LCGameTheme.creamColor)
            .disabled(locked)
        default:
            Text(value)
                .foregroundColor(.gray)
        }
    }

    private func padLayoutRow(prefs: LCGamePrefs, knownGame: LCKnownGame) -> some View {
        NavigationLink {
            LCPadLayoutEditorView(
                game: knownGame.padLayoutGame,
                prefs: prefs,
                bundlePath: app.appInfo.bundlePath(),
                bannerImage: LCGameLibraryInfo.bannerImage(for: app.appInfo),
                skinValue: skinInt(for: knownGame)
            )
        } label: {
            HStack {
                Text("按键布局")
                    .foregroundColor(.primary)
                Spacer()
                Text("调整")
                    .foregroundColor(.gray)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
        }
    }

    private func skinInt(for knownGame: LCKnownGame) -> Int {
        if let raw = currentValues[knownGame.skinEnv] ?? prefs?.launcherValue(knownGame.skinEnv) {
            return Int(raw) ?? 1
        }
        return 1 // 引擎里皮肤未保存时的默认：丝之歌 1（荆棘）、哈迪斯 1（月亮）
    }

    private var resetRow: some View {
        Button(role: .destructive) {
            confirmReset = true
        } label: {
            Text("恢复默认设置")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .background(Self.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: 高级与提示

    private var advancedSection: some View {
        sectionCard(title: "高级") {
            NavigationLink {
                LCAppSettingsView(model: app)
            } label: {
                HStack {
                    Text("容器与高级设置")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("LiveContainer")
                        .foregroundColor(.gray)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    private var noProfileHint: some View {
        sectionCard(title: "游戏设置") {
            Text("该游戏暂无内置档案，请进游戏内启动器调整。")
                .foregroundColor(.gray)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noContainerHint: some View {
        sectionCard(title: "游戏设置") {
            Text("这个游戏还没有数据容器：先启动一次游戏，容器生成后回到这里即可调整设置。")
                .foregroundColor(.gray)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerNote: some View {
        Text("改动写进这个游戏在容器里的数据文件夹（偏好与存档同一处），和游戏内启动器、按键编辑器共用一份，互通。游戏运行时请先退出再改。")
            .font(.caption)
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 分组卡片

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.bold())
                .foregroundColor(.gray)
                .padding(.leading, 4)
            VStack(spacing: 10) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Self.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: 状态装载与写入

    private func loadState() {
        // 先把模型里的容器选择对齐到 appInfo 当前记录，再按对齐后的容器读盘：
        // 客体启动器写偏好走的是被启动容器的 plist，读侧容器若停在模型创建时的
        // 快照上，就会整页读旧容器的值（客体改了 120、这里还显示 60）。
        app.refreshContainerSelection()
        let loaded = LCGameProfile.loadSettings(app: app)
        settings = loaded ?? []
        hasProfile = loaded != nil
        lockedValues = LCGameProfile.envLockedValues(app: app, container: container)
        if let container {
            let p = LCGamePrefs(container: container, bundleIdentifier: app.bundleIdentifier)
            prefs = p
            var values: [String: String] = [:]
            for setting in settings {
                if let locked = lockedValues[setting.env] {
                    values[setting.env] = setting.accepts(locked) ? locked : setting.defaultValue
                } else if let saved = p.launcherValue(setting.env), setting.accepts(saved) {
                    values[setting.env] = saved
                } else {
                    values[setting.env] = setting.defaultValue
                }
            }
            currentValues = values
        } else {
            prefs = nil
            currentValues = [:]
        }
    }

    private func apply(_ setting: LCLauncherSetting, _ value: String) {
        guard let prefs, lockedValues[setting.env] == nil else { return }
        prefs.setLauncherValue(setting, to: value)
        currentValues[setting.env] = value
    }

    private func stepRange(_ setting: LCLauncherSetting, by direction: Double) {
        let current = Double(currentValues[setting.env] ?? setting.defaultValue) ?? setting.minValue
        let next = min(max(current + direction * setting.stepValue, setting.minValue), setting.maxValue)
        // 浮点步进对齐，避免 0.30000000004 之类的值落盘
        let aligned = (next / setting.stepValue).rounded() * setting.stepValue
        apply(setting, LCLauncherSetting.formatRange(aligned))
    }

    private func resetAll() {
        guard let prefs else { return }
        prefs.resetLauncherValues(settings)
        var values = currentValues
        for setting in settings where lockedValues[setting.env] == nil {
            values[setting.env] = setting.defaultValue
        }
        currentValues = values
    }
}
