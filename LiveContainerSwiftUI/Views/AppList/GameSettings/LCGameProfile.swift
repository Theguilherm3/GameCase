//
//  LCGameProfile.swift
//  LiveContainerSwiftUI
//
//  每游戏设置页的数据真源：客体包内自带的 dm/launcher.json（引擎 settings.py 在打包时
//  按该游戏的档案生成，键名 / 选项 / 默认值 / 分组 / 标签都以它为准），两款已知游戏再按
//  当前 settings.tsv 做窄增补；解析不到且不是已知游戏时返回 nil，设置页只给通用提示。
//  偏好读写走 LCGamePrefs：目标游戏默认容器的 Library/Preferences/<bundleId>.plist，
//  与游戏内启动器（LauncherSettings.swift）共用同一份：键 "launcher.<ENV>"、字符串值，
//  等于默认值的选择按引擎惯例不落键（删键），其余键（DmPadCustom 等）原样保留。
//

import Foundation

// MARK: - 已知游戏（有按键布局档案的两款）

enum LCKnownGame: String {
    case silksong = "010013C00E930000"
    case hades2 = "0100A00019DE0000"

    /// bundle id 形如 org.nxnative.<小写标题 ID>，取末段大写后匹配
    static func from(bundleIdentifier: String) -> LCKnownGame? {
        guard let last = bundleIdentifier.split(separator: ".").last else {
            return nil
        }
        return LCKnownGame(rawValue: last.uppercased())
    }

    var shortName: String {
        switch self {
        case .silksong: return "丝之歌"
        case .hades2: return "哈迪斯 II"
        }
    }

    /// 按键布局在偏好里的存储键（与 NX2Apple 壳设置页编辑器、游戏内编辑器同一份）
    var padStoreKey: String {
        switch self {
        case .silksong: return "DmPadCustom"
        case .hades2: return "DmPadCustomHades"
        }
    }

    var skinEnv: String {
        switch self {
        case .silksong: return "DM_SILK_SKIN"
        case .hades2: return "DM_HADES_SKIN"
        }
    }

    var padLayoutGame: LCPadLayoutGame {
        switch self {
        case .silksong: return .silksong
        case .hades2: return .hades2
        }
    }
}

// MARK: - 一条启动器设置（launcher.json 的一行）

struct LCLauncherSetting: Identifiable {
    var env: String
    var kind: String // choice / toggle / range
    var section: String // Game / Controls / Performance
    var label: String
    var note: String = ""
    var defaultValue: String
    var options: [(value: String, label: String)] = []
    var minValue: Double = 0
    var maxValue: Double = 0
    var stepValue: Double = 0
    var onValue: String = "1"
    var offValue: String = "0"
    var needs: String? = nil // "DM_RUMBLE=1"：仅当该变量取该值时才显示

    var id: String { env }

    func accepts(_ v: String) -> Bool {
        switch kind {
        case "choice":
            return options.contains { $0.value == v }
        case "toggle":
            return v == onValue || v == offValue
        case "range":
            guard let n = Double(v), n.isFinite else { return false }
            return n >= minValue && n <= maxValue
        default:
            return true
        }
    }

    /// 与引擎 LauncherSetting.isDefault 一致：range 按数值比，其余按字符串比
    func isDefault(_ v: String) -> Bool {
        if kind == "range" {
            guard let a = Double(v), let b = Double(defaultValue) else { return false }
            return abs(a - b) < 1e-6
        }
        return v == defaultValue
    }

    func optionLabel(for value: String) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    /// range 的显示 / 落盘格式：最多两位小数，去掉尾随的 0（1.0 写 "1.0"，0.25 写 "0.25"）
    static func formatRange(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        if s.hasSuffix("0") { s.removeLast() }
        return s
    }
}

// MARK: - 档案加载

enum LCGameProfile {
    /// 设置页的设置清单：客体自带 launcher.json 优先，其次已知游戏的内置表，都没有返回 nil
    static func loadSettings(app: LCAppModel) -> [LCLauncherSetting]? {
        let known = LCKnownGame.from(bundleIdentifier: app.bundleIdentifier)
        if let bundlePath = app.appInfo.bundlePath() {
            let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("dm/launcher.json")
            if let data = try? Data(contentsOf: url), let parsed = parseLauncherJSON(data) {
                return augment(parsed, known: known)
            }
        }
        if let known {
            return builtinSettings(known)
        }
        return nil
    }

