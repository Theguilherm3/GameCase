//
//  LCAppInfo.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/5.
//

import Foundation

class LCContainer : ObservableObject, Hashable {
    @Published var folderName : String
    @Published var name : String
    @Published var isShared : Bool
    
    @Published var storageBookMark: Data?
    @Published var resolvedContainerURL: URL?
    @Published var bookmarkResolved = false
    var bookmarkResolveContinuation: UnsafeContinuation<(), Never>? = nil
    
    @Published var isolateAppGroup : Bool

    @Published var spoofIdentifierForVendor : Bool {
        didSet {
            if spoofIdentifierForVendor && spoofedIdentifier == nil {
                spoofedIdentifier = UUID().uuidString
            }
        }
    }
    public var spoofedIdentifier: String?
    private var infoDict : [String:Any]?
    public var containerURL : URL {
        if let resolvedContainerURL {
            return resolvedContainerURL
        }
        
        if isShared {
            return LCPath.lcGroupDataPath.appendingPathComponent("\(folderName)")
        } else {
            return LCPath.dataPath.appendingPathComponent("\(folderName)")
        }
    }
    private var infoDictUrl : URL {
        return containerURL.appendingPathComponent("LCContainerInfo.plist")
    }
    public var keychainGroupId : Int {
        get {
            if infoDict == nil {
                infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
            }
            guard let infoDict else {
                return -1
            }
            return infoDict["keychainGroupId"] as? Int ?? -1
        }
    }
    
    public var appIdentifier : String? {
        get {
            if infoDict == nil {
                infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
            }
            guard let infoDict else {
                return nil
            }
            return infoDict["appIdentifier"] as? String ?? nil
        }
    }
    
