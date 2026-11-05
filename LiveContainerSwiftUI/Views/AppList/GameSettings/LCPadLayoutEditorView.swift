//
//  LCPadLayoutEditorView.swift
//  LiveContainerSwiftUI
//
//  按键布局编辑页（样式按已批准预览 lc-padedit-silk-v1，交互与 NX2Apple 壳设置页的
//  编辑器 PR #51 一致）：画布上的按键摆在引擎键位表的真实座位上，可点选、拖动、
//  方向键 1% 微调、大小 ±0.05（0.6–1.6）、单键 / 全部重置；改动即存进客体容器偏好
//  plist 的 DmPadCustom / DmPadCustomHades，与游戏内编辑器共用一份，下次启动生效。
//  演示按键的皮肤跟随该游戏的按键皮肤设置：素材从客体包内 dm/<皮肤夹>/<键名>.png
//  读（DmGamepad 的同一路径规则），读不到就退回带字形的玻璃圆盘。
//

import SwiftUI

struct LCPadLayoutEditorView: View {
    let game: LCPadLayoutGame
    let prefs: LCGamePrefs
    let bundlePath: String?
    let bannerImage: UIImage?
    let skinValue: Int

    @Environment(\.presentationMode) private var presentationMode
    @State private var custom: LCPadCustom
    @State private var selected: String?
    @State private var drag: (name: String, start: LCPadCustom.Entry, centre: CGPoint)?
    @State private var confirmResetAll = false

    private static let panelBackground = Color(red: 0.075, green: 0.078, blue: 0.09)
    private static let accentColor = Color(red: 0.788, green: 0.373, blue: 0.263)
    private static let ringColor = Color(red: 1.0, green: 0.72, blue: 0.1)

    init(game: LCPadLayoutGame, prefs: LCGamePrefs, bundlePath: String?, bannerImage: UIImage?, skinValue: Int) {
        self.game = game
        self.prefs = prefs
        self.bundlePath = bundlePath
        self.bannerImage = bannerImage
        self.skinValue = skinValue
        _custom = State(initialValue: LCPadCustom(dictionary: prefs.padCustomDictionary(game.storeKey)))
        _selected = State(initialValue: game.keys.first?.name)
    }

    private var artFolder: String? { game.artFolder(skin: skinValue) }

