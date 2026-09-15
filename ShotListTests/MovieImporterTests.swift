import XCTest
@testable import ShotList

/// 批量导入的推进逻辑。
///
/// 相册选片那一步没法自动化，所以「一次选多段」到底是怎么推进的，靠这里拿到证据：
/// 顺序不变、中间某段失败不打断后面的、失败算得准。
final class MovieImporterTests: XCTestCase {
    private struct PickupError: LocalizedError {
        let index: Int
        var errorDescription: String? { "第 \(index) 段打不开" }
    }

    func testRunsEveryItemInOrderAndCollectsFailuresWithoutStopping() async {
        var visited: [Int] = []
        var progress: [Int] = []

        let failures = await MovieImporter.run(
            Array(1...5),
            onProgress: { progress.append($0) },
            onEach: { item in
                visited.append(item)
                if item == 2 || item == 4 { throw PickupError(index: item) }
            }
        )

        XCTAssertEqual(visited, [1, 2, 3, 4, 5], "某一段失败不能中断后面的段")
        XCTAssertEqual(progress, [0, 1, 2, 3, 4], "每段开始前报一次下标")
        XCTAssertEqual(failures, ["第 2 段打不开", "第 4 段打不开"])
    }

    func testAllSucceedingReportsNothing() async {
        let failures = await MovieImporter.run([1, 2, 3]) { _ in }
        XCTAssertTrue(failures.isEmpty)
    }

    func testEmptySelectionTouchesNothing() async {
        var called = false
        let failures = await MovieImporter.run([Int]()) { _ in called = true }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(called)
    }

    func testEveryFailureIsCollectedInOrder() async {
        let failures = await MovieImporter.run(Array(1...3)) { item in
            throw PickupError(index: item)
        }
        XCTAssertEqual(failures, ["第 1 段打不开", "第 2 段打不开", "第 3 段打不开"])
    }
}
