//
//  LCSidePanel.swift
//  LiveContainerSwiftUI
//
//  横屏右侧抽屉面板呈现（NX2Apple 壳真形态，规格真源 = NX2Apple
//  frontend-ios/Sources/ShellUI/LibraryView.swift 的 ShellLayout 与三处
//  overlay 呈现代码；Phase 10/12 把 maxWidth:640 误读成「横屏居中列」，
//  640 其实只是面板内部内容列的上限——面板本体另有宽度规则，见下）。
//
//  NX 规格摘录（出处 LibraryView.swift，行号以 NX2Apple 仓为准）：
//  - 布局判定（:5-16）：regular = 宽 ≥600 且高 ≥500；宽 > 高×1.2 为
//    coverFlow。设置在库留在身后时浮动成面板（settingsFloat，:28）：
//    布局非 column 且屏宽 ≥ 面板宽 + 120，否则设置整屏。
//  - 面板宽（overlayWidth :19、:22-25 与 paneWidth :29）：上限 520；
//    coverFlow 且非 regular（手机横屏）时 min(520, 屏宽×0.44)——用户
//    真机截图里 ≈44% 屏宽即此式；最终宽 = min(屏宽, 上限)。
//  - 呈现（每游戏设置 :131-160，手柄 :188-201，壳设置 :202-215）：
//    面板贴右、全高、页底色（ShellPalette.background = (0.055,0.055,
//    0.06)，ShellStyle.swift:5）铺满至屏幕边缘，左缘一条 1pt 发丝线
//    （hairline = 白 0.08，ShellStyle.swift:12）朝向库一侧；无圆角、
//    无阴影（圆角 26 + 阴影只属于帮助/删除的居中卡片）。左侧库被
//    黑 0.55 压暗且不可交互，点压暗区关闭；进出动画 .smooth 0.3s
//    （LC 部署目标 iOS 15 无 .smooth，用 Phase 11 已定的同曲线
//    timingCurve(0.22, 0.61, 0.36, 1) 代替）；另有左缘右滑拖动关闭
//    （EdgeSwipeBack :271-279 + finishEdgeSwipe :405-413：拖过面板
//    1/3 或速度 >600 即关闭）。
//  - 面板内头部与内容：壳设置 = 页题 + 「完成」胶囊钮同排、内容
//    padding 24、分组间距 30（ShellSettingsView.swift:72-121）；
//    每游戏设置 = 封面条横幅 + 左上返回胶囊钮（LibraryView.swift
//    :337-377）。两者的内容列都另有 .frame(maxWidth: 640)——面板宽
//    ≤520 恒小于 640，该上限在面板内永不生效，只在同页整屏铺开时
//    封顶。这正是 Phase 12 的 LCSettingsColumn 在面板内必须退化为
//    全宽的原因（见 LCSettingsColumn 的 lcInSidePanel 处理）。
//
//  LC 落点：仅横屏（呈现层宽 > 高）时，游戏设置 / 容器设置 / 手柄
//  三页改走本容器（宿主 ZStack 内的覆盖层，主页留在后面被压暗、
//  不可交互）；竖屏仍走原 .sheet，本容器不参与。关闭方式（横屏）：
//  页内「取消 / 关闭」钮（页面经 onClose 注入回调）、点压暗区、
//  在压暗区上右滑拖动（面板跟随、过 1/3 或甩动关闭后松手）——与
//  NX 的点压暗 + 左缘右滑等价；sheet 的下滑关闭在面板形态下无
//  对应手势。页面内部再呈的 sheet / fullScreenCover（数据包导入、
//  封面裁剪等）仍是系统呈现、盖在面板之上，与竖屏时一致。
//
//  Phase 22（呈现形态随旋转跟随）：Phase 14 的「按打开时方向分轨」
//  在真机被证伪——竖屏以 .sheet 打开设置后旋转到横屏，sheet 是
//  UIKit 模态、终身铺满整屏，变不回右侧面板（反向因 paneWidth 的
//  「留不出 120 即整屏宽」规则自然退化、看起来没事）。NX 的解法是
//  结构性的：同一个设置视图实例常驻 ZStack，形态（floating 面板 /
//  整屏）由 ShellLayout 按「当前」尺寸在每次布局时现算——源码注释
//  原话 "One settings view in one place for every layout, so its
//  state, scroll position and focus survive a fold, a rotation or a
//  Stage Manager resize."。本容器自此改为三页在两形态下的唯一宿主
//  （.sheet 通路整体拆除）：pane 宽仍由 LCSidePanelSpec 逐布局现
//  算，pane < 宿主宽即 floating 面板形态（压暗 + 发丝线 + 右侧滑
//  入），pane == 宿主宽即整屏形态（自底部滑入、无压暗）。页面实例
//  从不离开视图层级，旋转只是同一实例的帧宽与环境标记翻转——页面
//  状态、滚动位置、进行中的设置写入全部原样保留，不存在关页重开。
//  取舍一处：竖屏 .sheet 的下滑关闭是 UIKit sheet  chrome 的属性，
//  单一宿主下若要保留，须逐页做滚动偏移协调（容器设置页本体按约
//  不动、无从接入），故整屏形态以页内关闭钮为准（游戏设置「‹ 游
//  戏库」/ 容器设置「关闭」/ 手柄页「X」，两形态都在且都走 onClose）；
//  NX 自身整屏形态同样无下滑关闭、只靠页内返回钮。面板形态的点压
//  暗区 + 右滑拖动关闭照旧。
//
//  Phase 24（已由 Phase 26 撤销，存史）：曾在宿主整屏分支按页声明
//  三态（LCSidePanelTopBehavior）垫回顶距、并给整页块套 sheet 式顶
//  部圆角（LCSheetTopClipShape，圆角线落在内容实际顶缘）。真机被
//  用户否决：圆角线以上仍露一带宿主页底色 / 主页同款游戏封面，两
//  张封面上下重叠很难看。
//
//  Phase 26（竖屏设置页改 NX2 式全顶铺满，用户裁决）：竖屏呼出设
//  置页应直接铺满到物理顶——这正是 NX 的处理方式：settingsPane 的
//  ScrollView .ignoresSafeArea(edges: .all)、页底色出血到屏幕边缘，
//  控件与文字各自在内容坐标里避开安全区（PaneBanner 的 topInset
//  公式与状态栏 scrim、返回钮浮排）。本容器随之回退为纯粹的呈现
//  宿主：不再裁圆角、不再垫顶距、不再有 topBehavior 声明；顶部处
//  理全部下放到各页（都在物理顶坐标系里自理）：
//  - 游戏设置页：封面背景层向上出血到物理顶（等价于 NX 的
//    bannerHeight + topInset，坐标换算见 LCGameSettingsView 头部
//    注释），信息簇与「‹ 游戏库」钮相对安全区位置不变，状态栏
//    scrim 按 NX 原规格补回；
//  - 手柄页：页面背景画满整帧，内容（标题行 / X / 按键测试子页）
//    在页面背景内侧按窗口顶部安全区下移（页面自己垫，不再由宿
//    主外垫）；
//  - 容器设置页：自带 NavigationView，导航栏背景延伸覆盖状态栏
//    带、工具栏在栏内不撞岛，零改动（Phase 26 核查结论）。
//  横屏面板形态逐点不动（贴右全高直角，用户已确认）。各页需要的
//  顶部安全区数值统一取 LCSidePanelSpec.windowTopSafeInset（窗口
//  keyWindow 的 UIKit 真值）：本工程带 .ignoresSafeArea() 的
//  GeometryReader 读到的 safeAreaInsets 恒为 0（LCGameHomeView
//  .swift:120-122 实证、主页靠外层注入同理），只能取窗口真值；
//  该值逐布局重读，旋转 / 形态翻转时各页按当前值重算（手机横屏
//  状态栏隐藏时为 0），不残留、不双算。
//