    var body: some View {
        ZStack {
            backgroundView
            GeometryReader { geo in
                if geo.size.width >= 700 {
                    // 横屏：左画布右面板固定排布；底部多留一段避开浮动底栏胶囊
                    VStack(spacing: 10) {
                        header
                        HStack(alignment: .top, spacing: 14) {
                            canvas
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            panel
                                .frame(width: 330)
                        }
                    }
                    .padding(14)
                    .padding(.bottom, 76)
                } else {
                    // 竖屏：整页可滚动——上方画布按屏宽等比，下方完整面板全部可达；
                    // 画布上的按键拖动手势用 highPriorityGesture，不被页面滚动抢走
                    ScrollView {
                        VStack(spacing: 10) {
                            header
                            canvas
                                .frame(maxWidth: .infinity)
                                .aspectRatio(16 / 9, contentMode: .fit)
                            panel
                        }
                        .padding(14)
                        .padding(.bottom, 96)
                    }
                }
            }
        }
        .hideTabBarOnPush()
        .preferredColorScheme(.dark)
        .navigationBarHidden(true)
        .confirmationDialog("全部重置？", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("全部重置", role: .destructive) {
                custom.resetAll()
                save()
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("所有按键回到打包时的位置与大小。")
        }
    }

    // MARK: 背景与头部

    @ViewBuilder
    private var backgroundView: some View {
        if let bannerImage {
            Image(uiImage: bannerImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 18)
                .opacity(0.5)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.45).ignoresSafeArea())
        } else {
            Color(red: 0.055, green: 0.055, blue: 0.059)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                presentationMode.wrappedValue.dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.footnote.bold())
                    Text("游戏设置")
                }
                .foregroundColor(LCGameCardView.creamColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            Text("\(game.displayName) · 按键布局（仅战斗页）")
                .font(.headline)
                .foregroundColor(LCGameCardView.creamColor)
            Spacer()
        }
    }

    // MARK: 画布

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                stickView(in: size)
                ForEach(game.keys) { key in
                    keyView(key, in: size)
                }
            }
        }
    }

    private func centre(of name: String, in size: CGSize) -> CGPoint {
        if let drag, drag.name == name { return drag.centre }
        if name == "stick" { return custom.stickCentre(game: game, in: size) }
        let key = game.keys.first { $0.name == name }!
        return custom.centre(of: key, game: game, in: size)
    }

    private func keyView(_ key: LCPadLayoutGame.Key, in size: CGSize) -> some View {
        let e = custom.entry(key.name)
        let d = 2 * key.r * e.s * size.width * game.artScale(key, skin: skinValue)
        let c = centre(of: key.name, in: size)
        return keyFace(key, diameter: d)
            .frame(width: d, height: d)
            .overlay { if selected == key.name { selectionRing(d) } }
            .position(c)
            .highPriorityGesture(dragGesture(key.name, in: size))
            .onTapGesture { selected = key.name }
            .zIndex(selected == key.name || drag?.name == key.name ? 2 : 1)
    }

    private func stickView(in size: CGSize) -> some View {
        let e = custom.entry("stick")
        // 玻璃皮肤下摇杆盘按引擎的 0.9 画（仅丝之歌）；哈迪斯素材的盘占画布 0.875
        let glassFactor: CGFloat = artFolder == nil && game == .silksong ? 0.9 : 1
        let d = 2 * game.stickRadius * e.s * size.width * glassFactor
            * (game == .hades2 && artFolder != nil ? 1.0 / 0.875 : 1)
        let c = centre(of: "stick", in: size)
        return ZStack {
            if let artFolder, let img = padArt(artFolder, "stick") {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Circle().fill(Color.white.opacity(0.10))
                Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
            }
            if let artFolder, let knob = padArt(artFolder, "knob") {
                Image(uiImage: knob).resizable().scaledToFit().frame(width: d * 0.67, height: d * 0.67)
            } else {
                Circle().fill(Color.white.opacity(0.16)).frame(width: d * 0.67, height: d * 0.67)
            }
        }
        .frame(width: d, height: d)
        .overlay { if selected == "stick" { selectionRing(d) } }
        .position(c)
        .highPriorityGesture(dragGesture("stick", in: size))
        .onTapGesture { selected = "stick" }
        .zIndex(selected == "stick" || drag?.name == "stick" ? 2 : 1)
    }

    private func selectionRing(_ d: CGFloat) -> some View {
        Circle()
            .strokeBorder(Self.ringColor, lineWidth: 3)
            .frame(width: d * 1.12 + 8, height: d * 1.12 + 8)
    }

    /// 拖动自由移动（游戏内编辑器的方式）：存的偏移是中心相对键位表中心的屏幕比例，
    /// 中心按引擎规则夹取，拖完落盘
    private func dragGesture(_ name: String, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag?.name != name {
                    selected = name
                    let start = custom.entry(name)
                    drag = (name, start, centre(of: name, in: size))
                }
                guard let d0 = drag else { return }
                let raw = game.keys.first { $0.name == name }
                let base = name == "stick" ? game.rawStickCentre(in: size) : game.rawCentre(raw!, in: size)
                let startCentre = CGPoint(x: base.x + d0.start.dx * size.width, y: base.y + d0.start.dy * size.height)
                let moved = CGPoint(x: startCentre.x + value.translation.width, y: startCentre.y + value.translation.height)
                let radius = (raw?.r ?? game.stickRadius) * d0.start.s * size.width
                drag = (name, d0.start, LCPadCustom.clamp(moved, radius: radius, in: size))
            }
            .onEnded { _ in
                guard let d0 = drag else { return }
                let raw = game.keys.first { $0.name == name }
                let base = name == "stick" ? game.rawStickCentre(in: size) : game.rawCentre(raw!, in: size)
                var entry = d0.start
                entry.dx = (d0.centre.x - base.x) / size.width
                entry.dy = (d0.centre.y - base.y) / size.height
                custom.set(name, entry)
                save()
                drag = nil
            }
    }

    @ViewBuilder
    private func keyFace(_ key: LCPadLayoutGame.Key, diameter d: CGFloat) -> some View {
        if let artFolder, let img = padArt(artFolder, key.name) {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            ZStack {
                Circle().fill(Color.black.opacity(0.45))
                Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                if let glyph = key.glyph {
                    Text(glyph)
                        .font(.system(size: d * (glyph.count > 1 ? 0.30 : 0.42), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    symbol(for: key.name)
                        .font(.system(size: d * 0.42))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }

    @ViewBuilder
    private func symbol(for name: String) -> some View {
        switch name {
        case "eye": Image(systemName: "eye")
        case "bag": Image(systemName: "bag")
        case "pause": Image(systemName: "pause")
        case "left": Image(systemName: "arrowtriangle.left.fill")
        case "up": Image(systemName: "arrowtriangle.up.fill")
        case "down": Image(systemName: "arrowtriangle.down.fill")
        case "right": Image(systemName: "arrowtriangle.right.fill")
        default: Image(systemName: "circle")
        }
    }

    /// 客体包内素材：<客体包>/dm/<皮肤夹>/<键名>.png（DmGamepad 的同一路径）
    private func padArt(_ folder: String, _ name: String) -> UIImage? {
        guard let bundlePath else { return nil }
        return UIImage(contentsOfFile: bundlePath + "/dm/\(folder)/\(name).png")
    }

    // MARK: 右侧面板（预览：选中按键 / 位置 / 大小 / 重置 / 完成）

    private var panel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("按键布局")
                    .font(.title3.bold())
                    .foregroundColor(LCGameCardView.creamColor)
                Spacer()
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("完成")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Self.accentColor)
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("选中按键")
                    .font(.footnote)
                    .foregroundColor(.gray)
                Text(selectedLabel)
                    .font(.title3.bold())
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("位置（点一下移动 1%）")
                    .font(.footnote)
                    .foregroundColor(.gray)
                HStack(spacing: 8) {
                    nudgeButton(systemImage: "chevron.left", dx: -0.01, dy: 0)
                    nudgeButton(systemImage: "chevron.up", dx: 0, dy: -0.01)
                    nudgeButton(systemImage: "chevron.down", dx: 0, dy: 0.01)
                    nudgeButton(systemImage: "chevron.right", dx: 0.01, dy: 0)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("大小")
                    .font(.footnote)
                    .foregroundColor(.gray)
                HStack(spacing: 14) {
                    sizeButton(systemImage: "minus") { stepSize(by: -LCPadLayoutGame.sizeStep) }
                    Text(String(format: "%.2f×", selectedEntry.s))
                        .font(.title3.bold().monospacedDigit())
                        .frame(minWidth: 76)
                    sizeButton(systemImage: "plus") { stepSize(by: LCPadLayoutGame.sizeStep) }
                }
            }

            HStack(spacing: 10) {
                Button {
                    if let selected {
                        custom.reset(selected)
                        save()
                    }
                } label: {
                    Text("单键重置")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                Button {
                    confirmResetAll = true
                } label: {
                    Text("全部重置")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
            }

            Text("演示按键跟随皮肤设置（当前：\(game.skinDisplayName(skinValue))）。与游戏内编辑器共用 \(game.storeKey)，改完下次启动游戏生效。")
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
        }
        .padding(18)
        .background(Self.panelBackground.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    private func nudgeButton(systemImage: String, dx: CGFloat, dy: CGFloat) -> some View {
        Button {
            nudge(dx: dx, dy: dy)
        } label: {
            Image(systemName: systemImage)
                .font(.body.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundColor(LCGameCardView.creamColor)
        .disabled(selected == nil)
    }

    private func sizeButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.bold())
                .frame(width: 52, height: 44)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundColor(LCGameCardView.creamColor)
        .disabled(selected == nil)
    }

    // MARK: 编辑动作

    private var selectedLabel: String {
        guard let selected else { return "（点选一个按键）" }
        if selected == "stick" { return "摇杆" }
        return game.keys.first { $0.name == selected }?.label ?? selected
    }

    private var selectedEntry: LCPadCustom.Entry {
        guard let selected else { return LCPadCustom.Entry() }
        return custom.entry(selected)
    }

    /// 方向键一步：偏移按屏幕比例移动，钳在整屏范围内（绘制时再按引擎规则夹取）
    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let selected else { return }
        var entry = custom.entry(selected)
        entry.dx = min(max(entry.dx + dx, -1), 1)
        entry.dy = min(max(entry.dy + dy, -1), 1)
        custom.set(selected, entry)
        save()
    }

    private func stepSize(by step: CGFloat) {
        guard let selected else { return }
        var entry = custom.entry(selected)
        entry.s = min(LCPadLayoutGame.sizeRange.upperBound,
                      max(LCPadLayoutGame.sizeRange.lowerBound, ((entry.s + step) * 20).rounded() / 20))
        custom.set(selected, entry)
        save()
    }

    private func save() {
        prefs.setPadCustomDictionary(game.storeKey, custom.dictionary)
    }
}
