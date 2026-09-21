import Foundation
import Combine

/// 导出结果属于生成时的输入；输入变化后，已完成结果保留在磁盘上供已发起的分享继续读取，
/// 但在界面上标记为过期；在途结果不能重新变成可分享状态。
@MainActor
final class ExportSession: ObservableObject {
    @Published private(set) var package: ExportPackage?
    @Published private(set) var isBuilding = false
    @Published private(set) var isStale = false
    /// 打包进度。转码一段素材是几十秒级别的事，界面靠它说明「还在动、动到哪了」。
    @Published private(set) var progress: ExportProgress?
    /// 用户已点「停止」，打包侧还没有真正停下。
    ///
    /// 取消信号只在下一段素材开始之前才会被查看（转码本身不改），所以点了「停止」到
    /// `build` 返回之间可能还隔着当前那一段——界面靠这个标记如实显示「停止中」，
    /// 不能一直摆着一个点了没反应的进度条。
    @Published private(set) var isStopping = false
    @Published var errorMessage: String?
    private var generation = UUID()
    /// 在途那次打包的取消信号。
    ///
    /// 输入一变（改了范围、改了格式、动了素材）这次导出就已经作废：转码要几十秒
    /// 一段，不能因为结果没人要了还让用户接着等、让设备接着转。
    private var cancellation: ExportCancellation?

    func invalidate() {
        cancellation?.cancel()
        cancellation = nil
        generation = UUID()
        progress = nil
        if package != nil || isBuilding { isStale = true }
        // 不在这里删除已生成的包。ShareLink 可能仍在系统分享面板或目标 App 中读取它；
        // 旧包在下一次成功生成新包时替换，或由应用启动时的 cleanUp() 统一回收。
        errorMessage = nil
    }

    /// 用户主动停下在途那次打包。
    ///
    /// 与 `invalidate()` 是两回事：输入没变，之前生成的包（若有）仍然对应当前设定，
    /// 所以这里不置「过期」，也不当成失败提示——停下就是用户要的结果。
    /// 真正收尾在 `build` 里：返回后看到 `isStopping`，丢掉这次的产物，其余状态原样保留。
    func stop() {
        guard isBuilding, !isStopping else { return }
        isStopping = true
        progress = nil
        cancellation?.cancel()
    }

    func build(
        _ request: ExportRequest,
        isCurrent: () -> Bool,
        builder: (ExportRequest, ExportRun) async -> ExportOutcome = {
            await ExportPackageBuilder.buildOffMain($0, run: $1)
        }
    ) async {
        guard !isBuilding else { return }
        let token = UUID()
        generation = token
        let run = ExportRun(publish: { [weak self] update in
            await self?.publish(update)
        })
        cancellation = run.cancellation
        isBuilding = true
        errorMessage = nil
        progress = nil

        let outcome = await builder(request, run)

        let stoppedByUser = isStopping
        cancellation = nil
        isBuilding = false
        isStopping = false
        progress = nil
        // 输入变化优先于「用户停止」：输入变了，已有的包本来就该标为过期
        guard generation == token, isCurrent() else {
            if case .success(let result) = outcome { discard(result) }
            invalidate()
            isStale = true
            return
        }
        if stoppedByUser {
            // 停得太晚、包其实已经打好了也不要：用户点的是「停止」。
            // 取消翻译成的失败文案（`打包失败：…`）同样不展示。
            if case .success(let result) = outcome { discard(result) }
            return
        }
        switch outcome {
        case .success(let result):
            discard(package)
            package = result
            isStale = false
            Haptics.success()
        case .failure(let message):
            errorMessage = message
            Haptics.error()
        }
    }

    /// 进度只在这里落地：打包侧在后台线程，写界面的状态统一回主协程。
    private func publish(_ update: ExportProgress) {
        // 已经点了停止：在途的最后一次回传不该让进度条重新冒出来
        guard !isStopping else { return }
        progress = update
    }

    private func discard(_ package: ExportPackage?) {
        guard let package else { return }
        try? FileManager.default.removeItem(at: package.zipURL)
        let directory = package.zipURL.deletingLastPathComponent()
        if directory.deletingLastPathComponent().lastPathComponent == "ShotListExport",
           UUID(uuidString: directory.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
