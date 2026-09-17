import XCTest
@testable import ShotList

/// 剪辑风格改成「一段描述」之后要守住的三件事：
/// 旧的结构化风格要能翻译过来、留空与写过的空壳口径、值没变不算一次编辑。
final class FilmStylePromptTests: XCTestCase {

    private func fixture() throws -> (URL, IsolatedFileManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, IsolatedFileManager(root: root))
    }

    private func metadataURL(_ root: URL) -> URL {
        root.appendingPathComponent("Support/ShotList/films.json")
    }

    private func decodeFilm(_ json: String) throws -> Film {
        try JSONDecoder().decode(Film.self, from: Data(json.utf8))
    }

    /// 一份带完整结构化风格的旧影片 JSON（迁移用例的共同输入）
    private let legacyFilmJSON = """
    {
      "id": "8B1A6C64-2A1E-4F0B-9E1D-3C5A7B9D1E2F",
      "title": "老片子",
      "style": {
        "canvas": "vertical1080",
        "frameRate": 60,
        "pacing": { "targetMinDuration": 12, "targetMaxDuration": 15,
                    "shotMinDuration": 0.8, "shotMaxDuration": 2 },
        "typography": { "family": "songti", "weight": "bold", "sizeRatio": 0.05,
                        "strokeRatio": 0.004, "colorHex": "#FFEE00", "strokeColorHex": "#101010" },
        "badge": { "isEnabled": true, "anchor": "center", "offsetYRatio": 0.5, "maxLines": 1,
                   "contentSource": "shotText", "text": "热量缺口：{value}千卡" },
        "caption": { "isEnabled": true, "anchor": "lowerThird", "offsetYRatio": 0.709, "maxLines": 2,
                     "contentSource": "shotText", "text": "" },
        "tailCard": { "overlay": { "isEnabled": true, "anchor": "center", "offsetYRatio": 0.5,
                                   "maxLines": 2, "contentSource": "fixed",
                                   "text": "今日热量缺口：\\n{value}千卡" },
                      "duration": 1.2, "backgroundColorHex": "#000000" },
        "audio": { "mode": "silent", "originalGain": 0 }
      },
      "shots": [],
      "createdAt": 700000000,
      "updatedAt": 700000000
    }
    """

    // MARK: - 旧数据

    /// 只有标题和分镜的老影片：风格留空，等用户自己写。
    /// 与下一条一起验证同一件事——缺字段不能让整份影片读不出来。
    func testLegacyFilmWithoutAnyStyleDecodesToEmptyPrompt() throws {
        let film = try decodeFilm("""
        { "id": "\(UUID().uuidString)", "title": "老片子", "shots": [],
          "createdAt": 700000000, "updatedAt": 700000000 }
        """)

        XCTAssertEqual(film.title, "老片子")
        XCTAssertEqual(film.stylePrompt, "")
        XCTAssertFalse(film.hasStylePrompt)
    }

    /// 存着旧结构化风格的老影片：翻译成一段描述写进 `stylePrompt`。
    /// 不能因为换了表达方式，就把用户已经调好的东西丢掉。
    func testLegacyStructuredStyleIsTranslatedIntoPrompt() throws {
        let prompt = try decodeFilm(legacyFilmJSON).stylePrompt

        XCTAssertTrue(prompt.contains("竖屏 1080×1920、60fps"), prompt)
        XCTAssertTrue(prompt.contains("总长 12–15 秒"), prompt)
        XCTAssertTrue(prompt.contains("单镜 0.8–2 秒"), prompt)
        XCTAssertTrue(prompt.contains("静音"), prompt)
        XCTAssertTrue(prompt.contains("画面正中一行常驻角标"), prompt)
        XCTAssertTrue(prompt.contains("文字块中心距屏顶约 50.0%"), prompt)
        XCTAssertTrue(prompt.contains("宋体 · 粗体"), prompt)
        XCTAssertTrue(prompt.contains("#FFEE00 文字 + #101010 描边"), prompt)
        XCTAssertTrue(prompt.contains("片尾卡 1.2 秒"), prompt)
    }

    /// 角标的文案模板**不再进风格描述**：按新口径，角标要显示的整段字由各分镜自己写。
    /// 把模板留在描述里，会诱导剪辑侧再拼一次字符串。
    func testLegacyPromptDropsPerShotBadgeTemplate() throws {
        let prompt = try decodeFilm(legacyFilmJSON).stylePrompt

        XCTAssertFalse(prompt.contains("热量缺口：{value}千卡"), prompt)
        XCTAssertTrue(prompt.contains("文字由各分镜自己填"), prompt)
    }

    /// 片尾卡是全片统一的那一条，它的 `{value}` 要解释清楚——
    /// 已经没有模板机制了，不说明的话剪辑侧只能看到一个字面的占位符。
    func testLegacyPromptExplainsTailCardPlaceholder() throws {
        let prompt = try decodeFilm(legacyFilmJSON).stylePrompt

        XCTAssertTrue(prompt.contains("{value} 换成当天的数字"), prompt)
    }

    /// 关掉的图层不该出现在描述里——列出来等于告诉剪辑侧「这一层要做」。
    func testLegacyPromptSkipsDisabledLayers() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "title": "只留字幕", "shots": [],
          "style": { "badge": { "isEnabled": false },
                     "tailCard": { "overlay": { "isEnabled": false } } },
          "createdAt": 700000000, "updatedAt": 700000000 }
        """
        let prompt = try decodeFilm(json).stylePrompt

        XCTAssertFalse(prompt.contains("角标"), prompt)
        XCTAssertFalse(prompt.contains("片尾卡"), prompt)
        XCTAssertTrue(prompt.contains("屏幕字幕"), prompt)
    }

    /// 缺字段的旧风格不能整段读不出来：只写了半截时，没写的那些回落到旧版的默认值。
    func testPartiallySpecifiedLegacyStyleFallsBackToDefaults() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "title": "半截风格", "shots": [],
          "style": { "canvas": "vertical1080" },
          "createdAt": 700000000, "updatedAt": 700000000 }
        """
        let prompt = try decodeFilm(json).stylePrompt

        XCTAssertTrue(prompt.contains("竖屏 1080×1920、30fps"), prompt)
        // 旧版默认就是实测成片那套：4K 画幅、18–22 秒、保留原声
        XCTAssertFalse(prompt.contains("2160×3840"), prompt)
        XCTAssertTrue(prompt.contains("保留各镜现场原声"), prompt)
    }

    /// 4K 那档要给出 2160×3840，而不是把 1080 的口径照抄过去。
    func testLegacyVertical4KCanvasKeepsItsOwnSize() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "title": "4K", "shots": [],
          "style": { "canvas": "vertical4K" },
          "createdAt": 700000000, "updatedAt": 700000000 }
        """
        XCTAssertTrue(try decodeFilm(json).stylePrompt.contains("2160×3840"))
    }

    /// 已经写过描述的影片不该被旧字段盖掉：`stylePrompt` 优先。
    func testStoredPromptWinsOverLegacyStyle() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "title": "两边都有", "shots": [],
          "stylePrompt": "竖屏 1080×1920，快切。",
          "style": { "canvas": "vertical4K" },
          "createdAt": 700000000, "updatedAt": 700000000 }
        """
        XCTAssertEqual(try decodeFilm(json).stylePrompt, "竖屏 1080×1920，快切。")
    }

    // MARK: - 落盘往返

    /// 存一段描述、换个 store 从磁盘读回来。
    /// 顺带钉住：旧的 `style` 键**不再写回**，否则迁移会被反复触发。
    @MainActor
    func testPromptSurvivesReloadAndLegacyKeyIsDropped() throws {
        let (root, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let prompt = "竖屏 1080×1920、30fps。\n快切，不加音乐。"
        XCTAssertTrue(store.updateStylePrompt(prompt))

        let onDisk = try String(
            contentsOf: metadataURL(root).appendingPathComponent("../films.json").standardizedFileURL,
            encoding: .utf8
        )
        XCTAssertTrue(onDisk.contains("\"stylePrompt\""), onDisk)
        XCTAssertFalse(onDisk.contains("\"style\""), onDisk)

        let reloaded = ShotStore(fileManager: fm)
        XCTAssertEqual(reloaded.currentFilm?.stylePrompt, prompt)
    }

    /// 首尾空白在落盘前就裁掉：不然「敲了个回车又删掉」会被当成写过了。
    @MainActor
    func testPromptIsTrimmedBeforePersisting() throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)

        XCTAssertTrue(store.updateStylePrompt("\n  竖屏 1080×1920。 \n"))
        XCTAssertEqual(store.currentFilm?.stylePrompt, "竖屏 1080×1920。")
    }

    /// 值没变（含「只改了首尾空白」）就不算一次编辑，不刷新影片的「最后更新」。
    @MainActor
    func testUnchangedPromptIsNotAnEdit() throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        let before = try XCTUnwrap(store.currentFilm).updatedAt

        XCTAssertFalse(store.updateStylePrompt(""))
        XCTAssertFalse(store.updateStylePrompt("   "))
        XCTAssertEqual(try XCTUnwrap(store.currentFilm).updatedAt, before)

        XCTAssertTrue(store.updateStylePrompt("快切。"))
        XCTAssertFalse(store.updateStylePrompt("快切。 "))
    }

    // MARK: - 空壳口径

    /// 用户可能先把要求写好再去拍。写过风格的影片不能算空壳——
    /// 按「无分镜 + 无标题」回收会把刚写好的那段一起丢掉。
    @MainActor
    func testFilmWithPromptIsNotBlank() throws {
        let (_, fm) = try fixture()
        let store = ShotStore(fileManager: fm)
        XCTAssertTrue(try XCTUnwrap(store.currentFilm).isBlank)

        XCTAssertTrue(store.updateStylePrompt("竖屏，快切。"))

        XCTAssertFalse(try XCTUnwrap(store.currentFilm).isBlank)
        // 重制会归档旧片、新建空白片；写过要求的那部必须留下来
        _ = store.remakeCurrentFilm()
        XCTAssertTrue(store.films.contains { $0.stylePrompt == "竖屏，快切。" })
        XCTAssertEqual(store.films.count, 2)
    }

    // MARK: - 空输入框的提示

    /// 占位示例与要点清单是这一页「不用猜该填什么」的全部依据，钉住它们非空且覆盖各类。
    func testPlaceholderAndGuidanceCoverTheStyleSurface() {
        // 示例里各类都要点到一遍：改一行比从零写容易得多。
        // 关键词取示例里**真出现过**的字样——示例写得自然，不为了配合断言硬塞术语。
        for keyword in ["竖屏", "总长", "原声", "角标", "字幕", "黑底卡"] {
            XCTAssertTrue(
                FilmStylePrompt.placeholder.contains(keyword),
                "占位示例里少了「\(keyword)」"
            )
        }
        // 术语放在要点清单里：那里是「能写什么」的目录，按类别叫法最清楚
        XCTAssertFalse(FilmStylePrompt.guidance.isEmpty)
        XCTAssertTrue(FilmStylePrompt.guidance.contains { $0.contains("画幅与帧率") })
        XCTAssertTrue(FilmStylePrompt.guidance.contains { $0.contains("音轨") })
    }
}
