import SwiftUI

/// 三个顶层标签：分镜清单、历史记录、统一导出。
///
/// 用 `TabView` 而不是抽屉菜单，保证功能可发现性；标签栏在列表向下滚动时
/// 自动收起，把纵向空间让给内容，回到顶部再展开（iOS 26）。
struct RootTabView: View {
    /// 标签标识。原始值保持稳定，换了写法也不会丢掉用户上次停留的标签。
    enum TabSelection: String {
        case shots, history, export
    }

    @EnvironmentObject private var store: ShotStore
    @SceneStorage("root.selectedTab") private var selectedTabRaw: String = Self.initialTabRawValue()

    private var selectedTab: Binding<TabSelection> {
        Binding(
            get: { TabSelection(rawValue: selectedTabRaw) ?? .shots },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    /// 支持调试启动参数 `-preselectTab <shots|history|export>`：
    /// 验收截图可以直接停在某个标签页（见 Tools/seed-simulator.py 的验收流程）。
    private static func initialTabRawValue() -> String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-preselectTab"),
              index + 1 < arguments.count,
              TabSelection(rawValue: arguments[index + 1]) != nil
        else { return TabSelection.shots.rawValue }
        return arguments[index + 1]
    }

    var body: some View {
        if let loadError = store.loadError {
            ContentUnavailableView {
                Label("无法读取分镜记录", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("重新读取") { store.retryLoad() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: selectedTab) {
            Tab("分镜", systemImage: "film.stack", value: TabSelection.shots) {
                ShotListView()
            }

            Tab("历史", systemImage: "clock.arrow.circlepath", value: TabSelection.history) {
                HistoryView()
            }
            // 徽标沿用拍摄提醒的口径：今天还欠几个镜头没拍
            .badge(store.pendingShots(on: Date()).count)

            Tab("导出", systemImage: "square.and.arrow.up", value: TabSelection.export) {
                ExportView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#Preview {
    RootTabView()
        .environmentObject(ShotStore())
}
