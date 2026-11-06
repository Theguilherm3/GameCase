//
//  LCDatapackImport.swift
//  LiveContainerSwiftUI
//
//  数据包（romfs.img）导入：选目标游戏（从卡片长按菜单进入时已预选）→ 选 .img 文件
//  → 分块拷贝进该游戏默认容器的 Documents/romfs.img。数据包动辄数 GB：拷贝在后台
//  线程分块进行、带进度与取消，先写临时文件、校验大小一致后才替换正式文件，中途
//  失败不破坏已有数据包。
//

import SwiftUI
import UniformTypeIdentifiers

struct LCDatapackRequest: Identifiable {
    let id = UUID()
    let app: LCAppModel? // nil = 从库页按钮进入，先选游戏
}

/// 拷贝分块大小（放文件级常量：拷贝在后台线程跑，不能读主 actor 隔离的静态成员）
private let lcDatapackChunkSize = 4 * 1024 * 1024

/// 分块拷贝被取消（与真实 IO 失败分开报：取消回待选状态、不算导入失败）
enum LCDatapackCopyError: Error {
    case cancelled
}

struct LCDatapackImportView: View {
    let request: LCDatapackRequest
    let apps: [LCAppModel]
    var onFinished: () -> Void = {}

    @Environment(\.presentationMode) private var presentationMode

    @State private var target: LCAppModel?
    @State private var pickingFile = false
    @State private var pickingFolder = false
    @State private var pickedSource: URL?
    @State private var pendingFolderPlan: FolderPlan?
    @State private var confirmFolderImport = false
    @State private var confirmOverwrite = false
    @State private var stage: Stage = .ready
    @State private var progress: Double = 0
    @State private var copiedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var resultSize: Int64 = 0

    private enum Stage: Equatable {
        case ready
        case copying
        case done
        case failed(String)
    }

    private final class CancelBox { var cancelled = false }
    @State private var cancelBox = CancelBox()



    var body: some View {
        NavigationView {
            Group {
                if let target {
                    targetBody(target)
                } else {
                    gamePickerBody
                }
            }
            .navigationTitle("导入数据包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        cancelBox.cancelled = true
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
        .onAppear {
            if target == nil {
                target = request.app
            }
        }
        // 允许任意文件：.img 没有注册 UTI，用 [.data] 过滤会在文件选择器里把它置灰选不了
        // （IPA 能选是因为宿主为 ipa/tipa 声明了专用类型）。选到后仍由 pickedFile 按
        // 扩展名 == img 把关、startCopy 按大小校验，类型放宽不降低校验强度。
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedFile(url)
                }
            case .failure(let error):
                stage = .failed(error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedFolder(url)
                }
            case .failure(let error):
                stage = .failed(error.localizedDescription)
            }
        }
        .confirmationDialog("lc.datapack.folderOverwriteTitle".loc, isPresented: $confirmFolderImport, titleVisibility: .visible) {
            Button("lc.datapack.folderOverwriteButton".loc, role: .destructive) {
                if let plan = pendingFolderPlan {
                    startFolderImport(plan: plan)
                }
                pendingFolderPlan = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingFolderPlan = nil
            }
        } message: {
            Text("lc.datapack.folderOverwriteMessage".loc.localizeWithFormat(Self.sizeText(existingDatapackSize)))
        }
        .confirmationDialog("已有数据包", isPresented: $confirmOverwrite, titleVisibility: .visible) {
            Button("覆盖现有数据包", role: .destructive) {
                if let source = pickedSource {
                    startCopy(source: source)
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pickedSource = nil
            }
        } message: {
            Text("这个游戏已经导入过数据包（\(Self.sizeText(existingDatapackSize))），覆盖它吗？")
        }
    }

    // MARK: 选游戏

