import SwiftUI

/// 分镜助手 —— 纯本地单机应用，全部数据保存在设备上，不进行任何网络请求。
@main
struct ShotListApp: App {
    @StateObject private var store = ShotStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // 取景页的验收入口：模拟器没有摄像头，只有靠启动参数才能看到这一页
            // （见 CameraChromePreviewScreen.swift，Release 构建里不存在）
            if ProcessInfo.processInfo.arguments.contains("-chromeDemo") {
                CameraChromeDemoScreen()
            } else if ProcessInfo.processInfo.arguments.contains("-cameraDemo") {
                CameraCaptureDemoScreen()
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
    }

    /// 正式入口。单独抽出来，是因为 Debug 构建下它可能是上面那个验收分支之外的默认分支，
    /// 直接写在 `WindowGroup` 里会让两种构建的差异埋在一层缩进里。
    @ViewBuilder
    private var mainContent: some View {
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
