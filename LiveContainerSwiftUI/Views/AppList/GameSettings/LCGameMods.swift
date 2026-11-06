//
//  LCGameMods.swift
//  LiveContainerSwiftUI
//
//  Mod 支持：照搬 NX2Apple 壳的 GameMods 方案（上游 #557）。玩家把散装
//  RomFS 替换文件按 mod 分夹放进数据容器 Documents/mods/<mod 名>/，
//  GC 在每次启动前按 NX2 同规则扫描、拼出 DM_ROMFS_OVERLAY，行级维护
//  进容器 Documents/env.txt——客体宿主 boot_env()（dm/ios main.m）启动
//  时先读 Documents/env.txt（优先于包内 dm/env.txt），hle_fs.c 挂载
//  RomFS 时逐文件先探 overlay、再查镜像本体，等于在 romfs.img 之上叠
//  一层散文件补丁：不改数据包本体、不动 romfs.id，数据包状态判定仍
//  只看 img（LCGameLibraryInfo.isDatapackReady），与本功能互不相干。
//
//  与 env 锁定逻辑的关系（LCGameProfile.envLockedValues）：该函数把
//  env.txt 里出现的键一律视为「被 env 文件固定」而在设置页锁定，
//  DM_ROMFS_OVERLAY 写入后同样落入这一口径——正确且无冲突：这行本来
//  就不该由启动器设置驱动，它由 mods 目录现状决定、GC 独占维护。
//  代价是玩家手写在 Documents/env.txt 里的 DM_ROMFS_OVERLAY 行会在
//  下次启动时被扫描结果覆盖（有 mods 按扫描写、无 mods 删行）——GC
//  自此是这一行的唯一写者，与 NX2 壳「壳现算的值优先」同义。
//
//  维护点：LCAppModel.runApp 的派发漏斗（与 LCPlayStats.beginSession
//  同处，已越过全部早退分支）——主页 / 牌组 / 列表 / 深链等入口最终都
//  过这里，且转交其他 LC 副本时由接手进程自己的漏斗维护。经桌面网
//  页剪辑 / 扩展直启客体时不经此漏斗，沿用上一次维护出的一行（mods
//  没变就仍然正确）。
//

import SwiftUI

enum LCGameMods {
    /// 一个生效中的 mod：文件夹名 + 解析出的 RomFS 根（绝对路径）
    struct EffectiveMod: Identifiable {
        let name: String
        let romfsPath: String
        var id: String { name }
    }

    static let envKey = "DM_ROMFS_OVERLAY"

    /// titleID：客体 bundle id 末段（org.nxnative.<titleID>），大写——
    /// 与 LCKnownGame.from 的归一化同法，也对齐 Atmosphere 目录惯例
    static func titleID(bundleIdentifier: String) -> String? {
        guard let last = bundleIdentifier.split(separator: ".").last, !last.isEmpty else {
            return nil
        }
        return last.uppercased()
    }