import SwiftUI
import UIKit

/// 「当前页处于 floating 侧面板形态」环境标记：自适应宿主按当前
/// 形态现置（Phase 22 起不再是「打开时」常量——旋转翻转形态时此
/// 值随之翻转，页面据此原地变形）。LCSettingsColumn 读到 true 时
/// 把横屏 640 列退化为全宽填充，并把 isLandscape 恒置 true（面板
/// 内页自身宽 < 高是常态——如手机横屏面板 410×430——横竖屏语义
/// 应由呈现形态决定，不由面板内尺寸决定）；整屏形态时为 false，
/// 页面回到按自身尺寸判定的原 sheet 语义（竖屏全宽、零变化）。
private struct LCInSidePanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var lcInSidePanel: Bool {
        get { self[LCInSidePanelKey.self] }
        set { self[LCInSidePanelKey.self] = newValue }
    }
}

/// NX ShellLayout 的面板宽度规则（见文件头规格摘录）
enum LCSidePanelSpec {
    /// 面板宽度上限（NX overlayWidth，LibraryView.swift:19）
    static let overlayCap: CGFloat = 520

    static func paneWidth(screenWidth width: CGFloat, screenHeight height: CGFloat) -> CGFloat {
        let regular = width >= 600 && height >= 500
        let coverFlow = width > height * 1.2
        var cap = overlayCap
        if coverFlow && !regular {
            cap = min(overlayCap, width * 0.44)
        }
        // settingsFloat 的等价条件：留不出至少 120pt 的库，面板即整屏宽
        guard width >= cap + 120 else { return width }
        return min(width, cap)
    }

