import SwiftUI

/// 三个顶层标签：分镜清单、今日状态、统一导出。
/// 使用 `TabView` 而非抽屉菜单，保证功能可发现性。
struct RootTabView: View {
    enum Tab: String {
        case shots, today, export
    }

    @EnvironmentObject private var store: ShotStore
    @SceneStorage("root.selectedTab") private var selectedTabRaw: String = Tab.shots.rawValue

    private var selectedTab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: selectedTabRaw) ?? .shots },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTab) {
            ShotListView()
                .tabItem { Label("分镜", systemImage: "film.stack") }
                .tag(Tab.shots)

            TodayView()
                .tabItem { Label("今日", systemImage: "checklist") }
                .tag(Tab.today)
                .badge(store.todayPendingCount)

            ExportView()
                .tabItem { Label("导出", systemImage: "square.and.arrow.up") }
                .tag(Tab.export)
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(ShotStore())
}
