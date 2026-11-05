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

import SwiftUI

/// 「当前页处于横屏侧面板内」环境标记：面板容器在内容上置 true。
/// LCSettingsColumn 读到它时把横屏 640 列退化为全宽填充，并把
/// isLandscape 恒置 true（面板内页自身宽 < 高是常态——如手机横屏
/// 面板 410×430——若按页自身宽高判横竖，游戏设置页头部会误落到
/// 竖屏图标头；横屏语义应由呈现形态决定，不由面板内尺寸决定）。
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
}

/// 右侧抽屉面板容器：宿主在自己的 ZStack 顶层放一层，isPresented 为
/// true 时渲染压暗层 + 面板；false 时不渲染任何可命中内容。
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
            ZStack(alignment: .trailing) {
                if isPresented {
                    // 压暗层：盖住主页（主页随之不可交互），不透明度随
                    // 拖动量线性变浅（NX 同式 0.55 × (1 − drag/pane)）
                    Color.black
                        .opacity(0.55 * (1 - min(1, dragOffset / max(pane, 1))))
                        .ignoresSafeArea()
                        .onTapGesture { onClose() }
                        .gesture(dragGesture(pane: pane))
                        .transition(.opacity)

                    content()
                        .frame(width: pane)
                        .frame(maxHeight: .infinity)
                        // 页底色铺满至屏幕边缘（NX ShellPalette.background 原值）
                        .background {
                            Color(red: 0.055, green: 0.055, blue: 0.06)
                                .ignoresSafeArea()
                        }
                        // 朝向库一侧的 1pt 发丝线（NX hairline = 白 0.08）
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 1)
                                .ignoresSafeArea()
                        }
                        .offset(x: dragOffset)
                        .environment(\.lcInSidePanel, true)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
