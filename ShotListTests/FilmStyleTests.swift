import XCTest
@testable import ShotList

/// 影片级剪辑风格：落盘往返、旧数据兼容、以及「调过风格就不算空壳」这条口径。
final class FilmStyleTests: XCTestCase {

    private func fixture() throws -> (URL, IsolatedFileManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, IsolatedFileManager(root: root))
    }

    private func metadataURL(_ root: URL) -> URL {
        root.appendingPathComponent("Support/ShotList/films.json")
    }

    // MARK: - 旧数据

    /// 库里已有的影片 JSON 没有 `style` 字段。读它必须拿到一套默认风格，
    /// 而不是整份影片读不出来——手写解码就是为了这一条。
    @MainActor
    func testLegacyFilmWithoutStyleDecodesToDefault() throws {
        let (root, fm) = try fixture()
        let metadata = metadataURL(root)
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacy = """
        {
          "films": [
            {
              "id": "\(UUID().uuidString)",
              "title": "老片子",
              "shots": [],
              "createdAt": 700000000,
              "updatedAt": 700000000
            }
          ],
          "currentFilmID": null
        }
        """
        try Data(legacy.utf8).write(to: metadata)

        let store = ShotStore(fileManager: fm)

        XCTAssertNil(store.loadError)
        let film = try XCTUnwrap(store.currentFilm)
        XCTAssertEqual(film.title, "老片子")
        XCTAssertEqual(film.style, FilmStyle())
    }

    /// 风格里少一个键（例如手册被手工改过、或以后加了新字段）时，
    /// 缺的那一项取默认值，已配好的其它项不受影响。
    func testPartiallySpecifiedStyleKeepsOtherFields() throws {
        let json = """
        {
          "canvas": "vertical1080",
          "pacing": { "targetMinDuration": 30, "targetMaxDuration": 40 },
          "badge": { "isEnabled": false }
        }
        """
        let style = try JSONDecoder().decode(FilmStyle.self, from: Data(json.utf8))

        XCTAssertEqual(style.canvas, .vertical1080)
        XCTAssertEqual(style.pacing.targetMinDuration, 30)
        XCTAssertEqual(style.pacing.targetMaxDuration, 40)
        // 同一段里没写的项回落到默认
        XCTAssertEqual(style.pacing.shotMinDuration, PacingStyle().shotMinDuration)
        XCTAssertFalse(style.badge.isEnabled)
        // 关掉的图层仍然带着默认位置，重新打开时不会跳到画面外
        XCTAssertEqual(style.badge.anchor, .topCenter)
        XCTAssertEqual(style.badge.offsetYRatio, OverlayAnchor.topCenter.defaultOffsetYRatio)
        // 整个没出现的小节整套取默认
        XCTAssertEqual(style.tailCard.duration, TailCardStyle().duration)
        XCTAssertEqual(style.frameRate, .fps30)
        XCTAssertEqual(style.typography.family, .heiti)
    }

    // MARK: - 落盘往返

    @MainActor
    func testStyleSurvivesReload() throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)

        var style = FilmStyle()
        style.canvas = .vertical1080
        style.pacing = PacingStyle(targetMinDuration: 12, targetMaxDuration: 15,
                                   shotMinDuration: 0.8, shotMaxDuration: 2)
        style.badge.anchor = .center
        style.badge.offsetYRatio = OverlayAnchor.center.defaultOffsetYRatio
        style.typography = TextTypography(weight: .bold, sizeRatio: 0.05)
        style.audio = AudioStyle(mode: .silent, originalGain: 0)
        XCTAssertTrue(store.updateStyle(style))

        // 换一个 store 从磁盘重新读，验证的是落盘结果而不是内存里的值
        let reloaded = ShotStore(fileManager: fm)
        XCTAssertEqual(reloaded.currentFilm?.style, style)
    }

    /// 值没变就不算一次编辑：滑块松手回到原值时不该刷新影片的「最后更新」。
    @MainActor
    func testUnchangedStyleIsNotAnEdit() throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let before = try XCTUnwrap(store.currentFilm).updatedAt

        XCTAssertFalse(store.updateStyle(FilmStyle()))
        XCTAssertEqual(try XCTUnwrap(store.currentFilm).updatedAt, before)

        var changed = FilmStyle()
        changed.canvas = .vertical1080
        XCTAssertTrue(store.updateStyle(changed))
    }

    // MARK: - 空壳口径

    /// 用户可能先把风格配好再去拍。调过风格的影片不能算空壳——
    /// 按「无分镜 + 无标题」回收会把刚配好的那份风格一起丢掉。
    @MainActor
    func testFilmWithCustomStyleIsNotBlank() throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let fresh = try XCTUnwrap(store.currentFilm)
        XCTAssertTrue(fresh.isBlank)

        var style = FilmStyle()
        style.caption.maxLines = 3
        XCTAssertTrue(store.updateStyle(style))

        let styled = try XCTUnwrap(store.currentFilm)
        XCTAssertFalse(styled.isBlank)
        // 重制会归档旧片、新建空白片；配过风格的那部必须留下来
        _ = store.remakeCurrentFilm()
        XCTAssertTrue(store.films.contains { $0.style.caption.maxLines == 3 })
        XCTAssertEqual(store.films.count, 2)
    }

    // MARK: - 内置方案

    @MainActor
    func testPresetReplacesEveryField() throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        var tweaked = FilmStyle()
        tweaked.canvas = .vertical1080
        tweaked.typography.sizeRatio = 0.09
        XCTAssertTrue(store.updateStyle(tweaked))

        XCTAssertTrue(store.applyStylePreset(.cardPacing))
        XCTAssertEqual(store.currentFilm?.style, FilmStylePreset.cardPacing.style)
    }

    // MARK: - 导出的规格

    /// 导出的 JSON 是剪辑侧的唯一权威来源，所以这里钉住几件容易走样的事：
    /// 比例而不是像素、位置名与比例同时给出、角标关掉时也要留在文件里。
    func testExportedJSONCarriesRatiosNotPixels() throws {
        var style = FilmStyle()
        style.canvas = .vertical1080
        style.pacing = PacingStyle(targetMinDuration: 18, targetMaxDuration: 22,
                                   shotMinDuration: 0.6, shotMaxDuration: 2.5)
        style.badge.anchor = .center
        style.badge.offsetYRatio = OverlayAnchor.center.defaultOffsetYRatio

        let json = style.exportedJSON(filmTitle: "减脂日记", exportedAt: Date())
        let canvas = try XCTUnwrap(json["canvas"] as? [String: Any])
        XCTAssertEqual(canvas["width"] as? Int, 1080)
        XCTAssertEqual(canvas["height"] as? Int, 1920)
        XCTAssertEqual(canvas["orientation"] as? String, "portrait")

        let typography = try XCTUnwrap(json["typography"] as? [String: Any])
        XCTAssertEqual(typography["sizeRatio"] as? Double, 0.044)
        // 比例是权威值，JSON 里不该出现「字号 85 像素」这种只在一个分辨率下成立的数
        XCTAssertNil(typography["size"])

        let overlays = try XCTUnwrap(json["overlays"] as? [String: Any])
        let badge = try XCTUnwrap(overlays["badge"] as? [String: Any])
        XCTAssertEqual(badge["anchor"] as? String, "center")
        XCTAssertEqual(badge["offsetYRatio"] as? Double, 0.5)
        XCTAssertEqual(badge["contentSource"] as? String, "shotText")
        // 角标数值是逐镜内容，规格里只给格式模板
        XCTAssertEqual(badge["text"] as? String, "热量缺口：{value}千卡")

        let caption = try XCTUnwrap(overlays["caption"] as? [String: Any])
        XCTAssertEqual(caption["contentSource"] as? String, "shotText")
        XCTAssertEqual(caption["maxLines"] as? Int, 2)

        let tailCard = try XCTUnwrap(overlays["tailCard"] as? [String: Any])
        XCTAssertEqual(tailCard["contentSource"] as? String, "fixed")
        XCTAssertEqual(tailCard["duration"] as? Double, 0.7)
        XCTAssertEqual(tailCard["backgroundColor"] as? String, "#000000")

        let pacing = try XCTUnwrap(json["pacing"] as? [String: Any])
        XCTAssertEqual(pacing["tailCardDuration"] as? Double, 0.7)
    }

    /// 关掉片尾卡时规格里的时长写 0——剪辑侧不必再去猜「enabled=false 是不是还要留黑屏」。
    func testDisabledTailCardContributesNoDuration() throws {
        var style = FilmStyle()
        style.tailCard.overlay.isEnabled = false
        let json = style.exportedJSON(filmTitle: "", exportedAt: Date())
        let pacing = try XCTUnwrap(json["pacing"] as? [String: Any])
        XCTAssertEqual(pacing["tailCardDuration"] as? Double, 0)
        let overlays = try XCTUnwrap(json["overlays"] as? [String: Any])
        let tailCard = try XCTUnwrap(overlays["tailCard"] as? [String: Any])
        XCTAssertEqual(tailCard["enabled"] as? Bool, false)
        XCTAssertEqual(tailCard["duration"] as? Double, 0)
    }

    /// 静音的影片，音量写成 0，不给剪辑侧留下「静音但音量 0.8」这种自相矛盾的组合。
    func testSilentModeForcesZeroGain() throws {
        var style = FilmStyle()
        style.audio = AudioStyle(mode: .silent, originalGain: 0.8)
        let json = style.exportedJSON(filmTitle: "", exportedAt: Date())
        let audio = try XCTUnwrap(json["audio"] as? [String: Any])
        XCTAssertEqual(audio["mode"] as? String, "silent")
        XCTAssertEqual(audio["originalGain"] as? Double, 0)
    }

    // MARK: - 节奏自检

    /// 上下限被拖反时不能给出一条空区间，也要能看出「这么多镜头根本放不下」。
    func testPacingNormalizationAndCapacity() {
        let inverted = PacingStyle(targetMinDuration: 30, targetMaxDuration: 20,
                                   shotMinDuration: 3, shotMaxDuration: 1).normalized
        XCTAssertEqual(inverted.targetMaxDuration, 30)
        XCTAssertEqual(inverted.shotMaxDuration, 3)

        let pacing = PacingStyle(targetMinDuration: 18, targetMaxDuration: 22,
                                 shotMinDuration: 0.6, shotMaxDuration: 2.5)
        // 21 秒预算装 14 个镜头：14 × 0.6 = 8.4 ≤ 21，放得下
        XCTAssertTrue(pacing.canHost(shotCount: 14, tailCardDuration: 0.7))
        // 40 个镜头就要 24 秒，超了
        XCTAssertFalse(pacing.canHost(shotCount: 40, tailCardDuration: 0.7))
        XCTAssertTrue(pacing.canHost(shotCount: 0, tailCardDuration: 0.7))

        let suggested = pacing.suggestedShotDuration(shotCount: 14, tailCardDuration: 0.7)
        XCTAssertGreaterThanOrEqual(suggested, pacing.shotMinDuration)
        XCTAssertLessThanOrEqual(suggested, pacing.shotMaxDuration)
    }
}
