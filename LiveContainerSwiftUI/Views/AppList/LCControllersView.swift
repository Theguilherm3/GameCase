//
//  LCControllersView.swift
//  LiveContainerSwiftUI
//
//  手柄页：复刻 NX2Apple 壳 ControllersView 的结构、视觉与文案（主页手柄胶囊点开，
//  sheet 呈现）。组成：页题 + 关闭钮、已连接手柄卡（玩家号 / 名称 / 电量片）、
//  空状态卡、「按钮」分组（按键测试入口 → 实时按键测试）。
//  未搬入的部分及原因见 PR #5 报告：按键映射（壳侧映射表由客体引擎消费，LC 宿主
//  没有对应落点）、「手柄操作」提示（那是壳内手柄导航的说明，LC 游戏库只有触控）。
//

import SwiftUI
import GameController

struct LCControllersView: View {
    @ObservedObject var monitor: LCControllerMonitor
    /// 横屏侧面板呈现时的关闭回调（Phase 14，主页注入）：面板不是系统
    /// 呈现，dismiss 环境无效，关闭走此回调；nil = sheet 呈现，用
    /// dismiss 关闭，与原来一致。
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    /// 当前是否 floating 侧面板形态（宿主按当前形态现置）：整屏
    /// 形态下本页要自己垫顶部安全区（见 body 的 topContentPad），
    /// 面板形态恒不垫（面板贴右全高、顶部即其物理顶）
    @Environment(\.lcInSidePanel) private var inSidePanel
    @State private var showTest = false
    /// 电量变化慢且 GameController 不发通知：30 秒重读一次（与 NX 壳适配器同策略）
    @State private var batteryTick = 0