    /// 窗口顶部安全区真值（UIKit）：Phase 26 起各页在物理顶坐标系
    /// 里自理顶部（游戏页封面出血的补偿量、手柄页内容下移的垫值）
    /// 时统一取此值。带 .ignoresSafeArea() 的 GeometryReader 读到
    /// 的 safeAreaInsets 恒为 0（见文件头 Phase 26 注），只能取
    /// keyWindow 真值；每次访问现读，旋转后即为新方向的值。
    static var windowTopSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
    }
}

/// 设置类页面的自适应宿主（Phase 22 起为三页在两形态下的唯一呈现
/// 容器，结构照 NX LibraryView 的 settingsPane）：宿主在自己的
/// ZStack 顶层放一层，isPresented 为 true 时按「当前」尺寸现算形态
/// ——pane 宽 < 宿主宽 = floating 面板（压暗层 + 发丝线 + 右侧
/// 滑入）；pane 宽 == 宿主宽 = 整屏（无压暗、自底部滑入）。旋转 /
/// 窗口尺寸变化只改帧宽与环境标记，内容实例不重建。
struct LCSidePanelContainer<Content: View>: View {
    var isPresented: Bool
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    /// 压暗区右滑拖动量：面板等量跟随（NX edgeDrag），松手按阈值决定去留
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var slideAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.3)
    }

    var body: some View {
        GeometryReader { geo in
            let pane = LCSidePanelSpec.paneWidth(screenWidth: geo.size.width, screenHeight: geo.size.height)
            // 形态由当前尺寸决定（NX settingsFloat 的等价判定）：
            // pane 占满宿主宽即整屏形态，否则为 floating 面板
            let floating = pane < geo.size.width
            ZStack(alignment: .trailing) {
                if isPresented {
                    if floating {
                        // 压暗层：盖住主页（主页随之不可交互），不透明度随
                        // 拖动量线性变浅（NX 同式 0.55 × (1 − drag/pane)）
                        Color.black
                            .opacity(0.55 * (1 - min(CGFloat(1), dragOffset / max(pane, 1))))
                            .ignoresSafeArea()
                            .onTapGesture { onClose() }
                            .gesture(dragGesture(pane: pane))
                            .transition(.opacity)
                    }

                    content()
                        .frame(width: pane)
                        .frame(maxHeight: .infinity)
                        // 页底色铺满至屏幕边缘（NX ShellPalette.background 原值）
                        .background {
                            Color(red: 0.055, green: 0.055, blue: 0.06)
                                .ignoresSafeArea()
                        }
                        // 朝向库一侧的 1pt 发丝线（NX hairline = 白 0.08），
                        // 仅 floating 形态有「朝向库的一侧」（NX 同规）
                        .overlay(alignment: .leading) {
                            if floating {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 1)
                                    .ignoresSafeArea()
                            }
                        }
                        .offset(x: dragOffset)
                        .environment(\.lcInSidePanel, floating)
                        .transition(floating
                            ? .move(edge: .trailing).combined(with: .opacity)
                            : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 形态翻转（旋转）时帧宽 / 压暗 / 列宽语义一并平滑变形；
            // 翻转瞬间清掉面板拖动量，避免整屏形态残留横向偏移
            .animation(slideAnimation, value: floating)
            .onChange(of: floating) { _ in
                dragOffset = 0
            }
        }
        .ignoresSafeArea()
        .animation(slideAnimation, value: isPresented)
        .onChange(of: isPresented) { presented in
            if !presented {
                dragOffset = 0
            }
        }
    }

    /// 压暗区上的右滑拖动 = NX 的左缘 EdgeSwipeBack（手势起点在屏幕
    /// 左缘即压暗区上）：只认横向右滑，面板跟随；松手时过面板 1/3
    /// 或预测落点甩过整幅面板则关闭，否则弹回。手势挂在压暗层上，
    /// 不与面板内滚动 / 编辑手势竞争。
    private func dragGesture(pane: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let travel = value.translation.width
                if travel > pane / 3 || value.predictedEndTranslation.width > pane {
                    onClose()
                } else if dragOffset != 0 {
                    withAnimation(reduceMotion ? nil : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.25)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
