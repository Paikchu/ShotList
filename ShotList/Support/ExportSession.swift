import Foundation
import Combine

/// 导出结果属于生成时的输入；输入变化后，已完成和在途结果都不能重新变成可分享状态。
@MainActor
final class ExportSession: ObservableObject {
    @Published private(set) var package: ExportPackage?
    @Published private(set) var isBuilding = false
    @Published private(set) var isStale = false
    @Published var errorMessage: String?
    private var generation = UUID()

    func invalidate() {
        generation = UUID()
        if package != nil || isBuilding { isStale = true }
        discard(package)
        package = nil
        errorMessage = nil
    }

    func build(
        shots: [Shot], clipsDirectory: URL, scope: ExportScope, filmTitle: String,
        isCurrent: () -> Bool,
        builder: ([Shot], URL, ExportScope, String) async -> ExportOutcome = {
            await ExportPackageBuilder.buildOffMain(shots: $0, clipsDirectory: $1, scope: $2, filmTitle: $3)
        }
    ) async {
        guard !isBuilding else { return }
        let request = UUID()
        generation = request
        isBuilding = true
        errorMessage = nil
        let outcome = await builder(shots, clipsDirectory, scope, filmTitle)
        isBuilding = false
        guard generation == request, isCurrent() else {
            if case .success(let result) = outcome { discard(result) }
            invalidate()
            isStale = true
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