    // NX 壳 ShellPalette 原值；自适应轮改动态色：深色变体与原值逐字
    // 一致，浅色变体与设置页 LCNXColor 同口径（页底 0.96 灰白、卡面
    // 白、奶油金棕、发丝线黑 0.08）。状态色两模式共用、不翻。
    private static let background = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    })
    private static let surface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })
    private static let cream = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1)
            : UIColor(red: 0.66, green: 0.47, blue: 0.16, alpha: 1)
    })
    private static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
    private static let attention = Color(red: 1, green: 0.78, blue: 0.24)
    private static let hairline = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    })

    private struct RowInfo: Identifiable {
        let id: ObjectIdentifier
        let name: String
        let player: Int
        let batteryPercent: Int?
        let charging: Bool
    }

    private var rows: [RowInfo] {
        _ = batteryTick
        return monitor.controllers.enumerated().map { index, controller in
            let battery = Self.battery(of: controller)
            return RowInfo(
                id: ObjectIdentifier(controller),
                name: controller.vendorName ?? "游戏手柄",
                player: index + 1,
                batteryPercent: battery.percent,
                charging: battery.charging
            )
        }
    }

    /// 电量读法与 NX 壳适配器一致：状态 unknown 视为不报告电量，其余按比例取整
    private static func battery(of controller: GCController) -> (percent: Int?, charging: Bool) {
        if #available(iOS 17.0, *) {
            guard let battery = controller.battery, battery.batteryState != .unknown else {
                return (nil, false)
            }
            return (Int((battery.batteryLevel * 100).rounded()), battery.batteryState == .charging)
        }
        return (nil, false)
    }

    /// 整屏形态的内容顶垫（Phase 26）：页面背景画满到物理顶、内容
    /// （标题行 / X / 按键测试子页的返回钮）在背景内侧下移一个窗
    /// 口顶部安全区，避开灵动岛。Phase 24 曾由宿主在内容外侧垫
    /// （连宿主页底色带与圆角线一起），Phase 26 改由页面自垫：
    /// 垫加在根 Group 上、背景修饰之前——背景按垫后的帧再
    /// ignoresSafeArea 画满整帧，顶部那条是页面自己的底色而非宿
    /// 主的。面板形态（inSidePanel）恒 0，现行面板内排布逐点不
    /// 变；数值取窗口真值、逐次求值现读，旋转后即为新方向的值。
    private var topContentPad: CGFloat {
        inSidePanel ? 0 : LCSidePanelSpec.windowTopSafeInset
    }

    var body: some View {
        Group {
            if showTest {
                LCControllerTestView(onBack: { showTest = false })
            } else {
                listPage
            }
        }
        .padding(.top, topContentPad)
        .background(Self.background.ignoresSafeArea())
        .foregroundStyle(.primary)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            batteryTick += 1
        }
    }

    // MARK: 列表页（NX ControllersView 本体）

    private var listPage: some View {
        // 横屏定宽与游戏设置页同一层：LCSettingsColumn 把 ScrollView 本体
        // 定宽 640 并居中（PR #10 在内容 VStack 上加 maxWidth、且外层照抄了
        // NX 的 .leading 对齐，真机列宽 ≈668pt 还靠左贴边、右侧留死黑；
        // 视口层定宽后列居中、宽度精确——见 LCSettingsColumn.swift）。
        LCSettingsColumn { _ in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    Text("手柄")
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Button {
                        if let onClose {
                            onClose()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭手柄页")
                }
                if rows.isEmpty {
                    emptyCard
                } else {
                    controllerCard
                }
                buttonsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lcHideScrollIndicators()
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Self.cream)
                .padding(.bottom, 4)
            Text("未连接手柄")
                .font(.system(size: 19, weight: .bold))
            Text("在蓝牙设置里连接手柄。游戏库里随时可以用触控操作。")
                .font(.system(size: 14.5))
                .foregroundStyle(.primary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Self.hairline))
    }

    private var controllerCard: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                controllerRow(row)
                if row.id != rows.last?.id {
                    Rectangle()
                        .fill(Self.hairline)
                        .frame(height: 1)
                        .padding(.leading, 64)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Self.hairline))
    }

    private func controllerRow(_ row: RowInfo) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 20))
                .frame(width: 48, height: 48)
                .background(.primary.opacity(0.07), in: Circle())
                .foregroundStyle(.primary.opacity(0.9))
            VStack(alignment: .leading, spacing: 4) {
                Text("玩家 \(row.player)")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Self.cream.opacity(0.8))
                Text(row.name)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            batteryChip(row)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    }

    /// 电量片（NX BatteryChip）：描边电池形 + 百分比，低电量琥珀、充电绿
    private func batteryChip(_ row: RowInfo) -> some View {
        let low = (row.batteryPercent ?? 100) < 20 && !row.charging
        let tint: Color = low ? Self.attention : row.charging ? Self.ready : .primary.opacity(0.75)
        return HStack(spacing: 7) {
            if let percent = row.batteryPercent {
                batteryShape(fraction: Double(percent) / 100)
                    .foregroundStyle(tint)
                Text("\(percent)%")
                    .monospacedDigit()
                if row.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .accessibilityLabel("充电中")
                }
            } else {
                Text("无电量信息")
            }
        }
        .lineLimit(1)
        .fixedSize()
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(row.batteryPercent == nil ? .primary.opacity(0.45) : tint)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(.primary.opacity(0.06), in: Capsule())
    }

    private func batteryShape(fraction: Double) -> some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(lineWidth: 1.2)
                    .opacity(0.7)
                RoundedRectangle(cornerRadius: 1.5)
                    .padding(2.5)
                    .frame(width: max(7, 22 * min(1, max(0, fraction))))
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 1.5, height: 4)
                .opacity(0.7)
        }
    }

    // MARK: 「按钮」分组（NX 同名分组：映射行依赖客体引擎、未搬；只留按键测试）

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按钮")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.primary.opacity(0.55))
            Button {
                showTest = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("按键测试")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("按下按键，对应的按键会亮起。")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Self.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 按键测试（NX ButtonTestView 的行为复刻：按键亮起、摇杆移动、扳机填充）

private struct LCControllerTestView: View {
    let onBack: () -> Void

    private struct Snapshot {
        var name: String = ""
        var a = false, b = false, x = false, y = false
        var up = false, down = false, left = false, right = false
        var l1 = false, r1 = false
        var l2: Float = 0, r2: Float = 0
        var menu = false, options = false, home = false
        var l3 = false, r3 = false
        var ls = CGPoint.zero, rs = CGPoint.zero
    }

    @State private var snapshot: Snapshot?
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private static let card = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.075, blue: 0.082, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })
    private static let cream = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1)
            : UIColor(red: 0.66, green: 0.47, blue: 0.16, alpha: 1)
    })
    private static let hairline = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    })

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按键测试")
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)
                        Text(headerName)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.primary.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回手柄页")
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)
                Rectangle()
                    .fill(Self.hairline)
                    .frame(height: 1)
                diagram
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                Text(pressedText)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Self.cream)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Text("摇杆推动、扳机按压都会实时跟随")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 18)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 620)
            .background(Self.card, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.10)))
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .lcHideScrollIndicators()
        .onReceive(tick) { _ in
            refresh()
        }
        .onAppear {
            refresh()
        }
    }

    private var headerName: String {
        if let name = snapshot?.name, !name.isEmpty {
            return name
        }
        return "在手柄上按任意按键"
    }

    // MARK: 简图（面键菱形 + 十字键 + 双摇杆 + 肩键/扳机条）

    private var diagram: some View {
        let s = snapshot ?? Snapshot()
        return VStack(spacing: 16) {
            HStack(spacing: 14) {
                triggerBar(label: "L2", value: s.l2)
                triggerBar(label: "R2", value: s.r2)
            }
            HStack {
                shoulderChip(label: "L1", pressed: s.l1)
                Spacer()
                shoulderChip(label: "R1", pressed: s.r1)
            }
            HStack(alignment: .center, spacing: 10) {
                stickView(point: s.ls, pressed: s.l3, label: "左摇杆")
                dpadView(s)
                centerChips(s)
                faceButtons(s)
                stickView(point: s.rs, pressed: s.r3, label: "右摇杆")
            }
        }
    }

    private func triggerBar(label: String, value: Float) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(value > 0.02 ? Self.cream : .primary.opacity(0.55))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.cream)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func shoulderChip(label: String, pressed: Bool) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(pressed ? .black : .primary.opacity(0.7))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(pressed ? Self.cream : Color.primary.opacity(0.08), in: Capsule())
    }

    private func stickView(point: CGPoint, pressed: Bool, label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                Circle()
                    .fill(pressed ? Self.cream : Color.primary.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .offset(x: point.x * 18, y: point.y * 18)
            }
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary.opacity(0.5))
        }
    }

    private func dpadView(_ s: Snapshot) -> some View {
        let cell: CGFloat = 17
        func piece(_ pressed: Bool) -> some View {
            RoundedRectangle(cornerRadius: 3)
                .fill(pressed ? Self.cream : Color.primary.opacity(0.14))
                .frame(width: cell, height: cell)
        }
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Color.clear.frame(width: cell, height: cell)
                piece(s.up)
                Color.clear.frame(width: cell, height: cell)
            }
            HStack(spacing: 2) {
                piece(s.left)
                piece(s.up || s.down || s.left || s.right)
                piece(s.right)
            }
            HStack(spacing: 2) {
                Color.clear.frame(width: cell, height: cell)
                piece(s.down)
                Color.clear.frame(width: cell, height: cell)
            }
        }
    }

    private func centerChips(_ s: Snapshot) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                miniChip(label: "菜单", pressed: s.menu)
                miniChip(label: "选项", pressed: s.options)
            }
            HStack(spacing: 8) {
                miniChip(label: "主页", pressed: s.home)
            }
        }
    }

    private func miniChip(label: String, pressed: Bool) -> some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(pressed ? .black : .primary.opacity(0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(pressed ? Self.cream : Color.primary.opacity(0.08), in: Capsule())
    }

    private func faceButtons(_ s: Snapshot) -> some View {
        let d: CGFloat = 33
        func button(_ label: String, _ color: Color, _ pressed: Bool) -> some View {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(pressed ? .black : color)
                .frame(width: d, height: d)
                .background(pressed ? color : Color.primary.opacity(0.07), in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.55), lineWidth: 1))
        }
        let yellow = Color(red: 0.95, green: 0.78, blue: 0.25)
        let blue = Color(red: 0.35, green: 0.58, blue: 0.95)
        let red = Color(red: 0.92, green: 0.36, blue: 0.31)
        let green = Color(red: 0.36, green: 0.80, blue: 0.46)
        return VStack(spacing: 3) {
            button("Y", yellow, s.y)
            HStack(spacing: 14) {
                button("X", blue, s.x)
                button("B", red, s.b)
            }
            button("A", green, s.a)
        }
    }

    // MARK: 快照读取（第一个已连接手柄；扩展手柄优先，微型手柄取其子集）

    private var pressedText: String {
        guard let s = snapshot else {
            return "未按任何按键"
        }
        var names: [String] = []
        if s.y { names.append("Y") }
        if s.x { names.append("X") }
        if s.b { names.append("B") }
        if s.a { names.append("A") }
        if s.up { names.append("十字键上") }
        if s.down { names.append("十字键下") }
        if s.left { names.append("十字键左") }
        if s.right { names.append("十字键右") }
        if s.l1 { names.append("L1") }
        if s.r1 { names.append("R1") }
        if s.l2 > 0.02 { names.append("L2") }
        if s.r2 > 0.02 { names.append("R2") }
        if s.l3 { names.append("左摇杆按下") }
        if s.r3 { names.append("右摇杆按下") }
        if hypot(s.ls.x, s.ls.y) > 0.35 { names.append("左摇杆") }
        if hypot(s.rs.x, s.rs.y) > 0.35 { names.append("右摇杆") }
        if s.menu { names.append("菜单") }
        if s.options { names.append("选项") }
        if s.home { names.append("主页") }
        return names.isEmpty ? "未按任何按键" : names.joined(separator: " + ")
    }

    private func refresh() {
        guard let controller = GCController.controllers().first else {
            snapshot = nil
            return
        }
        var s = Snapshot()
        s.name = controller.vendorName ?? ""
        if let pad = controller.extendedGamepad {
            s.a = pad.buttonA.isPressed
            s.b = pad.buttonB.isPressed
            s.x = pad.buttonX.isPressed
            s.y = pad.buttonY.isPressed
            s.up = pad.dpad.up.isPressed
            s.down = pad.dpad.down.isPressed
            s.left = pad.dpad.left.isPressed
            s.right = pad.dpad.right.isPressed
            s.l1 = pad.leftShoulder.isPressed
            s.r1 = pad.rightShoulder.isPressed
            s.l2 = pad.leftTrigger.value
            s.r2 = pad.rightTrigger.value
            s.menu = pad.buttonMenu.isPressed
            s.options = pad.buttonOptions?.isPressed ?? false
            s.home = pad.buttonHome?.isPressed ?? false
            s.l3 = pad.leftThumbstickButton?.isPressed ?? false
            s.r3 = pad.rightThumbstickButton?.isPressed ?? false
            s.ls = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(-pad.leftThumbstick.yAxis.value))
            s.rs = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(-pad.rightThumbstick.yAxis.value))
        } else if let micro = controller.microGamepad {
            s.a = micro.buttonA.isPressed
            s.x = micro.buttonX.isPressed
            s.menu = micro.buttonMenu.isPressed
            s.up = micro.dpad.up.isPressed
            s.down = micro.dpad.down.isPressed
            s.left = micro.dpad.left.isPressed
            s.right = micro.dpad.right.isPressed
        } else {
            snapshot = nil
            return
        }
        snapshot = s
    }
}

private extension View {
    /// scrollIndicators 是 iOS 16 API，工程部署目标 15，分开守卫
    @ViewBuilder func lcHideScrollIndicators() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }
}