    private var gamePickerBody: some View {
        List {
            Section {
                ForEach(apps, id: \.self) { app in
                    Button {
                        target = app
                    } label: {
                        HStack(spacing: 12) {
                            gameIcon(app)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayName)
                                    .foregroundColor(.primary)
                                Text("版本 \(app.version)")
                                    .font(.footnote)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            datapackStatusText(for: app)
                        }
                    }
                }
            } header: {
                Text("数据包要导入哪个游戏？")
            }
        }
    }

    // MARK: 已选游戏

    @ViewBuilder
    private func targetBody(_ app: LCAppModel) -> some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                gameIcon(app)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.headline)
                    Text("版本 \(app.version)")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
                Spacer()
                datapackStatusText(for: app)
            }
            .padding(.horizontal)

            switch stage {
            case .ready:
                Text("数据包会写入这个游戏的数据容器（Documents/romfs.img），下次启动游戏时生效。")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                Button {
                    pickingFile = true
                } label: {
                    Text("选择 romfs.img 文件")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(LCGameTheme.accentColor)
                .padding(.horizontal)
                Button {
                    pickingFolder = true
                } label: {
                    Text("lc.datapack.chooseFolder".loc)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(LCGameTheme.accentColor)
                .padding(.horizontal)
                Text("lc.datapack.folderHint".loc)
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                if request.app == nil {
                    Button("换一款游戏") {
                        target = nil
                        pickedSource = nil
                    }
                    .foregroundColor(.gray)
                }
            case .copying:
                VStack(spacing: 10) {
                    ProgressView(value: progress)
                    Text("正在拷贝 \(Self.sizeText(copiedBytes)) / \(Self.sizeText(totalBytes))")
                        .font(.footnote)
                        .foregroundColor(.gray)
                    Button("取消拷贝") {
                        cancelBox.cancelled = true
                    }
                    .foregroundColor(.red)
                }
                .padding(.horizontal)
            case .done:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.green)
                    Text("数据包已导入（\(Self.sizeText(resultSize))）")
                        .font(.headline)
                    Button {
                        presentationMode.wrappedValue.dismiss()
                        onFinished()
                    } label: {
                        Text("完成")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LCGameTheme.accentColor)
                }
                .padding(.horizontal)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    Button("重新选择文件") {
                        stage = .ready
                        pickingFile = true
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
        }
        .padding(.top, 20)
    }

    // MARK: 拷贝

    private var existingDatapackSize: Int64 {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else { return 0 }
        let url = container.containerURL.appendingPathComponent("Documents/romfs.img")
        return Self.fileSize(url)
    }

    private func pickedFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "img" else {
            stage = .failed("所选文件不是 .img 数据包：\(url.lastPathComponent)")
            return
        }
        pickedSource = url
        if existingDatapackSize > 0 {
            confirmOverwrite = true
        } else {
            startCopy(source: url)
        }
    }

    private func startCopy(source: URL) {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else {
            stage = .failed("这个游戏尚无数据容器，请先启动一次游戏生成容器后再导入。")
            return
        }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let dest = documents.appendingPathComponent("romfs.img")
        let tmp = documents.appendingPathComponent("romfs.img.importing")
        let box = CancelBox()
        cancelBox = box
        stage = .copying
        progress = 0
        copiedBytes = 0
        totalBytes = 0

        Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                let expected = Self.fileSize(source)
                await MainActor.run { totalBytes = expected }
                guard expected > 0 else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let written = try await Self.chunkedCopyFile(from: source, to: tmp, isCancelled: { box.cancelled }) { done in
                    await MainActor.run {
                        copiedBytes = done
                        if expected > 0 { progress = Double(done) / Double(expected) }
                    }
                }
                // 校验：拷贝结果与源文件大小一致才替换正式文件
                guard written == expected, Self.fileSize(tmp) == expected else {
                    try? fm.removeItem(at: tmp)
                    throw CocoaError(.fileWriteUnknown)
                }
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: tmp, to: dest)
                await MainActor.run {
                    resultSize = expected
                    stage = .done
                }
            } catch LCDatapackCopyError.cancelled {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run { stage = .ready }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    stage = .failed("拷贝失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 分块拷贝单个文件（数据包导入的既有机制，文件夹导入与存档导入共用）：
    /// 每块 4MB，块前查取消，写完同步落盘，返回写入字节数。本函数只负责把
    /// 字节完整写到 dest（先清同名残留），大小校验与替换由调用方做。
    nonisolated static func chunkedCopyFile(from source: URL, to dest: URL, isCancelled: () -> Bool, onProgress: (Int64) async -> Void) async throws -> Int64 {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        guard fm.createFile(atPath: dest.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: dest)
        defer {
            try? reader.close()
            try? writer.close()
        }
        var written: Int64 = 0
        while true {
            if isCancelled() {
                throw LCDatapackCopyError.cancelled
            }
            let chunk = reader.readData(ofLength: lcDatapackChunkSize)
            if chunk.isEmpty { break }
            writer.write(chunk)
            written += Int64(chunk.count)
            await onProgress(written)
        }
        try writer.synchronize()
        return written
    }

    // MARK: 文件夹数据包导入

    /// 文件夹包的解析结果：包根 + 三个落点（romfs.img 走单文件同路替换、
    /// aoc 整夹替换、其余顶层文件原样进 Documents）
    struct FolderPlan {
        let root: URL
        let romfs: URL?
        let aocDirectory: URL?
        let extraFiles: [URL]
    }

    /// 解析所选文件夹为包：顶层有 romfs.img 或 aoc/ 即认；都没有时若顶层
    /// 恰有一个子文件夹且其内有包，按该子文件夹为包根（解压多套一层的常见
    /// 形态，只下钻一层）；仍无 → nil，调用方明确拒绝（散装 romfs 文件夹
    /// 引擎挂载不了，不静默拷一堆文件进去）。
    nonisolated static func resolveFolderPlan(at folder: URL) -> FolderPlan? {
        if let plan = folderPlan(at: folder) {
            return plan
        }
        let directories = topEntries(of: folder).directories
        if directories.count == 1, let plan = folderPlan(at: directories[0]) {
            return plan
        }
        return nil
    }

    nonisolated static func folderPlan(at folder: URL) -> FolderPlan? {
        let entries = topEntries(of: folder)
        let romfs = entries.files.first { $0.lastPathComponent.lowercased() == "romfs.img" }
        let aoc = entries.directories.first { $0.lastPathComponent.lowercased() == "aoc" }
        guard romfs != nil || aoc != nil else {
            return nil
        }
        let extras = entries.files.filter { $0 != romfs }
        return FolderPlan(root: folder, romfs: romfs, aocDirectory: aoc, extraFiles: extras)
    }

    /// 顶层条目（跳过 __MACOSX / .DS_Store / 点开头隐藏项，免得系统杂物进容器）
    nonisolated static func topEntries(of folder: URL) -> (files: [URL], directories: [URL]) {
        var files: [URL] = []
        var directories: [URL] = []
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: []) else {
            return (files, directories)
        }
        for item in items {
            let name = item.lastPathComponent
            if name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix(".") {
                continue
            }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                directories.append(item)
            } else if values?.isRegularFile == true {
                files.append(item)
            }
        }
        return (files, directories)
    }

    /// 目录内普通文件总字节（aoc 这种整夹计进度用）
    nonisolated static func treeSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// 目录内全部普通文件（相对路径升序，拷贝顺序稳定；跳过系统杂物）
    nonisolated static func treeFiles(_ url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [URL] = []
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let components = item.pathComponents
            if components.contains("__MACOSX") || components.contains(".DS_Store") {
                continue
            }
            files.append(item)
        }
        return files.sorted { $0.path < $1.path }
    }

    nonisolated static func relativePath(of url: URL, under base: URL) -> String {
        let path = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    private func pickedFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let plan = Self.resolveFolderPlan(at: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let plan else {
            stage = .failed("lc.datapack.folderRejected".loc)
            return
        }
        pendingFolderPlan = plan
        if folderPlanConflicts(plan) {
            confirmFolderImport = true
        } else {
            pendingFolderPlan = nil
            startFolderImport(plan: plan)
        }
    }

    /// 将被替换的现存内容：带 romfs 时已有数据包、或带 aoc 时已有 aoc 目录
    private func folderPlanConflicts(_ plan: FolderPlan) -> Bool {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else { return false }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let fm = FileManager.default
        if plan.romfs != nil, fm.fileExists(atPath: documents.appendingPathComponent("romfs.img").path) {
            return true
        }
        if plan.aocDirectory != nil, fm.fileExists(atPath: documents.appendingPathComponent("aoc").path) {
            return true
        }
        return false
    }

    /// 文件夹导入执行：全部内容先分块拷进 Documents/.folder-import-staging
    /// （与目标同卷），逐项过大小校验；全成才逐项替换落点（romfs.img 删旧
    /// 换新、aoc 整夹换、顶层文件同名换），任一步拷贝失败只删 staging、
    /// 现有数据包与 aoc 原样不动。进度/取消/分块与单文件导入共用一套。
    private func startFolderImport(plan: FolderPlan) {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else {
            stage = .failed("这个游戏尚无数据容器，请先启动一次游戏生成容器后再导入。")
            return
        }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let staging = documents.appendingPathComponent(".folder-import-staging", isDirectory: true)
        let box = CancelBox()
        cancelBox = box
        stage = .copying
        progress = 0
        copiedBytes = 0
        totalBytes = 0

        Task.detached(priority: .userInitiated) {
            let scoped = plan.root.startAccessingSecurityScopedResource()
            defer { if scoped { plan.root.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                if fm.fileExists(atPath: staging.path) {
                    try fm.removeItem(at: staging)
                }
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)

                var totalAcc: Int64 = 0
                if let romfs = plan.romfs { totalAcc += Self.fileSize(romfs) }
                if let aoc = plan.aocDirectory { totalAcc += Self.treeSize(aoc) }
                for file in plan.extraFiles { totalAcc += Self.fileSize(file) }
                guard totalAcc > 0 else {
                    throw CocoaError(.fileNoSuchFile)
                }
                // 定格为 let 再进各闭包捕获（var 捕获在并发闭包里会触发 Swift 6 模式诊断）
                let total = totalAcc
                await MainActor.run { totalBytes = total }

                var base: Int64 = 0
                func copyOne(_ source: URL, to dest: URL) async throws {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let start = base
                    let written = try await Self.chunkedCopyFile(from: source, to: dest, isCancelled: { box.cancelled }) { done in
                        let acc = start + done
                        await MainActor.run {
                            copiedBytes = acc
                            if total > 0 { progress = Double(acc) / Double(total) }
                        }
                    }
                    guard written == Self.fileSize(source) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    base += written
                }

                if let romfs = plan.romfs {
                    try await copyOne(romfs, to: staging.appendingPathComponent("romfs.img"))
                }
                if let aoc = plan.aocDirectory {
                    for file in Self.treeFiles(aoc) {
                        let relative = Self.relativePath(of: file, under: aoc)
                        try await copyOne(file, to: staging.appendingPathComponent("aoc").appendingPathComponent(relative))
                    }
                }
                for file in plan.extraFiles {
                    try await copyOne(file, to: staging.appendingPathComponent(file.lastPathComponent))
                }

                // 提交：staging 与目标同卷，逐项删旧换新（rename 级操作）
                func commit(_ staged: URL, to dest: URL) throws {
                    guard fm.fileExists(atPath: staged.path) else { return }
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                    }
                    try fm.moveItem(at: staged, to: dest)
                }
                if plan.romfs != nil {
                    try commit(staging.appendingPathComponent("romfs.img"), to: documents.appendingPathComponent("romfs.img"))
                }
                if plan.aocDirectory != nil {
                    try commit(staging.appendingPathComponent("aoc"), to: documents.appendingPathComponent("aoc"))
                }
                for file in plan.extraFiles {
                    try commit(staging.appendingPathComponent(file.lastPathComponent), to: documents.appendingPathComponent(file.lastPathComponent))
                }
                try? fm.removeItem(at: staging)

                let result = plan.romfs.map { Self.fileSize($0) } ?? total
                await MainActor.run {
                    resultSize = result
                    stage = .done
                }
            } catch LCDatapackCopyError.cancelled {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run { stage = .ready }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run {
                    stage = .failed("lc.datapack.folderFailed".loc.localizeWithFormat(error.localizedDescription))
                }
            }
        }
    }

    // MARK: 小件

    private func gameIcon(_ app: LCAppModel) -> some View {
        Group {
            if let icon = app.appInfo.iconIsDarkIcon(false) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .font(.title)
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func datapackStatusText(for app: LCAppModel) -> some View {
        let ready = LCGameLibraryInfo.isDatapackReady(container: LCGameLibraryInfo.defaultContainer(for: app))
        return HStack(spacing: 6) {
            Circle()
                .fill(ready ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(ready ? "数据包已就绪" : "未导入数据包")
                .font(.footnote)
                .foregroundColor(.gray)
        }
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize { return Int64(size) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
