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

struct LCGameSettingsView: View {
    @ObservedObject var app: LCAppModel
    var onRun: () -> Void
    var onOpenDataFolder: () -> Void
    /// 关闭本页回到游戏库：本页是被列表用隐藏 NavigationLink 推进来的，
    /// 只能走列表的 closeNavigationView 弹出，presentationMode.dismiss() 对 push 无效。
    var onClose: () -> Void

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

    private static let cardBackground = Color(red: 0.118, green: 0.118, blue: 0.129)
    private static let pageBackground = Color(red: 0.055, green: 0.055, blue: 0.059)
    private static let accentColor = Color(red: 0.788, green: 0.373, blue: 0.263)

    private var knownGame: LCKnownGame? {
        LCKnownGame.from(bundleIdentifier: app.bundleIdentifier)
    }

    private var container: LCContainer? {
        LCGameLibraryInfo.defaultContainer(for: app)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                gameInfoSection
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
            .padding(.horizontal, 16)
            // 底部留白 ≥ 浮动底栏胶囊高度 + 间距：即使底栏未隐藏，最后一行也能滚到胶囊上方
            .padding(.bottom, 110)
        }
        .hideTabBarOnPush()
        .background(Self.pageBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarHidden(true)
        .onAppear {
            loadState()
        }
        .sheet(item: $datapackRequest) { request in
            LCDatapackImportView(request: request, apps: [app]) {
                statusRefresh += 1
            }
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

    // MARK: 头部（预览：‹ 游戏库 胶囊 + 启动胶囊 + 封面条 + 标题与副标题）

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    onClose()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.footnote.bold())
                        Text("游戏库")
                    }
                    .foregroundColor(LCGameTheme.creamColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                Spacer()
                Button {
                    // 先退回游戏库再启动：启动流程要用的 JIT 确认 sheet 与错误弹窗都挂在
                    // 列表视图上，本页盖在上面时它们弹不出来，启动会无声卡住；
                    // 退回列表后与点卡片「启动」走完全同一条路。
                    onClose()
                    onRun()
                } label: {
                    Text("启动")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 9)
                        .background(Self.accentColor)
                        .clipShape(Capsule())
                }
                .disabled(app.isAppRunning)
            }
            coverStrip
            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName)
                    .font(.title2.bold())
                    .foregroundColor(LCGameTheme.creamColor)
                Text("\(knownGame?.shortName ?? app.displayName) · \(app.version) · 设置写入游戏容器，下次启动生效")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var coverStrip: some View {
        Group {
            if let banner = LCGameLibraryInfo.bannerImage(for: app.appInfo) {
                Image(uiImage: banner)
                    .resizable()
                    .scaledToFill()
            } else if let icon = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                ZStack {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 24)
                        .opacity(0.75)
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                }
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipped()
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
