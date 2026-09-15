import XCTest
@testable import ShotList

/// 停在打包中途用：拿到运行上下文和一个可以手动放行的续体。
final class ExportRunProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var run: ExportRun?
    private var continuation: CheckedContinuation<ExportOutcome, Never>?

    func attach(_ run: ExportRun) { lock.lock(); self.run = run; lock.unlock() }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return run?.cancellation.isCancelled ?? false }

    func store(_ continuation: CheckedContinuation<ExportOutcome, Never>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func resume(_ outcome: ExportOutcome) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

final class ExportSessionTests: XCTestCase, @unchecked Sendable {
    private func package() throws -> ExportPackage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data("zip fixture".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ExportPackage(id: UUID(), zipURL: url, clipCount: 1, pendingCount: 0, totalDuration: 1, byteCount: 11, createdAt: Date())
    }

    private func request(_ url: URL, option: ExportTranscodeOption = .original) -> ExportRequest {
        ExportRequest(shots: [], clipsDirectory: url, scope: .everything, option: option)
    }

    @MainActor
    func testCompletedPackageInvalidatesAndFreshBuildReplacesIt() async throws {
        let session = ExportSession()
        let first = try package()
        await session.build(request(first.zipURL), isCurrent: { true }, builder: { _, _ in .success(first) })
        XCTAssertEqual(session.package, first)
        session.invalidate()
        XCTAssertNil(session.package)
        XCTAssertTrue(session.isStale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.zipURL.path))
        let second = try package()
        await session.build(request(second.zipURL), isCurrent: { true }, builder: { _, _ in .success(second) })
        XCTAssertEqual(session.package, second)
        XCTAssertFalse(session.isStale)
    }

    @MainActor
    func testLateCompletionAfterInputChangeIsDiscarded() async throws {
        let session = ExportSession()
        let late = try package()
        let entered = expectation(description: "Builder entered")
        let probe = ExportRunProbe()
        let task = Task {
            await session.build(request(late.zipURL), isCurrent: { true }, builder: { _, _ in
                await withCheckedContinuation { probe.store($0); entered.fulfill() }
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(session.isBuilding)
        session.invalidate()
        XCTAssertTrue(session.isStale)
        probe.resume(.success(late))
        await task.value
        XCTAssertFalse(session.isBuilding)
        XCTAssertNil(session.package)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.zipURL.path))
    }

    @MainActor
    func testCurrentInputCheckRejectsResultBeforeViewChangeCallback() async throws {
        let session = ExportSession()
        let late = try package()
        await session.build(request(late.zipURL), isCurrent: { false }, builder: { _, _ in .success(late) })
        XCTAssertNil(session.package)
        XCTAssertTrue(session.isStale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.zipURL.path))
    }

    /// 输入一变就把在途那次打包作废：转码一段素材是几十秒的事，
    /// 不能让用户等一次已经没人要的导出。作废信号要真的能传到后台侧。
    @MainActor
    func testInvalidateSignalsCancellationToRunningBuild() async throws {
        let session = ExportSession()
        let late = try package()
        let entered = expectation(description: "Builder entered")
        let probe = ExportRunProbe()
        let task = Task {
            await session.build(request(late.zipURL), isCurrent: { true }, builder: { _, run in
                probe.attach(run)
                entered.fulfill()
                return await withCheckedContinuation { probe.store($0) }
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(probe.isCancelled)
        session.invalidate()
        XCTAssertTrue(probe.isCancelled)
        probe.resume(.failure("cancelled"))
        await task.value
        XCTAssertNil(session.package)
        XCTAssertNil(session.errorMessage)
    }

    /// 进度只在打包期间展示，结束后要收掉，不能挂在界面上。
    @MainActor
    func testProgressIsPublishedDuringBuildAndClearedAfterwards() async throws {
        let session = ExportSession()
        let result = try package()
        var seenDuringBuild: ExportProgress?
        await session.build(request(result.zipURL), isCurrent: { true }, builder: { _, run in
            await run.publish(ExportProgress(phase: .transcoding, completed: 1, total: 4))
            seenDuringBuild = session.progress
            await run.publish(ExportProgress(phase: .packaging, completed: 4, total: 4))
            return .success(result)
        })
        XCTAssertEqual(seenDuringBuild?.text, "正在转码 2 / 4 段")
        XCTAssertEqual(seenDuringBuild?.fraction, 0.25)
        XCTAssertNil(session.progress)
        XCTAssertEqual(session.package, result)
    }
}