    /// NX2 GameMods.romfsFolders 同构：mods 夹内非点开头的文件夹按
    /// 名字 localizedStandard 顺序，逐个解析 RomFS 根——candidates 依
    /// 次为 romfs、atmosphere/contents/<titleID>/romfs、
    /// contents/<titleID>/romfs；都不在则文件夹根本身即 RomFS 根，
    /// 但顶层只有 exefs/atmosphere/contents 的（纯代码 mod 改的是代码、
    /// 引擎不吃；或只有结构层没有真文件）与空夹跳过。点开头的名字
    /// 跳过，即 NX2 的禁用约定（改名加「.」前缀 = 禁用）。多个 mod
    /// 替换同一文件时，overlay 串里先列者先被探到、先到者赢（与 NX2 /
    /// Mac 启动器一致）。
    static func effectiveMods(in mods: URL, titleID: String, _ fm: FileManager = .default) -> [EffectiveMod] {
        let names = ((try? fm.contentsOfDirectory(atPath: mods.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.compactMap { name in
            var dir: ObjCBool = false
            let mod = mods.appendingPathComponent(name)
            guard fm.fileExists(atPath: mod.path, isDirectory: &dir), dir.boolValue else { return nil }
            let candidates = ["romfs", "atmosphere/contents/\(titleID)/romfs", "contents/\(titleID)/romfs"]
                .map { mod.appendingPathComponent($0).path }
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                return EffectiveMod(name: name, romfsPath: found)
            }
            let top = ((try? fm.contentsOfDirectory(atPath: mod.path)) ?? []).filter { !$0.hasPrefix(".") }
            let codeOnly = !top.isEmpty && top.allSatisfy { ["exefs", "atmosphere", "contents"].contains($0.lowercased()) }
            return codeOnly || top.isEmpty ? nil : EffectiveMod(name: name, romfsPath: mod.path)
        }
    }

    /// DM_ROMFS_OVERLAY 的值：各 mod RomFS 根的真实绝对路径冒号连接，
    /// 无可用 mod 返回 nil。路径本身含冒号时不转义（与 NX2 同构）：
    /// 引擎按冒号拆分 overlay，这类夹名会错位——别给 mod 文件夹起带
    /// 冒号的名字。
    static func overlayValue(in mods: URL, titleID: String, _ fm: FileManager = .default) -> String? {
        let mods = effectiveMods(in: mods, titleID: titleID, fm)
        return mods.isEmpty ? nil : mods.map(\.romfsPath).joined(separator: ":")
    }

    // MARK: env.txt 维护

    /// 按容器当前 mods 现算并维护其 Documents/env.txt 的 overlay 行。
    /// 维护失败静默吞掉：mod 只是增强，绝不能挡游戏启动。
    static func refreshEnvOverlay(container: LCContainer, bundleIdentifier: String) {
        guard let titleID = titleID(bundleIdentifier: bundleIdentifier) else { return }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let overlay = overlayValue(in: documents.appendingPathComponent("mods", isDirectory: true), titleID: titleID)
        maintainEnvLine(envFile: documents.appendingPathComponent("env.txt"), key: envKey, value: overlay)
    }

    /// 启动漏斗入口：容器取 runApp 即将启动的那一个（与
    /// LCGameLibraryInfo.defaultContainer 同源：selected 优先）。
    static func refreshEnvOverlay(for app: LCAppModel) {
        guard let container = LCGameLibraryInfo.defaultContainer(for: app) else { return }
        refreshEnvOverlay(container: container, bundleIdentifier: app.bundleIdentifier)
    }

    /// 行级维护 env 文件中的一行 `KEY=VALUE`：
    /// - value 非 nil：文件中恰有一行该键、值即 value——替换首个旧行，
    ///   其余同键行删除（客体 boot 按首个同名键胜出，多行会让旧值残留
    ///   生效）；没有旧行则追加到文件末尾；
    /// - value 为 nil：删掉全部该键行；
    /// - 其余行（注释、空行、其他键、怪格式）逐字保留，连各自的行尾
    ///   符（\n / \r\n）都不动；
    /// - 文件不存在且 value 为 nil 时什么都不做，绝不建空文件；
    /// - 文件不是 UTF-8 时整体不动（客体同样按 UTF-8 读，读不出等于
    ///   没有这个文件，不能冒险按字节改）。
    /// 键的识别与 LCGameProfile.envLockedValues 同口径：整行去空白后
    /// 按首个「=」切分、键再去空白比对；注释行永远不算、原样保留。
    static func maintainEnvLine(envFile: URL, key: String, value: String?) {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: envFile.path)
        guard exists || value != nil else { return }
        var original = ""
        if exists {
            guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return }
            original = text
        }
        // 拆成（行内容, 行尾）对，行尾逐字保留
        var lines: [(content: String, ending: String)] = []
        var rest = original[original.startIndex...]
        while !rest.isEmpty {
            if let nl = rest.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                var end = rest.index(after: nl)
                if rest[nl] == "\r", end < rest.endIndex, rest[end] == "\n" {
                    end = rest.index(after: end)
                }
                lines.append((String(rest[..<nl]), String(rest[nl..<end])))
                rest = rest[end...]
            } else {
                lines.append((String(rest), ""))
                rest = rest[rest.endIndex...]
            }
        }
        func isKeyLine(_ content: String) -> Bool {
            let t = content.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { return false }
            if t == key { return true }
            guard let eq = t.firstIndex(of: "=") else { return false }
            return t[..<eq].trimmingCharacters(in: .whitespaces) == key
        }
        let newline = lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
        var out: [(content: String, ending: String)] = []
        var written = false
        for line in lines {
            if isKeyLine(line.content) {
                if let value, !written {
                    out.append(("\(key)=\(value)", line.ending.isEmpty ? newline : line.ending))
                    written = true
                }
                continue
            }
            out.append(line)
        }
        if let value, !written {
            if !out.isEmpty, out[out.count - 1].ending.isEmpty {
                out[out.count - 1].ending = newline
            }
            out.append(("\(key)=\(value)", newline))
        }
        let result = out.map { $0.content + $0.ending }.joined()
        guard result != original else { return }
        do {
            // 原地截断重写、不换文件，与 LCGamePrefs.save 同理（跟踪方看同一文件）
            if exists, let handle = try? FileHandle(forWritingTo: envFile) {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data(result.utf8))
                try handle.synchronize()
                try? handle.close()
            } else {
                try Data(result.utf8).write(to: envFile)
            }
        } catch {
            // 维护失败不挡启动，下次启动再试
        }
    }

    // MARK: 设置页呈现的数据

    /// 设置页「Mod」组的数据：默认容器 + 其当前生效 mod 名单（顺序即
    /// 优先级）。无容器返回 nil（整组自隐）。
    static func sectionData(for app: LCAppModel) -> (container: LCContainer, mods: [EffectiveMod])? {
        guard let container = LCGameLibraryInfo.defaultContainer(for: app),
              let titleID = titleID(bundleIdentifier: app.bundleIdentifier) else {
            return nil
        }
        let modsDir = container.containerURL.appendingPathComponent("Documents/mods", isDirectory: true)
        return (container, effectiveMods(in: modsDir, titleID: titleID))
    }
}

