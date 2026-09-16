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
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
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
        blocked.deleteCurrentFilm()
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
        // 记录被外部删掉、素材还在：这一份不能当成空库继续跑——
        // 否则那些视频会在下一次「清理未使用的文件」里被当成孤儿清掉
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
        try fm.removeItem(at: metadata)
        let blocked = ShotStore(fileManager: fm)
        XCTAssertNotNil(blocked.loadError)
        XCTAssertEqual(blocked.removeOrphanFiles(), 0)
        XCTAssertNil(blocked.addShot())
        XCTAssertFalse(fm.fileExists(atPath: metadata.path))
    }

    @MainActor
    func testMetadataDirectoryIsReadFailure() async throws {
        let (root, fm) = try fixture()
        _ = ShotStore(fileManager: fm)
        // 首次启动会落一份空影片库；把那个位置换成同名目录，模拟元数据读不出来
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
        try fm.removeItem(at: metadata)
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)

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
        store.deleteCurrentFilm()
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
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
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
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
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
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
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
        store.deleteCurrentFilm()
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
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
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
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
        let film = Film(shots: original)
        let good = try JSONEncoder().encode(FilmLibrary(films: [film], currentFilmID: film.id))
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
        // 旧记录可能编号正确、文件名前缀却是旧的，读取时要顺手改好
        var stale = reopened.shots.reversed().map { $0 }
        for i in stale.indices { stale[i].number = i + 1 }
        let staleFilm = Film(shots: stale)
        try JSONEncoder()
            .encode(FilmLibrary(films: [staleFilm], currentFilmID: staleFilm.id))
            .write(to: metadata)
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
        store.deleteCurrentFilm()
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
        // 删除当前影片只回收这部影片自己的片段，未使用文件要在导出页单独清理，
        // 这里把上一次没删掉的 fail.mov 补删一次
        XCTAssertEqual(store.removeOrphanFiles(), 1)
        store.deleteCurrentFilm()
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
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
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
        try Data(#"{"films":[]}"#.utf8).write(to: metadata)
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
        store.deleteCurrentFilm()
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

    // MARK: - 影片库

    @MainActor
    func testMigratesLegacyShotsIntoASingleFilm() async throws {
        let (root, fm) = try fixture()
        // 先用新版跑一遍，拿到一份「有记录也有文件」的状态，再退回旧版布局
        let seed = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(seed.addShot(note: "旧记录"))
        let source = root.appendingPathComponent("source.mov")
        try Data("legacy video".utf8).write(to: source)
        try await seed.addClip(from: source, duration: 3, to: shot.id)
        let legacyShots = seed.shots

        let support = root.appendingPathComponent("Support/ShotList")
        try fm.removeItem(at: support.appendingPathComponent("films.json"))
        try JSONEncoder().encode(legacyShots).write(to: support.appendingPathComponent("shots.json"))

        let migrated = ShotStore(fileManager: fm)
        XCTAssertNil(migrated.loadError)
        // 镜头与片段逐项一致，一个都没丢
        XCTAssertEqual(migrated.shots, legacyShots)
        XCTAssertEqual(migrated.clipCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(migrated.clipURL(for: migrated.shots[0]))),
            Data("legacy video".utf8)
        )
        // 旧文件改名保留作回滚保险，新文件就位
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("shots.json.migrated").path))
        XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("shots.json").path))
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("films.json").path))
        // 再打开一次走的是新格式，不会重复迁移，也不会多出一部影片
        let reopened = ShotStore(fileManager: fm)
        XCTAssertEqual(reopened.shots, legacyShots)
        XCTAssertEqual(reopened.films.count, 1)
    }

    @MainActor
    func testOrphansAreScopedToEveryFilmNotJustTheCurrentOne() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)

        let aShot = try XCTUnwrap(store.addShot(note: "A"))
        let aSource = root.appendingPathComponent("a.mov")
        try Data("a".utf8).write(to: aSource)
        try await store.addClip(from: aSource, duration: 1, to: aShot.id)
        let filmA = try XCTUnwrap(store.currentFilmID)

        _ = store.remakeCurrentFilm(title: "B")
        let bShot = try XCTUnwrap(store.addShot(note: "B"))
        let bSource = root.appendingPathComponent("b.mov")
        try Data("b".utf8).write(to: bSource)
        try await store.addClip(from: bSource, duration: 1, to: bShot.id)
        XCTAssertNotEqual(store.currentFilmID, filmA)

        // 站在影片 B 的角度，影片 A 的素材绝不能被算成「未使用文件」
        XCTAssertEqual(store.clipCount, 1)
        XCTAssertTrue(store.orphanFileNames.isEmpty)
        XCTAssertEqual(store.removeOrphanFiles(), 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).count, 2)

        // 切回影片 A：记录与素材都还在
        XCTAssertTrue(store.loadFilm(filmA))
        XCTAssertEqual(store.shots.count, 1)
        XCTAssertEqual(store.shots[0].note, "A")
        XCTAssertEqual(store.clipCount, 1)
    }

    // MARK: - 画面的描述 / 屏幕的字

    /// 旧分镜里没有「屏幕字幕」与「角标数值」这两个字段，读它必须拿到空值
    /// ——空的含义正是旧数据的真实状态：这一镜不出字幕、不出角标。
    @MainActor
    func testLegacyShotWithoutCaptionAndBadgeDecodesToEmpty() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "早上起床称体重"))
        let source = root.appendingPathComponent("a.mov")
        try Data("video".utf8).write(to: source)
        try await store.addClip(from: source, duration: 3, to: shot.id)

        // 把落盘的字幕与角标字段删掉，模拟新版之前存下的数据
        let metadata = root.appendingPathComponent("Support/ShotList/films.json")
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: metadata)) as? [String: Any]
        )
        var films = try XCTUnwrap(json["films"] as? [[String: Any]])
        var shots = try XCTUnwrap(films[0]["shots"] as? [[String: Any]])
        shots[0].removeValue(forKey: "caption")
        shots[0].removeValue(forKey: "badgeValue")
        films[0]["shots"] = shots
        json["films"] = films
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)

        let reloaded = ShotStore(fileManager: fm)

        XCTAssertNil(reloaded.loadError)
        let legacy = try XCTUnwrap(reloaded.shots.first)
        XCTAssertEqual(legacy.note, "早上起床称体重")
        XCTAssertEqual(legacy.caption, "")
        XCTAssertEqual(legacy.badgeValue, "")
        XCTAssertFalse(legacy.hasCaption)
        XCTAssertFalse(legacy.hasBadgeValue)
        // 没有字幕不等于没有描述：两件事不能互相连坐
        XCTAssertTrue(legacy.hasNote)
        XCTAssertEqual(legacy.clips.count, 1)
    }

    /// 字幕与角标要真的落盘——它们是用户一个字一个字敲进去的内容，
    /// 不能只活在内存里，重开应用就没了。
    @MainActor
    func testCaptionAndBadgeSurviveReload() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "开场"))

        var edited = shot
        edited.caption = "今日体重114.1KG"
        edited.badgeValue = "1758"
        XCTAssertTrue(store.update(edited))

        let reloaded = ShotStore(fileManager: fm)
        let persisted = try XCTUnwrap(reloaded.shots.first)
        XCTAssertEqual(persisted.caption, "今日体重114.1KG")
        XCTAssertEqual(persisted.badgeValue, "1758")
        XCTAssertEqual(persisted.note, "开场")
    }

    /// 行尾多敲一个回车不算「写过字幕」：三样文字入库前都要裁掉首尾空白。
    @MainActor
    func testWhitespaceOnlyPerShotTextIsNotContent() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "开场"))

        var edited = shot
        edited.caption = "  \n "
        edited.badgeValue = "\n"
        XCTAssertTrue(store.update(edited))

        let stored = try XCTUnwrap(store.shots.first)
        XCTAssertFalse(stored.hasCaption)
        XCTAssertFalse(stored.hasBadgeValue)
        XCTAssertEqual(stored.trimmedCaption, "")
        XCTAssertEqual(stored.trimmedBadgeValue, "")
    }

    /// 复制镜头要把三样文字都带过去。只带描述的话，用户写好字幕再复制一下，
    /// 字幕就悄悄没了——那是最难被发现的一种丢数据。
    @MainActor
    func testDuplicateCarriesCaptionAndBadge() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        var shot = try XCTUnwrap(store.addShot(note: "器械划船"))
        shot.caption = "器械划船 ⌄ 45KG * 4 * 10"
        shot.badgeValue = "2318"
        XCTAssertTrue(store.update(shot))

        let copy = try XCTUnwrap(store.duplicate(XCTUnwrap(store.shots.first)))
        XCTAssertEqual(copy.note, "器械划船")
        XCTAssertEqual(copy.caption, "器械划船 ⌄ 45KG * 4 * 10")
        XCTAssertEqual(copy.badgeValue, "2318")
        XCTAssertEqual(store.shots.count, 2)
        XCTAssertEqual(store.shots[0].number, 1)
        XCTAssertEqual(store.shots[1].number, 2)
    }

    @MainActor
    func testRemakeArchivesCurrentFilmAndRecyclesBlankOnes() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        _ = store.addShot(note: "旧片的镜头")
        let oldFilm = try XCTUnwrap(store.currentFilmID)

        let fresh = try XCTUnwrap(store.remakeCurrentFilm())
        XCTAssertEqual(store.currentFilmID, fresh.id)
        XCTAssertTrue(store.shots.isEmpty)
        XCTAssertEqual(store.films.count, 2)

        // 再重制一次：上一次留下的空壳应当被静默回收，库里不会越攒越多
        _ = store.remakeCurrentFilm()
        XCTAssertEqual(store.films.count, 2)
        XCTAssertEqual(store.shots.count, 0)

        // 旧片原样留库，切回去内容完整
        XCTAssertTrue(store.loadFilm(oldFilm))
        XCTAssertEqual(store.shots.count, 1)
        XCTAssertEqual(store.shots[0].note, "旧片的镜头")
        XCTAssertNotNil(store.currentFilm)
    }

    @MainActor
    func testRemakeLeavesExactlyOneBlankFilm() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        // 全新库里只有一部空影片，第一次重制会把它回收掉，而不是留下两个空壳
        _ = store.remakeCurrentFilm()
        XCTAssertNotNil(store.currentFilm)
        XCTAssertTrue(store.shots.isEmpty)
        XCTAssertEqual(store.films.count, 1)
        // 反复重制也不会越攒越多
        _ = store.remakeCurrentFilm()
        XCTAssertEqual(store.films.count, 1)
        XCTAssertNotNil(store.currentFilm)
    }

    /// 导出页的「删除当前影片」在「只剩一部、没有分镜」时是否可用，判据是 `isBlank`
    /// 而不是 `shots.isEmpty`。这条用例钉住它所依赖的 store 行为：删掉一部
    /// 「起了名字但还没加镜头」的影片，标题确实被清掉了——不是「什么都没发生」。
    @MainActor
    func testDeletingTheOnlyTitledFilmActuallyClearsItsTitle() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let titled = try XCTUnwrap(store.currentFilmID)
        store.renameFilm(titled, to: "夏日vlog")
        XCTAssertTrue(try XCTUnwrap(store.currentFilm).hasTitle)

        store.deleteCurrentFilm()

        XCTAssertEqual(store.films.count, 1)
        XCTAssertNotEqual(store.currentFilmID, titled)
        XCTAssertFalse(try XCTUnwrap(store.currentFilm).hasTitle)
    }

    @MainActor
    func testDiskReconciliationDoesNotAdvanceUpdatedAt() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "会被外部删掉"))
        let source = root.appendingPathComponent("source.mov")
        try Data("video".utf8).write(to: source)
        try await store.addClip(from: source, duration: 1, to: shot.id)
        let before = try XCTUnwrap(store.currentFilm).updatedAt

        // 模拟用户从「文件」App 里删掉片段，再回到前台
        try fm.removeItem(at: XCTUnwrap(store.clipURL(for: store.shots[0])))
        store.refreshStorageStats()

        XCTAssertEqual(store.clipCount, 0)
        // 自愈不是用户编辑，影片的「最后更新」不该被推到现在
        XCTAssertEqual(try XCTUnwrap(store.currentFilm).updatedAt, before)
    }

    @MainActor
    func testLoadingHistoricalFilmLetsUserKeepShooting() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let oldShot = try XCTUnwrap(store.addShot(note: "没拍完的旧片"))
        let oldFilm = try XCTUnwrap(store.currentFilmID)

        // 先换一部新片，再从影片库里把旧片载入回来接着拍
        _ = store.remakeCurrentFilm(title: "新片")
        XCTAssertTrue(store.loadFilm(oldFilm))

        let source = root.appendingPathComponent("resume.mov")
        try Data("resume".utf8).write(to: source)
        try await store.addClip(from: source, duration: 2, to: oldShot.id)

        XCTAssertEqual(store.clipCount, 1)
        XCTAssertEqual(store.stats(of: try XCTUnwrap(store.film(withID: oldFilm))).clipCount, 1)
        // 新片没有被牵连
        let newFilm = try XCTUnwrap(store.films.first { $0.id != oldFilm })
        XCTAssertEqual(store.stats(of: newFilm).clipCount, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.clipsDirectory.path).count, 1)
        // 重启之后仍然停在载入的那部影片上
        XCTAssertEqual(ShotStore(fileManager: fm).currentFilmID, oldFilm)
    }

    @MainActor
    func testRenamingFilmUpdatesItsSortPositionWithoutTouchingShots() async throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        _ = store.addShot(note: "第一部的镜头")
        let first = try XCTUnwrap(store.currentFilmID)
        _ = store.remakeCurrentFilm(title: "第二部")
        let second = try XCTUnwrap(store.currentFilmID)
        // 让两次编辑落在不同的时间点上，排序才有确定的结论
        try await Task.sleep(for: .milliseconds(20))

        store.renameFilm(first, to: "改过名的那部")
        XCTAssertEqual(store.film(withID: first)?.title, "改过名的那部")
        // 排序按最后更新倒序，刚改过的那部排到最前
        XCTAssertEqual(store.sortedFilms.first?.id, first)
        XCTAssertEqual(store.film(withID: second)?.shots.count, 0)
    }
    /// 一次选多段视频时，按选择顺序逐段落进同一个镜头。
    ///
    /// 批量导入必然撞上「同一秒内连落几段」：文件名的时间戳 token 会撞车，
    /// 只能靠后缀错开；顺序、时长与主素材都按落地的先后定。
    @MainActor
    func testBatchImportAppendsClipsInSelectionOrderWithoutNameCollision() async throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "批量导入"))

        // 混着扩展名，确认每段的扩展名各随其源文件
        let sources = ["a.mov", "b.mp4", "c.mov"].map { name -> URL in
            let url = root.appendingPathComponent(name)
            try? Data(name.utf8).write(to: url)
            return url
        }

        for (index, source) in sources.enumerated() {
            try await store.addClip(from: source, duration: TimeInterval(index + 1), to: shot.id)
        }

        let live = try XCTUnwrap(store.shot(withID: shot.id))
        XCTAssertEqual(live.clips.map(\.duration), [1, 2, 3])
        XCTAssertEqual(live.clips.map(\.recordedAt), live.clips.map(\.recordedAt).sorted())
        XCTAssertEqual(live.latestTakeIndex, 3)

        let names = live.clips.map(\.fileName)
        XCTAssertEqual(Set(names).count, 3, "同一秒连落的三段不能互相覆盖")
        XCTAssertEqual(names.map { ($0 as NSString).pathExtension }, ["mov", "mp4", "mov"])
        for name in names {
            XCTAssertTrue(name.hasPrefix("镜头01_"))
            XCTAssertTrue(fm.fileExists(atPath: store.clipsDirectory.appendingPathComponent(name).path))
        }
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
