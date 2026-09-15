import XCTest
import UIKit
@testable import ShotList

final class ThumbnailLoaderTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testInvalidatedResultCannotReplaceNewCacheOrRemoveNewTask() async {
        for clearAll in [false, true] {
            for oldFinishesFirst in [false, true] {
                let oldImage = UIImage()
                let newImage = UIImage()
                let oldStarted = expectation(description: "Old decode")
                let newStarted = expectation(description: "New decode")
                var continuations: [CheckedContinuation<UIImage?, Never>] = []
                var decodeCount = 0
                let loader = ThumbnailLoader { _ in
                    decodeCount += 1
                    return await withCheckedContinuation { continuation in
                        continuations.append(continuation)
                        if continuations.count == 1 { oldStarted.fulfill() } else { newStarted.fulfill() }
                    }
                }
                let url = URL(fileURLWithPath: "/isolated-thumbnail-test.mov")
                let old = Task { await loader.thumbnail(for: url) }
                await fulfillment(of: [oldStarted], timeout: 2)
                if clearAll { loader.removeAll() } else { loader.invalidate(for: url) }
                let fresh = Task { await loader.thumbnail(for: url) }
                await fulfillment(of: [newStarted], timeout: 2)
                if oldFinishesFirst {
                    continuations[0].resume(returning: oldImage)
                    let stale = await old.value
                    XCTAssertNil(stale)
                    XCTAssertNil(loader.cachedThumbnail(for: url))
                    // 新一代尚未返回时再发请求，必须复用它而不是发起第三次解码。
                    let joined = Task { await loader.thumbnail(for: url) }
                    await Task.yield()
                    continuations[1].resume(returning: newImage)
                    let joinedImage = await joined.value
                    XCTAssertTrue(joinedImage === newImage)
                } else {
                    continuations[1].resume(returning: newImage)
                    _ = await fresh.value
                    continuations[0].resume(returning: oldImage)
                    let stale = await old.value
                    XCTAssertNil(stale)
                }
                let freshImage = await fresh.value
                XCTAssertTrue(freshImage === newImage)
                XCTAssertTrue(loader.cachedThumbnail(for: url) === newImage)
                XCTAssertEqual(decodeCount, 2)
                let cached = await loader.thumbnail(for: url)
                XCTAssertTrue(cached === newImage)
            }
        }
    }

    @MainActor
    func testConcurrentReadersShareOneDecodeAndReceiveSameImage() async {
        let started = expectation(description: "Decode started")
        var finish: CheckedContinuation<UIImage?, Never>?
        var count = 0
        let loader = ThumbnailLoader { _ in
            count += 1
            return await withCheckedContinuation { finish = $0; started.fulfill() }
        }
        let url = URL(fileURLWithPath: "/isolated-shared-thumbnail.mov")
        let first = Task { await loader.thumbnail(for: url) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await loader.thumbnail(for: url) }
        await Task.yield()
        let image = UIImage()
        finish?.resume(returning: image)
        let a = await first.value
        let b = await second.value
        XCTAssertTrue(a === image)
        XCTAssertTrue(b === image)
        XCTAssertEqual(count, 1)
    }
}
