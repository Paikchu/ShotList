import SwiftUI

/// 分镜助手 —— 纯本地单机应用，全部数据保存在设备上，不进行任何网络请求。
@main
struct ShotListApp: App {
    @StateObject private var store = ShotStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environment(\.locale, AppLocale.current)
        }
    }
}
