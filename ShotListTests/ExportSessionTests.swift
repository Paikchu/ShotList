import XCTest
@testable import ShotList

final class ExportSessionTests: XCTestCase, @unchecked Sendable {
    private func package() throws -> ExportPackage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("zip fixture".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ExportPackage(id: UUID(), zipURL: url, clipCount: 1, pendingCount: 0, totalDuration: 1, byteCount: 11, createdAt: Date())
    }

    @MainActor
    func testCompletedPackageInvalidatesAndFreshBuildReplacesIt() async throws {
        let session = ExportSession()
        let first = try package()
        await session.build(shots: [], clipsDirectory: first.zipURL, scope: .everything, filmTitle: "", isCurrent: { true }, builder: { _, _, _, _ in .success(first) })
        XCTAssertEqual(session.package, first)
        session.invalidate()
        XCTAssertNil(session.package)
        XCTAssertTrue(session.isStale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.zipURL.path))
        let second = try package()
        await session.build(shots: [], clipsDirectory: second.zipURL, scope: .everything, filmTitle: "", isCurrent: { true }, builder: { _, _, _, _ in .success(second) })
        XCTAssertEqual(session.package, second)
        XCTAssertFalse(session.isStale)
    }

    @MainActor
    func testLateCompletionAfterInputChangeIsDiscarded() async throws {
        let session = ExportSession()
        let late = try package()
        let entered = expectation(description: "Builder entered")
        var continuation: CheckedContinuation<ExportOutcome, Never>?
        let task = Task {
            await session.build(shots: [], clipsDirectory: late.zipURL, scope: .everything, filmTitle: "", isCurrent: { true }, builder: { _, _, _, _ in
                await withCheckedContinuation { continuation = $0; entered.fulfill() }
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(session.isBuilding)
        session.invalidate()
        XCTAssertTrue(session.isStale)
        continuation?.resume(returning: .success(late))
        await task.value
        XCTAssertFalse(session.isBuilding)
        XCTAssertNil(session.package)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.zipURL.path))
    }

    @MainActor
    func testCurrentInputCheckRejectsResultBeforeViewChangeCallback() async throws {
        let session = ExportSession()
        let late = try package()
        await session.build(shots: [], clipsDirectory: late.zipURL, scope: .everything, filmTitle: "", isCurrent: { false }, builder: { _, _, _, _ in .success(late) })
        XCTAssertNil(session.package)
        XCTAssertTrue(session.isStale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.zipURL.path))
    }
}
