import UIKit

/// 此刻有没有弹层（sheet、全屏页、弹窗、系统选片……）盖在界面上。
///
/// 弹层的状态分散在各页面自己的 `@State` 里，SwiftUI 没有一个全局的「界面上有没有弹层」。
/// 从外部来的请求（桌面小组件的链接）要在不打断用户的前提下开相机，得先知道界面是不是空的：
/// 别的弹层还盖着时呈现相机会被系统丢掉，而 `fullScreenCover` 的绑定已经写上了，
/// 之后相机就再也弹不出来（同类见 `ShotListView` 里卡片收起后再开相机的等待）。
enum ModalPresentation {
    /// 沿视图控制器树看有没有谁正在呈现别的控制器（SwiftUI 的弹层最终都是这样呈现的）。
    static var isActive: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { window in
                window.rootViewController.map(isPresenting) ?? false
            }
    }

    private static func isPresenting(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil
            || controller.children.contains(where: isPresenting)
    }

    /// 等到界面空下来；超时或任务被取消返回 `false`。
    static func waitUntilIdle(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isActive {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
