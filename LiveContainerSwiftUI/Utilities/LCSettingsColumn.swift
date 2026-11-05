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
//  与不加约束时逐点一致（竖屏零变化）。闭包参数 isLandscape 供页内按横竖屏
//  分支（如游戏设置页头部）使用。
//

import SwiftUI

struct LCSettingsColumn<Content: View>: View {
    @ViewBuilder var content: (_ isLandscape: Bool) -> Content

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let columnWidth = isLandscape ? min(640, geo.size.width) : geo.size.width
            content(isLandscape)
                .frame(width: columnWidth, height: geo.size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
