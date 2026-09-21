import Foundation

/// 桌面小组件与应用约定的「快速拍摄」链接。
///
/// 小组件用 `widgetURL` 打开它，应用在 `RootTabView` 里收下。小组件与应用两个 target
/// 都编入这个文件，scheme 与 host 只在这一处写。
enum QuickShootLink {
    static let scheme = "shotlist"
    static let host = "quick-shoot"

    /// 小组件的 `widgetURL` 收可选值，所以这里不必强解包。
    static var url: URL? { URL(string: "\(scheme)://\(host)") }

    static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }
}
