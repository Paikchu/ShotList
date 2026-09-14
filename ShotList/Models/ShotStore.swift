import Foundation
import SwiftUI

/// 分镜数据仓库。
///
/// 职责：
/// - 维护内存中的分镜列表，并持久化为 JSON（Application Support/ShotList/shots.json）
/// - 管理磁盘上的分镜视频文件（Documents/分镜视频）
///
/// 由于 Documents 目录对「文件」App 与 Finder 可见（Info.plist 中开启了
/// `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`），
/// 用户可以直接把拍摄好的分镜视频拖到电脑上。
@MainActor
final class ShotStore: ObservableObject {

    /// 全部分镜，按拍摄顺序排列
    @Published private(set) var shots: [Shot] = []

    private let fileManager: FileManager
    private let metadataURL: URL

    /// 分镜视频统一存放目录
    let clipsDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? documents

        let supportDirectory = applicationSupport.appendingPathComponent("ShotList", isDirectory: true)
        self.clipsDirectory = documents.appendingPathComponent("分镜视频", isDirectory: true)
        self.metadataURL = supportDirectory.appendingPathComponent("shots.json", isDirectory: false)

        createDirectoryIfNeeded(supportDirectory)
        createDirectoryIfNeeded(clipsDirectory)
        load()
    }

    // MARK: - 统计

    /// 已拍摄的镜头数量
    var recordedCount: Int { shots.filter(\.hasClip).count }

    /// 今日已拍摄的镜头数量
    var todayRecordedCount: Int {
        let today = Date()
        return shots.filter { $0.status(relativeTo: today) == .shotToday }.count
    }

    /// 今日仍未拍摄的镜头数量
    var todayPendingCount: Int { shots.count - todayRecordedCount }

    /// 全部已拍视频的总时长（秒）
    var totalDuration: TimeInterval {
        shots.compactMap(\.clipDuration).reduce(0, +)
    }

    /// 已拍视频占用空间（字节）
    var totalClipBytes: Int64 {
        shots.compactMap { clipURL(for: $0) }.reduce(into: Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
    }

    /// 拍摄进度 0…1
    var progress: Double {
        shots.isEmpty ? 0 : Double(recordedCount) / Double(shots.count)
    }

    /// 今日拍摄进度 0…1
    var todayProgress: Double {
        shots.isEmpty ? 0 : Double(todayRecordedCount) / Double(shots.count)
    }

    /// 下一个可用编号
    var nextNumber: Int { (shots.map(\.number).max() ?? 0) + 1 }

    func shot(withID id: Shot.ID) -> Shot? {
        shots.first { $0.id == id }
    }

    func index(of id: Shot.ID) -> Int? {
        shots.firstIndex { $0.id == id }
    }

    /// 某个分镜对应视频的磁盘位置
    func clipURL(for shot: Shot) -> URL? {
        guard let fileName = shot.clipFileName else { return nil }
        let url = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 增

    /// 新建一个分镜，编号接在末尾
    @discardableResult
    func addShot(title: String = "", note: String = "") -> Shot {
        let shot = Shot(number: nextNumber, title: title, note: note)
        shots.append(shot)
        normalizeNumbers()
        persist()
        return shot
    }

    /// 一次性批量新建多个空白分镜，对应「一次录完 1、2、3、4 号镜头」的场景
    @discardableResult
    func addShots(count: Int) -> [Shot] {
        guard count > 0 else { return [] }
        var created: [Shot] = []
        for _ in 0..<count {
            created.append(Shot(number: shots.count + created.count + 1))
        }
        shots.append(contentsOf: created)
        normalizeNumbers()
        persist()
        return created
    }

    /// 复制一个已有分镜（不含视频）
    @discardableResult
    func duplicate(_ shot: Shot) -> Shot {
        var copy = Shot(number: nextNumber, title: shot.title, note: shot.note)
        if let index = index(of: shot.id) {
            copy.number = index + 2
            shots.insert(copy, at: index + 1)
        } else {
            shots.append(copy)
        }
        normalizeNumbers()
        persist()
        return copy
    }

    // MARK: - 改

    /// 更新分镜内容。若编号发生变化，则把它移动到对应位置。
    func update(_ edited: Shot) {
        guard let currentIndex = index(of: edited.id) else { return }

        var updated = edited
        updated.clipFileName = shots[currentIndex].clipFileName
        updated.recordedAt = shots[currentIndex].recordedAt
        updated.clipDuration = shots[currentIndex].clipDuration
        shots[currentIndex] = updated

        let targetIndex = min(max(updated.number, 1), shots.count) - 1
        if targetIndex != currentIndex {
            let moved = shots.remove(at: currentIndex)
            shots.insert(moved, at: targetIndex)
        }

        normalizeNumbers()
        persist()
    }

    /// 按列表顺序重新编号（始终保持 1、2、3… 连续）
    func normalizeNumbers() {
        for index in shots.indices where shots[index].number != index + 1 {
            shots[index].number = index + 1
        }
    }

    /// 拖拽排序
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        shots.move(fromOffsets: source, toOffset: destination)
        normalizeNumbers()
        persist()
    }

    // MARK: - 删

    func delete(_ shot: Shot) {
        guard let index = index(of: shot.id) else { return }
        removeClipFile(for: shots[index])
        shots.remove(at: index)
        normalizeNumbers()
        persist()
    }

    func deleteShots(withIDs ids: [Shot.ID]) {
        for shot in shots where ids.contains(shot.id) {
            removeClipFile(for: shot)
        }
        shots.removeAll { ids.contains($0.id) }
        normalizeNumbers()
        persist()
    }

    /// 删除全部分镜与视频（用于「清空重来」）
    func deleteEverything() {
        try? fileManager.removeItem(at: clipsDirectory)
        createDirectoryIfNeeded(clipsDirectory)
        shots.removeAll()
        persist()
    }

    // MARK: - 视频文件

    /// 把一段视频挂到一个分镜上。
    ///
    /// - Parameters:
    ///   - sourceURL: 临时文件位置（相机录制或相册导入产生）
    ///   - duration: 视频时长（秒）
    ///   - shotID: 目标分镜
    func attachClip(from sourceURL: URL, duration: TimeInterval?, to shotID: Shot.ID) throws {
        guard let index = index(of: shotID) else { return }

        removeClipFile(for: shots[index])

        let number = shots[index].number
        let fileName = "镜头\(number)_\(Self.timestampToken()).mov"
        let destination = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try? fileManager.removeItem(at: sourceURL)

        shots[index].clipFileName = fileName
        shots[index].recordedAt = Date()
        shots[index].clipDuration = duration
        persist()
    }

    /// 移除某个分镜上的视频，保留分镜本身
    func removeClip(for shotID: Shot.ID) {
        guard let index = index(of: shotID) else { return }
        removeClipFile(for: shots[index])
        shots[index].clipFileName = nil
        shots[index].recordedAt = nil
        shots[index].clipDuration = nil
        persist()
    }

    private func removeClipFile(for shot: Shot) {
        guard let fileName = shot.clipFileName else { return }
        let url = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: url)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([Shot].self, from: data) else {
            return
        }

        // 视频文件可能已被用户从「文件」App 里删除，这里做一次一致性校正
        shots = decoded.map { shot in
            var fixed = shot
            if let fileName = fixed.clipFileName {
                let url = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)
                if !fileManager.fileExists(atPath: url.path) {
                    fixed.clipFileName = nil
                    fixed.recordedAt = nil
                    fixed.clipDuration = nil
                }
            }
            return fixed
        }
        normalizeNumbers()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shots) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func timestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
