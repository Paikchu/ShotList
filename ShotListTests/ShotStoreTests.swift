import XCTest
@testable import ShotList

final class IsolatedFileManager: FileManager, @unchecked Sendable {
    let root: URL
    var failingRemovals: Set<String> = []
    var onFailedRemoval: (() throws -> Void)?
    override func removeItem(at URL: URL) throws {
        if failingRemovals.contains(URL.lastPathComponent) {
            try onFailedRemoval?()
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try super.removeItem(at: URL)
    }
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent(directory == .documentDirectory ? "Documents" : "Support")]
    }
}

final class ShotStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private func assertAsyncThrows(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected error", file: file, line: line) }
        catch {}
    }

    private func fixture() throws -> (URL, IsolatedFileManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, IsolatedFileManager(root: root))
    }

    @MainActor
    func testUnreadableMetadataProtectsFilesAndBlocksAllMutations() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "Keep me"))
        let source = root.appendingPathComponent("source.mov")
        try Data("test video".utf8).write(to: source)
        try await store.addClip(from: source, duration: 1, to: shot.id)
        let metadata = root.appendingPathComponent("Support/ShotList/shots.json")
        let good = try Data(contentsOf: metadata)
        let broken = Data("invalid JSON".utf8)
        try broken.write(to: metadata)
        let blocked = ShotStore(fileManager: fm)
        XCTAssertNotNil(blocked.loadError)
        XCTAssertTrue(blocked.orphanFileNames.isEmpty)
        XCTAssertNil(blocked.addShot())
        XCTAssertTrue(blocked.addShots(count: 3).isEmpty)
        XCTAssertNil(blocked.insertShot(below: shot.id))
        XCTAssertNil(blocked.duplicate(shot))
        blocked.update(shot)
        blocked.move(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        blocked.delete(shot)
        blocked.deleteEverything()
        blocked.removeAllClips(for: shot.id)
        blocked.refreshStorageStats()
        XCTAssertFalse(blocked.normalize())
        XCTAssertEqual(blocked.removeOrphanFiles(), 0)
        try Data("retry source".utf8).write(to: source)
        await assertAsyncThrows { try await blocked.addClip(from: source, duration: 1, to: shot.id) }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: metadata), broken)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).count, 1)
        try good.write(to: metadata)
        blocked.retryLoad()
        XCTAssertNil(blocked.loadError)
        XCTAssertEqual(blocked.shots.first?.note, "Keep me")
        XCTAssertEqual(blocked.clipCount, 1)
        XCTAssertNil(ShotStore(fileManager: fm).loadError)
    }

    @MainActor
    func testMissingMetadataWithExistingVideoIsNotNewLibrary() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        XCTAssertNil(store.loadError)
        try Data("existing".utf8).write(to: store.clipsDirectory.appendingPathComponent("old.mov"))
        let blocked = ShotStore(fileManager: fm)
        XCTAssertNotNil(blocked.loadError)
        XCTAssertEqual(blocked.removeOrphanFiles(), 0)
        XCTAssertNil(blocked.addShot())
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Support/ShotList/shots.json").path))
    }

    @MainActor
    func testMetadataDirectoryIsReadFailure() async throws {
        let (root, fm) = try fixture()
        _ = ShotStore(fileManager: fm)
        try fm.createDirectory(at: root.appendingPathComponent("Support/ShotList/shots.json"), withIntermediateDirectories: true)
        let blocked = ShotStore(fileManager: fm)
        XCTAssertNotNil(blocked.loadError)
        XCTAssertNil(blocked.addShot())
    }

    @MainActor
    func testFirstLaunchAndValidEmptyLibrary() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        XCTAssertNil(store.loadError)
        XCTAssertNotNil(store.addShot())
        store.deleteEverything()
        let reopened = ShotStore(fileManager: fm)
        XCTAssertNil(reopened.loadError)
        XCTAssertTrue(reopened.shots.isEmpty)
        XCTAssertNotNil(reopened.addShot())
    }
    @MainActor
    func testClipWriteFailurePreservesSourceAndCanRetry() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "Original"))
        let metadata = root.appendingPathComponent("Support/ShotList/shots.json")
        let good = try Data(contentsOf: metadata)
        try fm.removeItem(at: metadata)
        try fm.createDirectory(at: metadata, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.mov")
        let video = Data("source video".utf8)
        try video.write(to: source)
        await assertAsyncThrows { try await store.addClip(from: source, duration: 1, to: shot.id) }
        XCTAssertEqual(try Data(contentsOf: source), video)
        XCTAssertTrue(store.shots[0].clips.isEmpty)
        XCTAssertEqual(store.clipCount, 0)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).isEmpty)
        try fm.removeItem(at: metadata)
        try good.write(to: metadata)
        XCTAssertTrue(ShotStore(fileManager: fm).shots[0].clips.isEmpty)
        try await store.addClip(from: source, duration: 1, to: shot.id)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        let reopened = ShotStore(fileManager: fm)
        XCTAssertEqual(reopened.clipCount, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.clipURL(for: reopened.shots[0]))), video)
    }

    @MainActor
    func testEncodingFailureDoesNotConsumeVideo() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot())
        let metadata = root.appendingPathComponent("Support/ShotList/shots.json")
        let before = try Data(contentsOf: metadata)
        let source = root.appendingPathComponent("source.mov")
        try Data("video".utf8).write(to: source)
        await assertAsyncThrows { try await store.addClip(from: source, duration: .nan, to: shot.id) }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertTrue(store.shots[0].clips.isEmpty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).isEmpty)
    }

    @MainActor
    func testFailedMetadataMutationsPreserveCommittedRecordsAndFiles() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let first = try XCTUnwrap(store.addShot(note: "First"))
        _ = store.addShot(note: "Second")
        let source = root.appendingPathComponent("source.mov")
        try Data("video".utf8).write(to: source)
        try await store.addClip(from: source, duration: 1, to: first.id)
        let original = store.shots
        let clip = try XCTUnwrap(original[0].clips.first)
        let originalURL = store.clipsDirectory.appendingPathComponent(clip.fileName)
        let metadata = root.appendingPathComponent("Support/ShotList/shots.json")
        let good = try Data(contentsOf: metadata)
        try fm.removeItem(at: metadata)
        try fm.createDirectory(at: metadata, withIntermediateDirectories: false)
        var edited = original[0]
        edited.note = "Changed"
        XCTAssertFalse(store.update(edited))
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.shots, original)
        XCTAssertNil(store.addShot())
        XCTAssertTrue(store.addShots(count: 2).isEmpty)
        XCTAssertNil(store.insertShot(below: first.id))
        XCTAssertNil(store.duplicate(first))
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(store.shots, original)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path), [clip.fileName])
        store.removeClip(clip.id, from: first.id)
        store.removeAllClips(for: first.id)
        store.delete(first)
        store.deleteEverything()
        XCTAssertEqual(store.shots, original)
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("video".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path), [clip.fileName])
        try fm.removeItem(at: metadata)
        try good.write(to: metadata)
        XCTAssertEqual(ShotStore(fileManager: fm).shots, original)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let reopened = ShotStore(fileManager: fm)
        XCTAssertEqual(reopened.shots[1].id, first.id)
        XCTAssertTrue(reopened.shots[1].clips[0].fileName.hasPrefix("镜头02_"))
        XCTAssertFalse(fm.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.clipURL(for: reopened.shots[1]))), Data("video".utf8))
        store.removeAllClips(for: first.id)
        XCTAssertTrue(ShotStore(fileManager: fm).shots[1].clips.isEmpty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).isEmpty)
    }

    @MainActor
    func testReconciliationWriteFailureKeepsCommittedReferences() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot())
        let source = root.appendingPathComponent("source.mov")
        try Data("video".utf8).write(to: source)
        try await store.addClip(from: source, duration: 1, to: shot.id)
        let original = store.shots
        let clipURL = try XCTUnwrap(store.clipURL(for: original[0]))
        let metadata = root.appendingPathComponent("Support/ShotList/shots.json")
        let good = try Data(contentsOf: metadata)
        try fm.removeItem(at: clipURL)
        try fm.removeItem(at: metadata)
        try fm.createDirectory(at: metadata, withIntermediateDirectories: false)
        store.refreshStorageStats()
        XCTAssertEqual(store.shots, original)
        XCTAssertNotNil(store.saveError)
        try fm.removeItem(at: metadata)
        try good.write(to: metadata)
        store.refreshStorageStats()
        XCTAssertTrue(store.shots[0].clips.isEmpty)
        XCTAssertTrue(ShotStore(fileManager: fm).shots[0].clips.isEmpty)
    }

    @MainActor
    func testDeletedImportTargetThrowsAndImportCleansItsOwnedSource() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot())
        store.delete(shot)
        let source = root.appendingPathComponent("import-test.mov")
        try Data("test source".utf8).write(to: source)
        await assertAsyncThrows { try await store.addClip(from: source, duration: 1, to: shot.id) }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        do {
            try await ImportedMovie(url: source).save(to: store, shotID: shot.id)
            XCTFail("Import reported success for a deleted target")
        } catch { XCTAssertTrue(error is ShotStoreError) }
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertTrue(store.shots.isEmpty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).isEmpty)
    }

    @MainActor
    func testSameTimestampReorderPreservesIdentityAndRepairsLegacyNames() async throws {
        let (root, fm) = try fixture()
        let initial = ShotStore(fileManager: fm)
        let clips = (1...2).map { ShotClip(fileName: String(format: "镜头%02d_20260915_120000.mov", $0), duration: 1, recordedAt: Date()) }
        var original = [Shot(number: 1, note: "A"), Shot(number: 2, note: "B")]
        for i in original.indices {
            original[i].clips = [clips[i]]
            try Data(original[i].note.utf8).write(to: initial.clipsDirectory.appendingPathComponent(clips[i].fileName))
        }
        let metadata = root.appendingPathComponent("Support/ShotList/shots.json")
        let good = try JSONEncoder().encode(original)
        try good.write(to: metadata)
        let store = ShotStore(fileManager: fm)
        // JSON failure must leave both original videos and references intact.
        try fm.removeItem(at: metadata)
        try fm.createDirectory(at: metadata, withIntermediateDirectories: false)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(store.shots, original)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path)), Set(clips.map(\.fileName)))
        try fm.removeItem(at: metadata)
        try good.write(to: metadata)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let reopened = ShotStore(fileManager: fm)
        XCTAssertEqual(reopened.shots.map(\.id), original.reversed().map(\.id))
        for shot in reopened.shots {
            XCTAssertTrue(shot.clips[0].fileName.hasPrefix(String(format: "镜头%02d_", shot.number)))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.clipURL(for: shot))), Data(shot.note.utf8))
        }
        XCTAssertFalse(reopened.normalize())
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).count, 2)
        // Legacy records can have correct numbers but stale file-name prefixes.
        var legacy = reopened.shots.reversed().map { $0 }
        for i in legacy.indices { legacy[i].number = i + 1 }
        try JSONEncoder().encode(legacy).write(to: metadata)
        let repaired = ShotStore(fileManager: fm)
        for shot in repaired.shots {
            XCTAssertTrue(shot.clips[0].fileName.hasPrefix(String(format: "镜头%02d_", shot.number)))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(repaired.clipURL(for: shot))), Data(shot.note.utf8))
        }
        XCTAssertEqual(ShotStore(fileManager: fm).shots, repaired.shots)
    }

    @MainActor
    func testDeletionFailuresKeepReferencesAndCountOnlyRemovedOrphans() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "Keep failed material"))
        for n in 1...2 {
            let source = root.appendingPathComponent("source\(n).mov")
            try Data("video\(n)".utf8).write(to: source)
            try await store.addClip(from: source, duration: 1, to: shot.id)
        }
        let first = store.shots[0].clips[0]
        fm.failingRemovals = [first.fileName]
        store.removeClip(first.id, from: shot.id)
        XCTAssertEqual(store.shots[0].clips[0], first)
        XCTAssertEqual(store.clipCount, 2)
        store.removeAllClips(for: shot.id)
        XCTAssertEqual(store.shots[0].clips, [first])
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(ShotStore(fileManager: fm).shots, store.shots)
        XCTAssertTrue(store.orphanFileNames.isEmpty)
        store.delete(shot)
        XCTAssertEqual(store.shots.first?.id, shot.id)
        store.deleteEverything()
        XCTAssertEqual(store.shots.first?.clips, [first])
        for name in ["fail.mov", "ok.mov"] {
            try Data("orphan".utf8).write(to: store.clipsDirectory.appendingPathComponent(name))
        }
        fm.failingRemovals.insert("fail.mov")
        store.refreshStorageStats()
        XCTAssertEqual(store.removeOrphanFiles(), 1)
        XCTAssertEqual(store.orphanFileNames, ["fail.mov"])
        XCTAssertNotNil(store.saveError)
        fm.failingRemovals = []
        store.deleteEverything()
        XCTAssertTrue(store.shots.isEmpty)
        XCTAssertTrue(store.orphanFileNames.isEmpty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).isEmpty)
    }

    @MainActor
    func testDeletionRecoverySurvivesRepairWriteFailureAndRestart() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "Recover me"))
        let source = root.appendingPathComponent("source.mov")
        try Data("video".utf8).write(to: source)
        try await store.addClip(from: source, duration: 1, to: shot.id)
        let original = store.shots
        let metadata = root.appendingPathComponent("Support/ShotList/shots.json")
        let journal = root.appendingPathComponent("Support/ShotList/pending-deletions.json")
        fm.failingRemovals = [original[0].clips[0].fileName]
        fm.onFailedRemoval = {
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        }
        store.delete(shot)
        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(fm.fileExists(atPath: journal.path))
        XCTAssertNil(store.addShot())
        fm.onFailedRemoval = nil
        try fm.removeItem(at: metadata)
        try Data("[]".utf8).write(to: metadata)
        let reopened = ShotStore(fileManager: fm)
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.shots, original)
        XCTAssertFalse(fm.fileExists(atPath: journal.path))
        XCTAssertEqual(ShotStore(fileManager: fm).shots, original)
    }

    @MainActor
    func testCopyRunsOffMainActorAndRechecksReorderedTarget() async throws {
        let (root, _) = try fixture()
        let fm = BlockingCopyFileManager(root: root)
        let store = ShotStore(fileManager: fm)
        let target = try XCTUnwrap(store.addShot(note: "Target"))
        _ = store.addShot(note: "Other")
        let source = root.appendingPathComponent("large.mp4")
        let bytes = Data(repeating: 37, count: 4 * 1024 * 1024)
        try bytes.write(to: source)
        let save = Task { try await store.addClip(from: source, duration: 1, to: target.id) }
        await fulfillment(of: [fm.copyStarted], timeout: 2)
        // While copy is held on a worker, this main-actor mutation must still complete.
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(store.shots[1].id, target.id)
        XCTAssertEqual(store.clipCount, 0)
        XCTAssertEqual(store.removeOrphanFiles(), 0)
        fm.releaseCopy.signal()
        try await save.value
        let clip = try XCTUnwrap(store.shots[1].clips.first)
        XCTAssertTrue(clip.fileName.hasPrefix("镜头02_"))
        XCTAssertTrue(clip.fileName.hasSuffix(".mp4"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.clipURL(for: clip))), bytes)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("import-") })
    }

    @MainActor
    func testDeletedTargetDuringCopyPreservesCallerSourceAndCleansStaging() async throws {
        let (root, _) = try fixture()
        let fm = BlockingCopyFileManager(root: root)
        let store = ShotStore(fileManager: fm)
        let target = try XCTUnwrap(store.addShot())
        let source = root.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: source)
        let save = Task { try await store.addClip(from: source, duration: 1, to: target.id) }
        await fulfillment(of: [fm.copyStarted], timeout: 2)
        store.deleteEverything()
        fm.releaseCopy.signal()
        do { try await save.value; XCTFail("Deleted target accepted") }
        catch { XCTAssertTrue(error is ShotStoreError) }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertTrue(store.shots.isEmpty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).isEmpty)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("import-") })
    }

    @MainActor
    func testCancelledCopyDoesNotPublishOrConsumeSource() async throws {
        let (root, _) = try fixture()
        let fm = BlockingCopyFileManager(root: root)
        let store = ShotStore(fileManager: fm)
        let target = try XCTUnwrap(store.addShot())
        let source = root.appendingPathComponent("source.mov")
        try Data("source".utf8).write(to: source)
        let save = Task { try await store.addClip(from: source, duration: 1, to: target.id) }
        await fulfillment(of: [fm.copyStarted], timeout: 2)
        save.cancel()
        fm.releaseCopy.signal()
        do { try await save.value; XCTFail("Cancelled save succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(store.clipCount, 0)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("import-") })
    }

}


final class BlockingCopyFileManager: FileManager, @unchecked Sendable {
    let root: URL
    let copyStarted = XCTestExpectation(description: "Background copy started")
    let releaseCopy = DispatchSemaphore(value: 0)
    init(root: URL) { self.root = root; super.init() }
    override var temporaryDirectory: URL { root }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent(directory == .documentDirectory ? "Documents" : "Support")]
    }
    override func copyItem(at source: URL, to destination: URL) throws {
        XCTAssertFalse(Thread.isMainThread, "Large-file copy must leave the UI thread")
        copyStarted.fulfill()
        guard !Thread.isMainThread, releaseCopy.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "CopyProbe", code: 1)
        }
        try super.copyItem(at: source, to: destination)
    }
}
