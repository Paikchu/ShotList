import Foundation

/// 一份影片模板：名称 + 一段纯文字。
///
/// 内容与 R-10 的分镜模板同一个形态——用户自己排版的字，默认是「描述：」「字幕：」
/// 「上方角标：」「转场：」四行，镜头面板里「应用」时原样（按 `Shot.applyingTemplate`
/// 的规则）填进内容框。没有变量、没有占位符。
///
/// 模板是**应用级**的，存在 `FilmLibrary.templates` 里，不属于某一部影片：
/// 影片只通过 `Film.templateID` 记住自己绑定了哪一份。这样「从模板新建」「事后绑定」
/// 「镜头面板里选别的模板」用的是同一批模板，改一处处处生效。
nonisolated struct FilmTemplate: Identifiable, Codable, Hashable {
    var id: UUID
    /// 模板名称。可以为空——空名称在界面上显示为「未命名模板」。
    var name: String
    /// 模板文字。空白时按默认模板处理，见 `effectiveContent`。
    var content: String

    init(
        id: UUID = UUID(),
        name: String = "",
        content: String = Film.defaultShotTemplate
    ) {
        self.id = id
        self.name = name
        self.content = content
    }
}

nonisolated extension FilmTemplate {
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 界面上展示的名称；未填时回退为「未命名模板」
    var displayName: String { trimmedName.isEmpty ? "未命名模板" : trimmedName }

    /// 真正填进内容框的文字：清空的模板回退为默认模板（与 R-10「把模板清空后回退成默认」一致）
    var effectiveContent: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Film.defaultShotTemplate : trimmed
    }

    /// 列表里的一行预览：各行标签用「 · 」连起来
    var previewText: String { Self.previewText(of: effectiveContent) }

    static func previewText(of content: String) -> String {
        content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 「应用模板」菜单里的一项。`templateID` 为 `nil` 表示内置的默认模板。
nonisolated struct TemplateChoice: Identifiable, Hashable {
    var templateID: FilmTemplate.ID?
    var name: String
    var content: String
    /// 是不是当前影片绑定的那一份（没绑定时默认模板就是它）
    var isBound: Bool

    var id: String { templateID?.uuidString ?? "default" }
}

nonisolated extension Film {
    /// 内置默认模板在界面上的名称
    static let defaultTemplateName = "默认"
}
