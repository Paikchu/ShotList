import SwiftUI

/// 三个顶层标签：分镜清单、今日状态、统一导出。
///
/// 用 `TabView` 而不是抽屉菜单，保证功能可发现性；标签栏在列表向下滚动时
/// 自动收起，把纵向空间让给内容，回到顶部再展开（iOS 26）。
struct RootTabView: View {
    /// 标签标识。原始值保持稳定，换了写法也不会丢掉用户上次停留的标签。
    enum TabSelection: String {
        case shots, today, export
    }

    @EnvironmentObject private var store: ShotStore
    @SceneStorage("root.selectedTab") private var selectedTabRaw: String = TabSelection.shots.rawValue

    private var selectedTab: Binding<TabSelection> {
        Binding(
            get: { TabSelection(rawValue: selectedTabRaw) ?? .shots },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTab) {
            Tab("分镜", systemImage: "film.stack", value: TabSelection.shots) {
                ShotListView()
            }

            Tab("今日", systemImage: "checklist", value: TabSelection.today) {
                TodayView()
            }
            .badge(store.todayPendingCount)

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
