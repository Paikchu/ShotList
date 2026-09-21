import SwiftUI

/// 「历史」标签页：按影片回看与找回拍摄记录。
///
/// 原来的日历已经移除。引入「影片」这一层之后，作品的边界是**影片**而不是日期：
/// 一部影片可以跨天续拍，「某天拍了什么」退化成影片的一个属性（最后更新时间），
/// 而「其他天 / 从未拍」这类跨天分类随之失去意义。
///
/// 有拍摄记录时，顶部影片条用来切换影片（不改名）。没有记录时不显示下拉，
/// 空状态「创建影片」直接跳到分镜页。
///
/// 页面主体是当前影片的拍摄记录：进度环（右侧是已拍 / 未拍 / 全部）+ 筛选 + 镜头卡片。
struct HistoryView: View {
    @EnvironmentObject private var store: ShotStore
    @Environment(\.dynamicTypeSize) private var typeSize

    /// 与根标签页共用，空状态「创建影片」用来跳到分镜页。
    @SceneStorage("root.selectedTab") private var selectedTabRaw: String = RootTabView.TabSelection.shots.rawValue

    @State private var sheet: ShotSheet?
    /// 未拍镜头的虚线加号：交给 `shotFlow` 直接开相机（与分镜页一致）
    @State private var captureRequest: ShotCaptureRequest?
    /// 默认看「全部」：进历史页就是想看这部影片一共拍了些什么。
    @State private var filter: Filter = .all

    /// 筛选项与圆盘右侧三项统计一一对应。「已拍 / 未拍」是不重不漏的二分，
    /// 加上「全部」正好覆盖三种看法。
    enum Filter: String, CaseIterable, Identifiable {
        case all, recorded, pending

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .recorded: return "已拍"
            case .pending: return "未拍"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.shots.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: SLSpacing.medium) {
                            // 有拍摄记录才显示影片条。历史页不改名，下拉只用来切换影片。
                            FilmBar(allowsRename: false)

                            progressCard
                            filterPicker
                            shotList
                        }
                        .padding(.horizontal, SLSpacing.medium)
                        .padding(.bottom, SLSpacing.large)
                    }
                    .background(Color(.systemGroupedBackground))
                    .contentMargins(.top, SLSpacing.pageTopInset, for: .scrollContent)
                }
            }
            .navigationTitle("历史记录")
            // 标题与右侧内容同行（inlineLarge），不单独占一行；三页起始位置一致
            .toolbarTitleDisplayMode(.inlineLarge)
        }
        .shotFlow(sheet: $sheet, captureRequest: $captureRequest)
    }

    // MARK: - 数据

    // 「已拍 / 未拍」读 `store` 的磁盘口径，与进度环、影片条的「N/M 已拍」是同一个判据
    private var filteredShots: [Shot] {
        switch filter {
        case .all: return store.shots
        case .recorded: return store.recordedShots
        case .pending: return store.pendingShots
        }
    }

    /// 筛选结果为空时的一行提示：图标 + 短语
    private var emptyFilterLabel: (title: String, systemImage: String) {
        switch filter {
        case .all: return ("无镜头", "film.stack")
        case .recorded: return ("无已拍", "checkmark.circle")
        case .pending: return ("全部已拍", "checkmark.circle.fill")
        }
    }

    // MARK: - 概览

    private var progressCard: some View {
        CardContainer {
            if typeSize.isAccessibilitySize {
                VStack(spacing: SLSpacing.medium) {
                    ProgressRing(progress: store.progress)
                    stats
                }
            } else {
                HStack(spacing: SLSpacing.medium) {
                    ProgressRing(progress: store.progress)
                    stats
                }
            }
        }
    }

    /// 圆盘右侧三项统计，点按即可筛选。不再单独占一行卡片，避免和进度环说两遍同一件事。
    private var stats: some View {
        HStack(spacing: 0) {
            statColumn(
                value: store.recordedShots.count,
                systemImage: "checkmark.circle.fill",
                tint: .green,
                caption: "已拍",
                filterTarget: .recorded
            )
            statColumn(
                value: store.pendingShots.count,
                systemImage: "circle.dashed",
                tint: .orange,
                caption: "未拍",
                filterTarget: .pending
            )
            statColumn(
                value: store.shots.count,
                systemImage: "film.stack",
                tint: .indigo,
                caption: "全部",
                filterTarget: .all
            )
        }
    }

    private func statColumn(
        value: Int,
        systemImage: String,
        tint: Color,
        caption: String,
        filterTarget: Filter
    ) -> some View {
        let isSelected = filter == filterTarget
        return Button {
            filter = filterTarget
            Haptics.selection()
        } label: {
            VStack(spacing: SLSpacing.tiny) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text("\(value)")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? tint : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: SLSize.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShotCardButtonStyle())
        .accessibilityLabel("\(caption) \(value)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var filterPicker: some View {
        Picker("筛选", selection: $filter) {
            ForEach(Filter.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("筛选")
    }

    // MARK: - 列表

    private var shotList: some View {
        VStack(spacing: SLSpacing.small) {
            ForEach(filteredShots) { shot in
                card(for: shot)
            }

            if filteredShots.isEmpty {
                Label(emptyFilterLabel.title, systemImage: emptyFilterLabel.systemImage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SLSpacing.large)
            }
        }
    }

    /// 卡片按镜头的默认口径展示（最近拍的那一条）。
    ///
    /// 改造前这里会按「当天」取素材，导致同一张卡片在列表里显示的画面与
    /// 无障碍朗读的内容对不上；不再按天切片之后，两个口径天然统一。
    private func card(for shot: Shot) -> some View {
        ShotCardView(
            shot: shot,
            clipURL: store.clipURL(for: shot),
            onCapture: {
                Haptics.impact(.light)
                captureRequest = ShotCaptureRequest(shotID: shot.id)
            }
        ) {
            Haptics.impact(.light)
            sheet = .options(shot)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("无记录", systemImage: "clock.arrow.circlepath")
        } actions: {
            Button("创建影片") {
                Haptics.impact(.light)
                selectedTabRaw = RootTabView.TabSelection.shots.rawValue
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    HistoryView()
        .environmentObject(ShotStore())
}