    static func parseLauncherJSON(_ data: Data) -> [LCLauncherSetting]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["settings"] as? [[String: Any]] else {
            return nil
        }
        var out: [LCLauncherSetting] = []
        for row in rows {
            guard let env = row["env"] as? String, let kind = row["kind"] as? String else { continue }
            var s = LCLauncherSetting(
                env: env,
                kind: kind,
                section: (row["section"] as? String) ?? "Game",
                label: (row["label"] as? String) ?? env,
                note: (row["note"] as? String) ?? "",
                defaultValue: (row["default"] as? String) ?? ""
            )
            if let opts = row["options"] as? [[Any]] {
                s.options = opts.compactMap { pair in
                    guard pair.count >= 2, let v = pair[0] as? String, let l = pair[1] as? String else { return nil }
                    return (value: v, label: l)
                }
            }
            if let v = row["min"] as? NSNumber { s.minValue = v.doubleValue }
            if let v = row["max"] as? NSNumber { s.maxValue = v.doubleValue }
            if let v = row["step"] as? NSNumber { s.stepValue = v.doubleValue }
            if let v = row["on"] as? String { s.onValue = v }
            if let v = row["off"] as? String { s.offValue = v }
            if let v = row["needs"] as? String { s.needs = v }
            out.append(s)
        }
        return out.isEmpty ? nil : out
    }

    /// 按当前 settings.tsv 对照增补：只补客体文件里缺的、当前构建线已支持的项，不改已有行
    static func augment(_ settings: [LCLauncherSetting], known: LCKnownGame?) -> [LCLauncherSetting] {
        var out = settings
        switch known {
        case .silksong:
            // settings.tsv 现行三档：60 / 120 / 120L（降分辨率）；旧包的 launcher.json 只有两档
            if let i = out.firstIndex(where: { $0.env == "SS_DISPLAY_HZ" }),
               !out[i].options.contains(where: { $0.value == "120L" }) {
                out[i].options.append((value: "120L", label: "120 帧（降分辨率）"))
            }
            // settings.tsv 现行四档皮肤：0 玻璃 / 1 荆棘 / 2 荆棘（角标）/ 3 黑铁；旧包只有三档
            if let i = out.firstIndex(where: { $0.env == "DM_SILK_SKIN" }),
               !out[i].options.contains(where: { $0.value == "3" }) {
                out[i].options.append((value: "3", label: "黑铁"))
            }
        case .hades2:
            // 哈迪斯旧包的 launcher.json 没有皮肤行；当前 settings.tsv 有 DM_HADES_SKIN
            // （0 玻璃 / 1 月亮 / 2 月亮角标，与 DmGamepad 的 hadesSkinMode 一致）
            if !out.contains(where: { $0.env == "DM_HADES_SKIN" }) {
                var skin = LCLauncherSetting(
                    env: "DM_HADES_SKIN", kind: "choice", section: "Controls",
                    label: "按键皮肤",
                    note: "玻璃 = 玻璃按键；月亮 = 图标皮肤；月亮（角标）= 带字母角标的图标皮肤",
                    defaultValue: "1"
                )
                skin.options = [(value: "0", label: "玻璃"), (value: "1", label: "月亮"), (value: "2", label: "月亮（角标）")]
                out.append(skin)
            }
        case nil:
            break
        }
        return out
    }

    // MARK: 内置表（客体缺 launcher.json 时的已知游戏兜底，内容与解析路径同源）

    private static func choice(_ env: String, _ section: String, _ label: String, _ def: String,
                               _ options: [(String, String)], note: String = "") -> LCLauncherSetting {
        var s = LCLauncherSetting(env: env, kind: "choice", section: section, label: label, note: note, defaultValue: def)
        s.options = options.map { (value: $0.0, label: $0.1) }
        return s
    }

    private static func toggle(_ env: String, _ section: String, _ label: String, _ def: String, needs: String? = nil, note: String = "") -> LCLauncherSetting {
        var s = LCLauncherSetting(env: env, kind: "toggle", section: section, label: label, note: note, defaultValue: def)
        s.needs = needs
        return s
    }

    private static func range(_ env: String, _ section: String, _ label: String, _ def: String,
                              _ lo: Double, _ hi: Double, _ step: Double, needs: String? = nil, note: String = "") -> LCLauncherSetting {
        var s = LCLauncherSetting(env: env, kind: "range", section: section, label: label, note: note, defaultValue: def)
        s.minValue = lo; s.maxValue = hi; s.stepValue = step; s.needs = needs
        return s
    }

    private static let languageOptions: [(String, String)] = [
        ("en-US", "美式英语"), ("ja", "日语"), ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"),
        ("it", "意大利语"), ("ru", "俄语"), ("ko", "韩语"), ("zh-Hant", "繁体中文"), ("zh-Hans", "简体中文"),
        ("pt-BR", "巴西葡萄牙语"),
    ]

    static func builtinSettings(_ game: LCKnownGame) -> [LCLauncherSetting] {
        switch game {
        case .silksong:
            // 出处：丝之歌现行包的 dm/launcher.json（引擎 settings.py 生成），再过 augment 的现行增补
            let rows: [LCLauncherSetting] = [
                choice("SS_DISPLAY_HZ", "Game", "帧率", "60",
                       [("60", "60 帧"), ("120", "120 帧")],
                       note: "120 帧需要设备屏幕支持，若设备不支持会自动回落 60 帧，持续高负载下可能因温控而降频，请谨慎使用"),
                choice("DM_OPMODE", "Game", "主机模式", "1",
                       [("1", "底座"), ("0", "掌机")],
                       note: "底座 = 1080p 电视模式；掌机 = 720p，部分游戏的触屏功能仅掌机模式可用"),
                choice("DM_PRESENT_UPSCALE", "Game", "超分", "off",
                       [("off", "标准"), ("metalfx", "MetalFX")], note: "更吃 GPU，可能增加发热。"),
                choice("DM_LANG", "Game", "游戏语言", "zh-Hans", languageOptions, note: "游戏内文本语言"),
                toggle("DM_SHOW_FPS", "Game", "帧数计数器", "1", note: "左上角显示实时帧数"),
                toggle("DM_TOUCH_HAPTICS", "Controls", "触控反馈", "1", note: "按下触屏按键时轻震一下"),
                toggle("DM_RUMBLE", "Controls", "游戏震动", "1", note: "游戏内震动传到手机或手柄"),
                range("DM_RUMBLE_GAIN", "Controls", "震动强度", "1.0", 0, 3, 0.1, needs: "DM_RUMBLE=1", note: "与游戏内的震动设置叠加生效"),
                range("DM_RUMBLE_MIN", "Controls", "震动下限", "0", 0, 0.9, 0.05),
                choice("DM_SILK_SKIN", "Controls", "按键皮肤", "1",
                       [("0", "默认"), ("1", "黑荆棘"), ("2", "黑荆棘（角标）")],
                       note: "默认 = 玻璃按键；黑荆棘 = 图标皮肤；黑荆棘（角标）= 带字母角标的图标皮肤"),
                toggle("DM_PRESENT_SNAP", "Performance", "帧缓冲", "0", note: "可能减少卡顿；会增加显示延迟。"),
                toggle("DM_PSO_MTL4", "Performance", "Metal 4 管线", "0", note: "保留管线档案；占用更多内存。"),
                toggle("DM_PSO_PREBUILD", "Performance", "管线预构建", "1", note: "首次启动需等待几分钟，仅一次。"),
                toggle("DM_NVN_ENC_THREAD", "Performance", "编码线程", "1"),
                toggle("DM_METAL_HUD", "Performance", "性能面板", "0", note: "苹果开发者性能浮层（GPU、帧时间等），一般保持关闭"),
            ]
            return augment(rows, known: .silksong)
        case .hades2:
            // 出处：哈迪斯现行包的 dm/launcher.json + 当前 settings.tsv 的其余行
            let rows: [LCLauncherSetting] = [
                choice("DM_OPMODE", "Game", "主机模式", "1",
                       [("1", "底座模式"), ("0", "掌机模式")]),
                choice("DM_FULLSCREEN", "Game", "画面比例", "1",
                       [("1", "自适应全屏"), ("0", "原生比例")]),
                choice("DM_LANG", "Game", "游戏语言", "zh-Hans", languageOptions),
                toggle("DM_SHOW_FPS", "Game", "帧数计数器", "1"),
                toggle("DM_TOUCH_HAPTICS", "Controls", "触控反馈", "1"),
                toggle("DM_RUMBLE", "Controls", "游戏震动", "1"),
                range("DM_RUMBLE_GAIN", "Controls", "震动强度", "1.0", 0, 3, 0.1, needs: "DM_RUMBLE=1"),
                range("DM_RUMBLE_MIN", "Controls", "震动下限", "0", 0, 0.9, 0.05),
                toggle("DM_PRESENT_SNAP", "Performance", "帧缓冲", "0", note: "可能减少卡顿；会增加显示延迟。"),
                toggle("DM_PSO_MTL4", "Performance", "Metal 4 管线", "0", note: "保留管线档案；占用更多内存。"),
                toggle("DM_PSO_PREBUILD", "Performance", "管线预构建", "1", needs: "DM_PSO_MTL4=1", note: "首次启动需等待几分钟，仅一次。"),
                toggle("DM_NVN_ENC_THREAD", "Performance", "编码线程", "1"),
                toggle("DM_METAL_HUD", "Performance", "性能面板", "0"),
            ]
            return augment(rows, known: .hades2)
        }
    }

    /// 被 env 文件固定的变量（包内 dm/env.txt、容器 Documents/env.txt）：启动器里只显示不改，这里同样锁定
    static func envLockedValues(app: LCAppModel, container: LCContainer?) -> [String: String] {
        var out: [String: String] = [:]
        func absorb(_ url: URL?) {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                let parts = t.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    out[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                        String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if let bundlePath = app.appInfo.bundlePath() {
            absorb(URL(fileURLWithPath: bundlePath).appendingPathComponent("dm/env.txt"))
        }
        if let container {
            absorb(container.containerURL.appendingPathComponent("Documents/env.txt"))
        }
        return out
    }
}

// MARK: - 客体容器偏好 plist 的读写（保留原格式与其余键）

final class LCGamePrefs {
    let container: LCContainer
    let bundleIdentifier: String

    var prefsURL: URL {
        container.containerURL
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    private(set) var values: [String: Any] = [:]
    private var format: PropertyListSerialization.PropertyListFormat = .binary

    init(container: LCContainer, bundleIdentifier: String) {
        self.container = container
        self.bundleIdentifier = bundleIdentifier
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: prefsURL) else {
            values = [:]
            format = .binary
            return
        }
        var fmt: PropertyListSerialization.PropertyListFormat = .binary
        if let dict = (try? PropertyListSerialization.propertyList(from: data, format: &fmt)) as? [String: Any] {
            values = dict
            format = fmt
        }
    }

    @discardableResult
    func save() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: values, format: format, options: 0)
            try data.write(to: prefsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 启动器已保存的选择（字符串；数字按字符串读，与 LauncherSettings 的读法一致）
    func launcherValue(_ env: String) -> String? {
        guard let raw = values["launcher.\(env)"] else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// 写一条启动器选择：等于档案默认值时按引擎惯例删键，其余时候写字符串
    func setLauncherValue(_ setting: LCLauncherSetting, to value: String) {
        if setting.isDefault(value) {
            values.removeValue(forKey: "launcher.\(setting.env)")
        } else {
            values["launcher.\(setting.env)"] = value
        }
        save()
    }

    /// 恢复默认：清掉档案内全部变量的已保存选择
    func resetLauncherValues(_ settings: [LCLauncherSetting]) {
        for s in settings {
            values.removeValue(forKey: "launcher.\(s.env)")
        }
        save()
    }

    func hasLauncherValues(_ settings: [LCLauncherSetting]) -> Bool {
        settings.contains { values["launcher.\($0.env)"] != nil }
    }

    // MARK: 按键布局（DmPadCustom / DmPadCustomHades，与启动器键同文件共存）

    func padCustomDictionary(_ storeKey: String) -> [String: Any] {
        values[storeKey] as? [String: Any] ?? [:]
    }

    func setPadCustomDictionary(_ storeKey: String, _ dict: [String: [String: Double]]) {
        if dict.isEmpty {
            values.removeValue(forKey: storeKey)
        } else {
            values[storeKey] = dict
        }
        save()
    }
}
