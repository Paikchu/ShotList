import XCTest
@testable import ShotList

final class IsolatedFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent(directory == .documentDirectory ? "Documents" : "Support")]
    }
}

final class ShotStoreTests: XCTestCase {
    private func fixture() throws -> (URL, IsolatedFileManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, IsolatedFileManager(root: root))
    }

    @MainActor
    func testUnreadableMetadataProtectsFilesAndBlocksAllMutations() throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let shot = try XCTUnwrap(store.addShot(note: "Keep me"))
        let source = root.appendingPathComponent("source.mov")
        try Data("test video".utf8).write(to: source)
        try store.addClip(from: source, duration: 1, to: shot.id)
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
        XCTAssertThrowsError(try blocked.addClip(from: source, duration: 1, to: shot.id))
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
    func testMissingMetadataWithExistingVideoIsNotNewLibrary() throws {
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
    func testMetadataDirectoryIsReadFailure() throws {
        let (root, fm) = try fixture()
        _ = ShotStore(fileManager: fm)
        try fm.createDirectory(at: root.appendingPathComponent("Support/ShotList/shots.json"), withIntermediateDirectories: true)
        let blocked = ShotStore(fileManager: fm)
        XCTAssertNotNil(blocked.loadError)
        XCTAssertNil(blocked.addShot())
    }

    @MainActor
    func testFirstLaunchAndValidEmptyLibrary() throws {
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
}