    /// 新建容器时的夹名生成器（GameCase 口径）：以游戏显示名为基名，让用户在文件 App 的
    /// Data/Application 下能直接认出哪个夹是哪款游戏。folderName 一经生成仍由 app 记录
    /// 持有为唯一真源、路径一律走记录拼装；这里只负责在新建时取一个干净且未被占用的名字。
    /// 消毒：去掉路径非法字符与控制字符、修剪首尾空白与圆点；消毒后为空回退 bundle id，
    /// 再为空回退 "Game"。去重范围：两个数据根（本机 Data/Application 与共享组
    /// Data/Application）下已存在的目录 + 本应用已有容器记录；冲突时追加「 2」「 3」序号。
    static func generateFolderName(displayName: String?, bundleIdentifier: String?, siblingFolderNames: [String]) -> String {
        let base = sanitizedFolderBase(displayName, fallback: bundleIdentifier)
        var taken = Set(siblingFolderNames)
        for root in [LCPath.dataPath, LCPath.lcGroupDataPath] {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                taken.formUnion(entries)
            }
        }
        if !taken.contains(base) {
            return base
        }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    static func sanitizedFolderBase(_ raw: String?, fallback: String?) -> String {
        func clean(_ value: String?) -> String {
            guard let value else { return "" }
            var cleaned = value.unicodeScalars.filter { scalar in
                !CharacterSet(charactersIn: "/:\\?%*|\"<>").contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar)
            }.map { Character($0) }
            // 首尾的空白与圆点在路径里易出问题（尾随圆点/纯圆点名），一并修剪
            while let first = cleaned.first, first == " " || first == "." { cleaned.removeFirst() }
            while let last = cleaned.last, last == " " || last == "." { cleaned.removeLast() }
            var result = String(cleaned)
            // 路径组件长度保护：UTF-8 不超过 120 字节
            while result.utf8.count > 120, !result.isEmpty {
                result.removeLast()
            }
            return result
        }
        let fromName = clean(raw)
        if !fromName.isEmpty { return fromName }
        let fromBundleId = clean(fallback)
        if !fromBundleId.isEmpty { return fromBundleId }
        return "Game"
    }

    /// 容器夹是否只是「空壳」：递归枚举后，除骨架空目录、顶层的
    /// LCContainerInfo.plist、以及 LCBootstrap 给每个容器 HOME 建的顶层
    /// tmp 软链之外，没有任何普通文件或其它软链。存档、数据包、偏好
    /// plist 等任何真实内容都会让判定不成立。夹不存在返回 false。
    /// 用途有二：旧形态记录收敛时判旧夹是否值得原样收编；孤儿清扫时
    /// 判未被引用的夹是否可删。两处都按「拿不准就当有内容」的保守
    /// 方向（枚举失败同样返回 false）。
    static func isEmptyContainerShell(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            return false
        }
        let rootPath = url.path
        for case let item as URL in enumerator {
            guard item.path.hasPrefix(rootPath + "/") else {
                return false
            }
            let rel = String(item.path.dropFirst(rootPath.count + 1))
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            if values.isSymbolicLink == true {
                // 骨架的一部分：LCBootstrap 建的顶层 tmp 软链；其余软链
                // 一律按有内容处理（可能指向真实数据）
                if rel == "tmp" {
                    continue
                }
                return false
            }
            if values.isDirectory == true {
                continue
            }
            if values.isRegularFile == true, rel == "LCContainerInfo.plist" {
                continue
            }
            return false
        }
        return true
    }

    /// 某夹名的容器夹在磁盘上是否存在且装有真实内容（非空壳）
    static func folderHasRealContent(folderName: String, isShared: Bool) -> Bool {
        let root = isShared ? LCPath.lcGroupDataPath : LCPath.dataPath
        let url = root.appendingPathComponent(folderName)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return !isEmptyContainerShell(at: url)
    }

    /// 清扫孤儿容器空壳：两个数据根下不被任何应用的容器记录引用、且
    /// 只是空壳（只有骨架空目录与 LCContainerInfo.plist、无任何真实
    /// 文件）的目录。历史时序里一次性生成的孤儿夹（如旧时序留下的
    /// UUID 空壳）不在任何记录里，卸载按记录删夹够不着，靠启动对账
    /// 与卸载后顺带清扫回收。删除条件严格同时成立才动手：未被引用
    /// （全部应用的容器名单 ∪ dataUUID）且空壳判定通过——装有
    /// romfs.img、存档、偏好等任何真实内容的目录一律不碰。
    /// 返回实际删除的夹名，供调用方同步文件夹名单。
    static func sweepOrphanContainerShells(apps: [LCAppModel]) -> [String] {
        var referenced = Set<String>()
        for app in apps {
            for container in app.appInfo.containers {
                referenced.insert(container.folderName)
            }
            if let dataUUID = app.appInfo.dataUUID {
                referenced.insert(dataUUID)
            }
        }
        let fm = FileManager.default
        var removed: [String] = []
        var roots = [LCPath.dataPath]
        if LCPath.lcGroupDataPath != LCPath.dataPath {
            roots.append(LCPath.lcGroupDataPath)
        }
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else {
                continue
            }
            for name in entries {
                guard !referenced.contains(name) else {
                    continue
                }
                let url = root.appendingPathComponent(name)
                guard isEmptyContainerShell(at: url) else {
                    continue
                }
                do {
                    try fm.removeItem(at: url)
                    removed.append(name)
                    NSLog("[GC] removed orphan container shell: \(name)")
                } catch {
                    NSLog("[GC] failed to remove orphan container shell \(name): \(error)")
                }
            }
        }
        return removed
    }

    init(folderName: String, name: String, isShared : Bool, isolateAppGroup: Bool = false, spoofIdentifierForVendor: Bool = false, bookmarkData: Data? = nil, resolvedContainerURL: URL? = nil) {
        self.folderName = folderName
        self.name = name
        self.isShared = isShared
        self.isolateAppGroup = isolateAppGroup
        self.spoofIdentifierForVendor = spoofIdentifierForVendor
        self.storageBookMark = bookmarkData
        self.resolvedContainerURL = resolvedContainerURL
    }
    
    convenience init(infoDict : [String : Any], isShared : Bool) {
        let bookmarkData : Data? = infoDict["bookmarkData"] as? Data
        
        self.init(folderName: infoDict["folderName"] as? String ?? "ERROR",
                  name: infoDict["name"] as? String ?? "ERROR",
                  isShared: isShared,
                  isolateAppGroup: false,
                  spoofIdentifierForVendor: false,
                  bookmarkData: bookmarkData,
                  resolvedContainerURL: nil
        )
        
        if let bookmarkData {

                do {
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)

                    self.resolvedContainerURL = url

                } catch {
                    print(error.localizedDescription)
                }

                self.bookmarkResolved = true
        }
        
        do {
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoDictUrl), format: nil)
            if let plistInfo = plistInfo as? [String : Any] {
                isolateAppGroup = plistInfo["isolateAppGroup"] as? Bool ?? false
                spoofIdentifierForVendor = plistInfo["spoofIdentifierForVendor"] as? Bool ?? false
                spoofedIdentifier = plistInfo["spoofedIdentifierForVendor"] as? String
            }
        } catch {
            
        }
    }
    
    func toDict() -> [String : Any] {
        var ans : [String: Any] = [
            "folderName" : folderName,
            "name" : name
        ]
        if let storageBookMark {
            ans["bookmarkData"] = storageBookMark
        }
        return ans
    }
    
    func makeLCContainerInfoPlist(appIdentifier : String, keychainGroupId : Int) {
        infoDict = [
            "appIdentifier" : appIdentifier,
            "name" : name,
            "keychainGroupId" : keychainGroupId,
            "isolateAppGroup" : isolateAppGroup,
            "spoofIdentifierForVendor": spoofIdentifierForVendor
        ]
        if let spoofedIdentifier {
            infoDict!["spoofedIdentifierForVendor"] = spoofedIdentifier
        }
        
        do {
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistData = try PropertyListSerialization.data(fromPropertyList: infoDict as Any, format: .binary, options: 0)
            try plistData.write(to: infoDictUrl)
        } catch {
            
        }
    }
    
    func reloadInfoPlist() {
        infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
    }

    func loadName() {
        reloadInfoPlist()
        guard let infoDict else {
            return
        }
        name = infoDict["name"] as? String ?? "ERROR"
        isolateAppGroup = infoDict["isolateAppGroup"] as? Bool ?? false
        spoofIdentifierForVendor = infoDict["spoofIdentifierForVendor"] as? Bool ?? false
        spoofedIdentifier = infoDict["spoofedIdentifierForVendor"] as? String
    }
    
    static func == (lhs: LCContainer, rhs: LCContainer) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension LCAppInfo {
    var containers : [LCContainer] {
        get {
            if self is BuiltInSideStoreAppInfo {
                let container = LCContainer(folderName: "", name: "SideStore", isShared: false)
                container.resolvedContainerURL = LCPath.docPath.appendingPathComponent("SideStore")
                return [container]
            }
            
            var upgrade = false
            // upgrade：只有 LCDataUUID、没有容器名单的旧形态记录（上游老
            // 版本形态，覆盖安装会原样继承）在此收敛出默认容器。
            // 旧实现直接拿 dataUUID 当夹名：dataUUID 停留在旧式 UUID 值时，
            // 它与首启正路（runApp 用 generateFolderName 生成游戏名夹）会
            // 在同一游戏上各建一夹——UUID 空壳 + 游戏名真身（双目录 bug）。
            // 收敛规则与正路对齐，二选一：
            // - dataUUID 命名的夹已在磁盘上且装有真实内容 → 原样收编，
            //   老数据不丢、夹名与 dataUUID 都不变；
            // - 其余（夹不存在或只是空壳）→ 按游戏名生成夹名，并先把
            //   dataUUID 改写为该名再写容器名单（两个 setter 各自落盘，
            //   先改 dataUUID 是让中间态也可被本垫片幂等重入收敛），
            //   此后模型快照、启动、LCBootstrap 与深链扩展读到的默认
            //   容器恒为同一个游戏名夹。
            if let oldDataUUID = dataUUID, containerInfo == nil {
                let convergedName: String
                if LCContainer.folderHasRealContent(folderName: oldDataUUID, isShared: isShared) {
                    convergedName = oldDataUUID
                } else {
                    convergedName = LCContainer.generateFolderName(displayName: displayName(), bundleIdentifier: bundleIdentifier(), siblingFolderNames: [])
                }
                if convergedName != oldDataUUID {
                    dataUUID = convergedName
                }
                containerInfo = [[
                    "folderName": convergedName,
                    "name": convergedName
                ]]
                upgrade = true
            }
            let dictArr = containerInfo as? [[String : Any]] ?? []
            return dictArr.map{ dict in
                let ans = LCContainer(infoDict: dict, isShared: isShared)
                if upgrade {
                    ans.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier()!, keychainGroupId: 0)
                }
                return ans
            }
        }
        set {
            containerInfo = newValue.map { container in
                return container.toDict()
            }
        }
    }

}
