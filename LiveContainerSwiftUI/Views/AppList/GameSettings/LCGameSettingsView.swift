//
//  LCGameSettingsView.swift
//  LiveContainerSwiftUI
//
//  每游戏设置页：改动写进这个游戏在容器里的偏好 plist，与游戏内启动器、
//  按键编辑器共用一份，下次启动生效。档案由 LCGameProfile 从客体自带的
//  dm/launcher.json 解析（纯镜像），没有档案的游戏给通用提示。
//
//  Phase 17（用户 2026-11-05 定：游戏设置页全部照搬 NX2 壳）：本页呈现层
//  逐项镜像 NX 壳每游戏设置页（ShellUI 的 PaneBanner / GameDetailView /
//  SettingControl / SegmentedChoice / CreamToggleStyle / RangeControl）：
//  大封面头 + 左下信息簇、左上浮排「‹ 游戏库」胶囊（ChipButtonStyle）、
//  选项类分段控件（2–4 项且放得下时）、奶油开关、滑杆行、分组卡与分隔。
//  数据与语义仍是 LC 的：头部状态/胶囊走数据包状态，胶囊仅缺包时出现
//  （「导入数据包…」），不加开始游戏；写路径（LCGamePrefs）零改。
//  NX 独有内容（选数据文件夹 / 云存档 / 删除游戏）不搬；LC 独有行
//  （数据包 / 封面图 / 存档 / 高级 / 恢复默认）保留功能、
//  按 NX 的行语言排。字型：NX 用 Manrope，本页用系统字体同字号/字重代。
//  按键布局入口已临时下架（Phase 21）：编辑页与布局数据留在仓里，
//  后续调整好再恢复入口；已保存的自定义布局仍由客体引擎读取生效。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 裁剪页呈现载荷（fullScreenCover item）
private struct LCCoverCropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// NX ShellPalette 的逐值移植（Phase 17）：页底 / 卡面 / 奶油 / 就绪绿 /
/// 注意琥珀 / 发丝线。LCGameTheme 的奶油色是近似值，本页照搬后统一用这里。
private enum LCNXColor {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
    static let attention = Color(red: 1, green: 0.78, blue: 0.24)
    static let hairline = Color.white.opacity(0.08)
}

/// NX ChipButtonStyle 移植：「‹ 游戏库」深色胶囊（ultraThinMaterial 叠
/// 黑 0.5、按下 0.62，白 0.14 描边，强制暗色环境渲染材质）
private struct LCNXChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundColor(.white)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.62 : 0.5))
                }
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// NX PrimaryPillStyle 移植：奶油底黑字大胶囊（bold 17、minHeight 50、
/// 横向内距 26，按下 opacity 0.78 + scale 0.98）
private struct LCNXPrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 26)
            .frame(minHeight: 50)
            .foregroundColor(.black)
            .background(LCNXColor.cream, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// NX ShellButtonStyle(fills: true) 移植：满宽浅底钮（14 semibold、
/// minHeight 44、白 0.055 底——按下 0.13、圆角 9、白 0.10 描边）
private struct LCNXShellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(.white)
            .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.055),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
    }
}

/// NX CreamSwitch 移植：46×28 奶油轨开关。NX 用本地 shown 态驱动钮位
/// 动画（外部值变化时 onChange 同步），本版同法；动画曲线 NX 为
/// .snappy（iOS 17+），部署目标 iOS 15，用等效 spring 代（报告注明）。
private struct LCCreamSwitch: View {
    let isOn: Bool
    var onToggle: (Bool) -> Void
    @State private var shown: Bool?

    private var displayOn: Bool { shown ?? isOn }

