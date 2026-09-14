import SwiftUI

/// 分镜助手 —— 纯本地单机应用，全部数据保存在设备上，不进行任何网络请求。
@main
struct ShotListApp: App {
    @StateObject private var store = ShotStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environment(\.locale, AppLocale.current)
                .task {
                    // 启动时统一回收临时目录。三类东西都只对产生它的那次操作有意义，
                    // 跨启动没有保留价值，而系统清理临时目录的时机由 iOS 决定：
                    // 「谁产生的谁回收」，所以这里是三个调用而不是一个。
                    ExportPackageBuilder.cleanUp()              // 导出包的中间产物
                    CameraRecorder.cleanUpTemporaryRecordings() // 相机录制的临时片段
                    ImportedMovie.cleanUpTemporaryImports()     // 相册导入的中转文件
                }
                .onChange(of: scenePhase) { _, phase in
                    // 用户可能在「文件」App 里删掉了片段，回到前台重新扫一次，
                    // 免得界面上还挂着早就不存在的视频
                    if phase == .active { store.refreshStorageStats() }
                }
        }
    }
}
