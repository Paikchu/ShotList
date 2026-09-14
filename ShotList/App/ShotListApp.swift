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
                .task {
                    // 清掉上一次运行留在临时目录里的导出包。
                    // 导出包只是中间产物（体积约等于全部视频），只对生成它的那次
                    // 会话有意义，跨启动没有保留价值——不清就会一直堆着。
                    ExportPackageBuilder.cleanUp()
                }
        }
    }
}
