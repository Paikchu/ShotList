import SwiftUI
import WidgetKit

/// 桌面小组件：小号（2×2 格），点一下直接进入应用的「快速拍摄」。
///
/// 内容是静态的、不读应用里的数据，所以不需要 App Group，也不需要刷新时间线。
/// 样式沿用应用里长按加号展开的卡片（`QuickShootCard`）：宫格图标加名称。
@main
struct QuickShootWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickShootWidget", provider: QuickShootProvider()) { _ in
            QuickShootWidgetView()
        }
        .configurationDisplayName("快速拍摄")
        .description("新建镜头并开拍")
        .supportedFamilies([.systemSmall])
    }
}

private struct QuickShootEntry: TimelineEntry {
    let date: Date
}

private struct QuickShootProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickShootEntry {
        QuickShootEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (QuickShootEntry) -> Void) {
        completion(QuickShootEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<QuickShootEntry>) -> Void) {
        // 内容不会变：只放一条，永不刷新
        completion(Timeline(entries: [QuickShootEntry(date: .now)], policy: .never))
    }
}

private struct QuickShootWidgetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .widgetAccentable()
            Text("快速拍摄")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(QuickShootLink.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

#Preview(as: .systemSmall) {
    QuickShootWidget()
} timeline: {
    QuickShootEntry(date: .now)
}
