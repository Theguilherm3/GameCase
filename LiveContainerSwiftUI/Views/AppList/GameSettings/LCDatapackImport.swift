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

struct LCDatapackImportView: View {
    let request: LCDatapackRequest
    let apps: [LCAppModel]
    var onFinished: () -> Void = {}

    @Environment(\.presentationMode) private var presentationMode

    @State private var target: LCAppModel?
    @State private var pickingFile = false
    @State private var pickedSource: URL?
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
                if fm.fileExists(atPath: tmp.path) {
                    try fm.removeItem(at: tmp)
                }
                guard fm.createFile(atPath: tmp.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let reader = try FileHandle(forReadingFrom: source)
                let writer = try FileHandle(forWritingTo: tmp)
                defer {
                    try? reader.close()
                    try? writer.close()
                }
                var written: Int64 = 0
                while true {
                    if box.cancelled {
                        try? fm.removeItem(at: tmp)
                        await MainActor.run { stage = .ready }
                        return
                    }
                    let chunk = reader.readData(ofLength: lcDatapackChunkSize)
                    if chunk.isEmpty { break }
                    writer.write(chunk)
                    written += Int64(chunk.count)
                    let done = written
                    await MainActor.run {
                        copiedBytes = done
                        if expected > 0 { progress = Double(done) / Double(expected) }
                    }
                }
                try writer.synchronize()
                // 校验：拷贝结果与源文件大小一致才替换正式文件
                guard Self.fileSize(tmp) == expected else {
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
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    stage = .failed("拷贝失败：\(error.localizedDescription)")
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