// MARK: - 设置页「Mod」组（只读呈现）

/// 显示当前生效的 mod 名单（名字 + 顺序 = 优先顺序）。没有启停开关：
/// 禁用按 NX2 约定把 mod 文件夹改名以「.」开头，说明写在本组内。
/// 排版与 LCSaveDataSectionView 同语言（自带同值常量）。
struct LCGameModsSectionView: View {
    let app: LCAppModel
    /// 宿主页面的状态刷新计数：数据包导入等动作关页后 bump，本组随之重算
    var refreshToken: Int = 0

    @State private var mods: [LCGameMods.EffectiveMod] = []
    @State private var hasContainer = false

    // 与 LCSaveDataSectionView / LCGameSettingsView 的 LCNXColor 同值
    private static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    private static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    private static let hairline = Color.white.opacity(0.08)

    var body: some View {
        // Group 透明包裹：无容器时条件为空，整组在宿主 VStack 里缺席
        // （不占间隔），与 LCSaveDataSectionView 的自隐同效
        Group {
            if hasContainer {
                section
            }
        }
        .onAppear { reload() }
        .onChange(of: refreshToken) { _ in reload() }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lc.mods.section".loc.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(Self.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                if mods.isEmpty {
                    Text("lc.mods.none".loc)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(mods.enumerated()), id: \.element.id) { index, mod in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 1)
                        }
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundColor(Self.cream)
                                .frame(minWidth: 18, alignment: .leading)
                            Text(mod.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("lc.mods.note".loc)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Self.hairline, lineWidth: 1)
            }
        }
    }

    private func reload() {
        if let data = LCGameMods.sectionData(for: app) {
            hasContainer = true
            mods = data.mods
        } else {
            hasContainer = false
            mods = []
        }
    }
}
