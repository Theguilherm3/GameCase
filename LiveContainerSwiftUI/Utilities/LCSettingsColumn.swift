//
//  LCSettingsColumn.swift
//  LiveContainerSwiftUI
//
//  设置类页面横屏定宽列（NX2Apple 壳通则：ShellSettingsView / ControllersView /
//  TouchLayoutEditorView 的设置类页面内容列统一 640pt）。
//
//  约束必须加在决定内容宽度的容器本体上：PR #10 把 .frame(maxWidth: 640)
//  加在 ScrollView 的内容 VStack 上，真机落点不精确——用户截图实测（956pt
//  横屏）：游戏设置页列宽 ≈669pt（居中但宽于规格），手柄页列宽 ≈668pt 且
//  靠左贴边（照抄 NX 时连 .leading 对齐一起抄了）。滚动内容的帧不治理滚动
//  视口的宽度，视口多宽、行与卡片就多宽。本容器在页面根层用 GeometryReader
//  读页面自身尺寸：横向（宽 > 高）时给内容容器（ScrollView / Form 本体）
//  显式定宽 min(640, 可用宽) 并居中；竖向时宽 = 可用全宽、高 = 可用全高，
//  与不加约束时逐点一致（竖屏零变化）。闭包参数 isLandscape 仍向页内
//  报告横竖屏判定（Phase 14 起游戏设置页头部已全形态统一为图标头、
//  不再读它，其余页可按需取用）。
//
//  横屏侧面板内（Phase 14，环境 lcInSidePanel = true）：640 在 NX 里
//  本就是面板内部内容列的上限、面板宽（≤520）恒小于它——本容器必须
//  退化为全宽填充，不得再叠一层收窄或居中偏移；同时 isLandscape 恒
//  置 true：面板内页自身宽 < 高是常态（手机横屏面板约 410×430），
//  若按页自身宽高判横竖，游戏设置页头部会误落竖屏图标头。横屏语义
//  由呈现形态决定。sheet 呈现（不带此环境）行为与原来逐点一致。
//
//  面板内右侧死空（Phase 16）：Phase 14 只退化了列宽，没退化安全区
//  消费。面板贴在屏幕右缘，窗口的横向 safe inset 是位置性的——面板
//  区域只压在尾部不安全带上（灵动岛侧 ≈59pt），页内的 NavigationView
//  内容区与 ScrollView 的自动内容安全区调整便把这 59pt 单侧计入，
//  叠在内容自己的 padding 之上：真机丝之歌面板内分组卡左距 ≈30、
//  右距 ≈120。NX2 壳在提交 d38ed0b8（「Landscape panels narrower
//  again, with even margins」）修过同病：设置类页面的 ScrollView 不
//  再吃横向 safe inset（.ignoresSafeArea(edges: [.leading,
//  .trailing])），每游戏页删掉第二次叠加的尾部 inset，边距只由内容
//  自己的 padding 决定。本容器照此：面板内时整页根层忽略横向安全
//  区，GeometryReader 量到的就是面板全宽、列按全宽落位，左右边距
//  对称（各页自己的 padding，面板内按 NX 口径 24）。非面板形态
//  （竖屏 sheet 横向 inset 本为 0、横屏居中列形态）不加此忽略，
//  与 Phase 12/14 行为逐点一致。
//

import SwiftUI

struct LCSettingsColumn<Content: View>: View {
    @ViewBuilder var content: (_ isLandscape: Bool) -> Content
    @Environment(\.lcInSidePanel) private var inSidePanel

    var body: some View {
        if inSidePanel {
            reader
                .ignoresSafeArea(edges: [.leading, .trailing])
        } else {
            reader
        }
    }

    private var reader: some View {
        GeometryReader { geo in
            let isLandscape = inSidePanel || geo.size.width > geo.size.height
            let columnWidth = inSidePanel ? geo.size.width
                : (isLandscape ? min(640, geo.size.width) : geo.size.width)
            content(isLandscape)
                .frame(width: columnWidth, height: geo.size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