    var body: some View {
        Button {
            let target = !displayOn
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                shown = target
            }
            onToggle(target)
        } label: {
            ZStack(alignment: displayOn ? .trailing : .leading) {
                Capsule()
                    .fill(displayOn ? LCNXColor.cream : Color.white.opacity(0.14))
                    .frame(width: 46, height: 28)
                Circle()
                    .fill(displayOn ? LCNXColor.background : Color.white.opacity(0.85))
                    .padding(3)
                    .frame(width: 28, height: 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: isOn) { newValue in
            shown = newValue
        }
    }
}

/// NX 的 choice 行移植（SettingControl + SegmentedChoice + ChoiceValueRow）：
/// 选项 2–4 个且每个标签在等宽段内放得下（按 NX 的判定式，字宽用
/// UIFont 实测代入）→ 分段条；否则整行值选择器（LC 既有 Menu 承载）。
/// 行宽与 NX SettingControl 同法：背景 GeometryReader 实测进 @State。
private struct LCChoiceRow: View {
    let setting: LCLauncherSetting
    let currentValue: String
    let locked: Bool
    var onPick: (String) -> Void
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        Group {
            if useSegments {
                VStack(alignment: .leading, spacing: 12) {
                    labelBlock
                    segmentedBar
                }
            } else {
                Menu {
                    ForEach(setting.options, id: \.value) { option in
                        Button {
                            onPick(option.value)
                        } label: {
                            if option.value == currentValue {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    valueRow
                }
            }
        }
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { rowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { rowWidth = $0 }
            }
        }
    }

    /// NX SettingControl.label：标题 15 medium + 说明 12.5 白 0.5，spacing 4
    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            if locked || !setting.note.isEmpty {
                Text(locked ? "由 env 文件固定，在这里改不了" : setting.note)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// NX 的分段判定（ChoicePresentation）：2–4 段，且最宽标签
    /// （13.5 bold 实测字宽 + 左右内距 28）不超过等宽段宽
    private var useSegments: Bool {
        let options = setting.options
        guard (2...4).contains(options.count), rowWidth > 0 else { return false }
        let segmentWidth = (rowWidth - 6 - 2 * CGFloat(options.count - 1)) / CGFloat(options.count)
        let font = UIFont.systemFont(ofSize: 13.5, weight: .bold)
        return options.allSatisfy { option in
            (option.label as NSString).size(withAttributes: [.font: font]).width + 28 <= segmentWidth
        }
    }

    /// NX SegmentedChoice：轨道 padding 3、白 0.055、圆角 11、白 0.08
    /// 描边；段间距 2 等宽，字 13.5（选中 bold 黑字奶油底圆角 8，
    /// 未选 medium 白 0.75），段 minHeight 40、横向内距 14。
    /// 等宽用 HStack + maxWidth .infinity（NX 的 EqualRow 是 iOS 16
    /// Layout 协议，部署目标 iOS 15 不可用，报告注明）。
    private var segmentedBar: some View {
        HStack(spacing: 2) {
            ForEach(setting.options, id: \.value) { option in
                let chosen = option.value == currentValue
                Button {
                    onPick(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 13.5, weight: chosen ? .bold : .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundColor(chosen ? .black : .white.opacity(0.75))
                        .background(chosen ? LCNXColor.cream : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    /// NX ChoiceValueRow：整行浅底（白 0.055、圆角 11、白 0.08 描边、
    /// 内距横 14 纵 8、minHeight 48），值 14.5 semibold 奶油右置，
    /// chevron 13 bold 白 0.4
    private var valueRow: some View {
        HStack(spacing: 12) {
            labelBlock
            Text(setting.optionLabel(for: currentValue))
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundColor(LCNXColor.cream)
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

struct LCGameSettingsView: View {
    @ObservedObject var app: LCAppModel
    var onOpenDataFolder: () -> Void
    /// 横屏侧面板呈现时的关闭回调（Phase 14，列表层注入）：面板不是
    /// 系统呈现，dismiss 环境无效，关闭走此回调；nil = sheet 呈现，
    /// 「‹ 游戏库」钮用 dismiss 环境关闭（列表层包 NavigationView 供
    /// 页内子页推进），与原来一致。
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

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
    @State private var headerWidth: CGFloat = 0 // 封面头实测宽（NX PaneBanner 同法，背景 GeometryReader 回填）

    // 自定义封面流程（选图 → 16:9 裁剪 → 存宿主 Documents/CustomCovers）
    @State private var coverRefresh = 0 // 换/删自定义封面后 bump，刷新本页封面头与封面行
    @State private var coverMenuPresented = false
    @State private var photoPickerPresented = false
    @State private var filePickerPresented = false
    @State private var cropItem: LCCoverCropItem?
    @State private var coverErrorPresented = false

    private static let pageBackground = Color(red: 0.055, green: 0.055, blue: 0.059)

    private var knownGame: LCKnownGame? {
        LCKnownGame.from(bundleIdentifier: app.bundleIdentifier)
    }

    private var container: LCContainer? {
        LCGameLibraryInfo.defaultContainer(for: app)
    }

    var body: some View {
        // 版式（Phase 17 照搬 NX settingsPane）：ScrollView 顶格放封面头
        // （出血到页/面板边缘），其下内容列横向 24、上 18、下 32、块距 30；
        // 「‹ 游戏库」胶囊浮排在封面左上（NX 返回钮排法：leading 16、
        // top 6），导航栏隐藏（Phase 16 的工具栏标题删除后，本轮连
        // 工具栏一并撤掉，关闭动作只剩这颗浮排钮 + 下滑关 sheet）。
        // 横屏 640 收窄仍由 LCSettingsColumn 在根层给 ScrollView 本体
        // 定宽居中（视口层，见 LCSettingsColumn.swift 注释），头部与
        // 内容列同在列内，宽随列宽。
        LCSettingsColumn { _ in
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    coverHeader
                        .fullScreenCover(item: $cropItem) { item in
                            NavigationView {
                                LCCoverCropView(image: item.image) { cropped in
                                    saveCroppedCover(cropped)
                                }
                            }
                        }
                    VStack(alignment: .leading, spacing: 30) {
                        detailLead
                        if !hasProfile {
                            noProfileHint
                        } else if prefs == nil {
                            noContainerHint
                        } else {
                            profileSections
                        }
                        gameInfoSection
                            .confirmationDialog("封面图", isPresented: $coverMenuPresented, titleVisibility: .visible) {
                                Button("从相册选择") { photoPickerPresented = true }
                                Button("从文件选择") { filePickerPresented = true }
                                if coverHasCustom || coverHasFetched {
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
                        if hasProfile, prefs != nil, hasSavedValues {
                            resetRow
                        }
                        advancedSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }
            Button {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            } label: {
                Label("游戏库", systemImage: "chevron.left")
            }
            .buttonStyle(LCNXChipButtonStyle())
            .padding(.leading, 16)
            .padding(.top, 6)
        }
        .navigationBarHidden(true)
        }
        .background(Self.pageBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            // 每次进页都按磁盘现状重解析封面与数据包状态（两个计数器被封面头 /
            // 封面行 / 数据包行读取，bump 即重算），不依赖上一次会话的快照
            coverRefresh += 1
            statusRefresh += 1
            loadState()
            // 联网封面懒抓（Phase 19）：展示时无缓存、无负缓存则补抓一次，
            // 成功回调 bump 本页 coverRefresh，封面头与封面行即时换上新图
            LCCoverFetchService.shared.ensureFetched(appInfo: app.appInfo) {
                self.coverRefresh += 1
            }
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

    // MARK: 封面头（NX PaneBanner 移植）

    /// 头部高度与 topInset（Phase 26 按 NX 原式找回）：NX 的头部顶
    /// 在物理顶（ScrollView 忽略安全区），bannerHeight = 有横图
    /// min(宽×9/16, 220) + topInset、无横图 topInset + 64，信息簇以
    /// padding.top = bannerHeight − 22 压在图下缘——topInset 项的作
    /// 用是让整幅图与簇一起下移，簇相对安全区的位置不变。
    /// LC 的坐标系不同：头部布局顶在安全线（外包 NavigationView
    /// 把设备顶部安全区还给内容），簇的布局公式（padding.top =
    /// min(宽×9/16, 220) − 22 / 无横图 64）与既有逐点一致、簇与
    /// 「‹ 游戏库」钮相对安全区的位置都不动；NX 的 +topInset 在此
    /// 坐标系里等价于「只把背景层向上出血 topInset」——背景帧扩到
    /// 物理顶后，底图的总高（帧高 + 160 溢出）与 NX 逐点相同（图
    /// 顶同为物理顶、图高同为 bannerHeight − 22 + 簇高 + 160）。
    /// 切勿把 topInset 加进布局公式：那会让簇在安全线之下再下移
    /// 一整段（双算）。
    /// topInset 取窗口顶部安全区真值（LCSidePanelSpec
    /// .windowTopSafeInset），逐次求值现读：竖屏为设备值（59）、
    /// 手机横屏状态栏隐藏时为 0，旋转后即为新方向的值，两形态
    /// 同式、不残留。封面走既有解析链（自定义 → 客体横版图 →
    /// 内置原画 → 联网获取 → 图标）；来源为图标时按 NX 无横图
    /// 路：图标自体模糊底 + 96×96 缩略图。
    private var coverHeader: some View {
        let resolution = coverResolution
        let hasBanner = resolution.source != .icon
        let width = headerWidth > 0 ? headerWidth : 430
        let bannerHeight = hasBanner ? min(width * 9 / 16, 220) : 64.0
        let topInset = LCSidePanelSpec.windowTopSafeInset
        return ZStack(alignment: .bottomLeading) {
            headerCluster(hasBanner: hasBanner, image: resolution.image, wide: width >= 560)
                .padding(.horizontal, 24)
                .padding(.top, bannerHeight - (hasBanner ? 22 : 0))
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .background {
            // 背景层向上出血到物理顶（布局帧不动）：底图的图顶与
            // scrim 随之落在状态栏之下，封面铺满到屏幕顶缘
            headerBackdrop(image: resolution.image, hasBanner: hasBanner, topInset: topInset)
                .ignoresSafeArea(edges: .top)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { headerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { headerWidth = $0 }
            }
        }
    }

    /// 信息簇的排布（NX PaneBanner.words / cluster）：有横图 = 仅信息簇；
    /// 无横图 = 宽 ≥560 时缩略图与信息簇 HStack(bottom, spacing 22)，
    /// 否则 VStack(leading, spacing 16) 上下排。
    @ViewBuilder
    private func headerCluster(hasBanner: Bool, image: UIImage?, wide: Bool) -> some View {
        if hasBanner {
            headerWords
        } else if wide {
            HStack(alignment: .bottom, spacing: 22) {
                headerThumbnail(image: image)
                headerWords
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                headerThumbnail(image: image)
                headerWords
            }
        }
    }

    /// 左下信息簇（NX PaneBanner.words）：状态行（7pt 圆点 + eyebrow
    /// 大写粗字，状态色）/ 大标题（heavy 26、tracking −0.6、限 2 行，
    /// ZStack 内藏隐藏「M\nM」预留两行高）/ 副行（「游戏设置」分组
    /// 小题 + 版本 note），簇内 spacing 8、副行 padding.top 2。
    /// 文案是 LC 语义：状态 ← 数据包状态，副行 ← 版本。
    private var headerWords: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(datapackReady ? LCNXColor.ready : LCNXColor.attention)
                    .frame(width: 7, height: 7)
                Text(datapackReady ? "随时可玩" : "需要导入数据包")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.3)
                    .foregroundColor(datapackReady ? LCNXColor.ready : LCNXColor.attention)
            }
            ZStack(alignment: .bottomLeading) {
                Text("M\nM")
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.6)
                    .hidden()
                Text(app.displayName)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("游戏设置")
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundColor(LCNXColor.cream.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("版本 \(app.version)")
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.top, 2)
        }
    }

    /// NX CoverThumbnail 移植：96×96、圆角 18、白 0.14 描边、
    /// 阴影 black 0.4 / radius 16 / y 6
    private func headerThumbnail(image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let icon = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    /// NX PaneBanner.background 移植：底图按头部实高 +160 绘制（向下
    /// 溢出垫进内容区）、整体罩 NX 的渐隐 mask。有横图：原图 +
    /// 压暗渐变（clear@0.3 → 黑 0.4@0.6 → 黑 0.55@1）；无横图：
    /// 图标自体放大 1.4 + blur 40 + saturation 1.2 + 黑 0.38 叠加。
    /// mask stops：黑@0 / 黑@0.45 / 黑 0.55@0.68 / 黑 0.18@0.85 / clear@1。
    /// 状态栏 scrim（Phase 26 补回，NX 原规格）：叠在图层之上、mask
    /// 之内，topInset > 0 时黑 0.5 → clear、高 topInset + 50，锚在
    /// 图顶（背景帧已出血到物理顶）——亮封面下状态栏的时钟与电量
    /// 靠它保可读；NX 结构里此 overlay 盖在图层组全体之上，有 /
    /// 无横图都生效。
    @ViewBuilder
    private func headerBackdrop(image: UIImage?, hasBanner: Bool, topInset: CGFloat) -> some View {
        GeometryReader { geo in
            Group {
                if hasBanner, let image {
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height + 160)
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0.3),
                            .init(color: .black.opacity(0.4), location: 0.6),
                            .init(color: .black.opacity(0.55), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                        .frame(width: geo.size.width, height: geo.size.height + 160)
                    }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height + 160)
                        .scaleEffect(1.4)
                        .blur(radius: 40)
                        .saturation(1.2)
                        .overlay(Color.black.opacity(0.38))
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height + 160, alignment: .top)
            .overlay(alignment: .top) {
                if topInset > 0 {
                    LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: topInset + 50)
                }
            }
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.45),
                .init(color: .black.opacity(0.55), location: 0.68),
                .init(color: .black.opacity(0.18), location: 0.85),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: 头部以下（NX GameDetailView 的头部块与分组）

    /// NX GameDetailView 头部块：说明行（14、白 0.72）+ 状态动作；
    /// LC 语义——说明行固定文案，动作胶囊仅缺数据包时出现
    /// （PrimaryPillStyle + folder 图标，走既有数据包导入流程），
    /// 已就绪时无胶囊；不加开始游戏（用户早前已把启动撤出设置页）。
    private var detailLead: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置写入游戏容器，下次启动生效")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.72))
            if !datapackReady {
                Button {
                    datapackRequest = LCDatapackRequest(app: app)
                } label: {
                    Label("导入数据包…", systemImage: "folder")
                }
                .buttonStyle(LCNXPrimaryPillStyle())
            }
        }
    }

    /// NX 导航行语言（LC 独有行适配用）：标签 15 medium 白、值 14.5
    /// semibold 奶油（或 note 12.5 白 0.5）、chevron.right 13 bold
    /// 白 0.4、行 minHeight 48
    private func navRow<Value: View>(label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            Spacer(minLength: 8)
            value()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    /// NX 组内分隔：白 0.06、高 1
    private var nxDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: 游戏（LC 独有组：NX 无对应，按 NX 行语言适配）

    private var datapackReady: Bool {
        _ = statusRefresh
        return LCGameLibraryInfo.isDatapackReady(container: container)
    }

    private var gameInfoSection: some View {
        sectionCard(title: "游戏") {
            Button {
                datapackRequest = LCDatapackRequest(app: app)
            } label: {
                navRow(label: "数据包 romfs.img") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(datapackReady ? LCNXColor.ready : LCNXColor.attention)
                            .frame(width: 7, height: 7)
                        Text(datapackReady ? "已就绪" : "未导入")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(datapackReady ? LCNXColor.ready : LCNXColor.attention)
                    }
                }
            }
            .buttonStyle(.plain)
            nxDivider
            Button {
                coverMenuPresented = true
            } label: {
                navRow(label: "封面图") {
                    coverRowThumbnail
                    Text(coverResolution.source.displayName)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(LCNXColor.cream)
                }
            }
            .buttonStyle(.plain)
            nxDivider
            Button {
                onOpenDataFolder()
            } label: {
                navRow(label: "存档") {
                    Text("在本机")
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
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

    private var coverHasFetched: Bool {
        LCFetchedCoverStore.exists(forBundleIdentifier: app.bundleIdentifier)
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
        // 恢复默认连联网抓取缓存一并删，并清掉负缓存记录——删完之后
        // 主页 / 设置页再次展示时允许重新抓（Phase 19）
        LCFetchedCoverStore.remove(forBundleIdentifier: app.bundleIdentifier)
        LCCoverFetchService.shared.clearNegativeCache(forBundleIdentifier: app.bundleIdentifier)
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
                        nxDivider
                    }
                    settingRow(setting)
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

    // MARK: 行（NX SettingControl 三种控件形态）

    /// NX SettingControl.label：标题在上、说明在下（15 medium /
    /// 12.5 白 0.5，spacing 4），toggle 与 range 共用
    private func settingLabelBlock(_ setting: LCLauncherSetting, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(setting.label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            if locked || !setting.note.isEmpty {
                Text(locked ? "由 env 文件固定，在这里改不了" : setting.note)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func settingRow(_ setting: LCLauncherSetting) -> some View {
        let locked = lockedValues[setting.env] != nil
        let value = currentValues[setting.env] ?? setting.defaultValue
        switch setting.kind {
        case "choice":
            LCChoiceRow(setting: setting, currentValue: value, locked: locked) { newValue in
                apply(setting, newValue)
            }
        case "toggle":
            // NX CreamToggleStyle：标签占满左、奶油开关右，行 minHeight 44
            HStack(alignment: .center, spacing: 16) {
                settingLabelBlock(setting, locked: locked)
                LCCreamSwitch(isOn: value == setting.onValue) { isOn in
                    apply(setting, isOn ? setting.onValue : setting.offValue)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(locked)
            .opacity(locked ? 0.45 : 1)
        case "range":
            rangeRow(setting, locked: locked, value: value)
        default:
            HStack(spacing: 10) {
                settingLabelBlock(setting, locked: locked)
                Text(value)
                    .foregroundColor(.gray)
            }
        }
    }

    /// NX RangeControl：行 1 = 标签块 + 值（15 bold 奶油、等宽数字）基线
    /// 对齐；行 2 = minus 圆钮 44 + Slider（tint 奶油、minHeight 44）+
    /// plus 圆钮 44（圆钮白 0.055 底、白 0.10 描边、符号 14 semibold）。
    /// 写值仍走既有 apply / stepRange（步进对齐不变）。
    private func rangeRow(_ setting: LCLauncherSetting, locked: Bool, value: String) -> some View {
        let raw = Double(value) ?? setting.minValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                settingLabelBlock(setting, locked: locked)
                Text(LCLauncherSetting.formatRange(raw))
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(LCNXColor.cream)
            }
            HStack(spacing: 10) {
                rangeStepButton("minus", setting: setting, direction: -1)
                Slider(
                    value: Binding(
                        get: { raw },
                        set: { apply(setting, LCLauncherSetting.formatRange($0)) }
                    ),
                    in: setting.minValue...setting.maxValue,
                    step: setting.stepValue
                )
                .tint(LCNXColor.cream)
                .frame(minHeight: 44)
                rangeStepButton("plus", setting: setting, direction: 1)
            }
        }
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
    }

    private func rangeStepButton(_ symbol: String, setting: LCLauncherSetting, direction: Double) -> some View {
        Button {
            stepRange(setting, by: direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.055), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    /// NX 的恢复默认块（ShellButtonStyle fills + 其下注文 12.5 白 0.45，
    /// spacing 10）移植；确认对话框沿用既有（body 的 confirmationDialog）
    private var resetRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                confirmReset = true
            } label: {
                Text("恢复默认设置")
            }
            .buttonStyle(LCNXShellButtonStyle())
            Text("清掉这个游戏在库里保存的全部启动器选择，回到打包时的默认值。按键布局不受影响。")
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    // MARK: 高级与提示（LC 独有，按 NX 行/文语言适配）

    private var advancedSection: some View {
        sectionCard(title: "高级") {
            NavigationLink {
                LCAppSettingsView(model: app)
            } label: {
                navRow(label: "容器与高级设置") {
                    Text("LiveContainer")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(LCNXColor.cream)
                }
            }
        }
    }

    private var noProfileHint: some View {
        sectionCard(title: "游戏设置") {
            Text("该游戏暂无内置档案，请进游戏内启动器调整。")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var noContainerHint: some View {
        sectionCard(title: "游戏设置") {
            Text("这个游戏还没有数据容器：先启动一次游戏，容器生成后回到这里即可调整设置。")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 分组卡片（NX SettingsGroup + shellCard 移植）

    /// 分组小题（SectionHeading：11.5 semibold、tracking 1.6、奶油 0.72、
    /// 大写）+ 卡（内容 spacing 14、padding 18、surface 底、圆角 16、
    /// hairline 描边 1pt）；组内行间分隔由调用方插入 nxDivider。
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(LCNXColor.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(LCNXColor.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(LCNXColor.hairline, lineWidth: 1)
            }
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
