import SwiftUI

/// 「历史」标签页：按影片回看与找回拍摄记录。
///
/// 原来的日历已经移除。引入「影片」这一层之后，作品的边界是**影片**而不是日期：
/// 一部影片可以跨天续拍，「某天拍了什么」退化成影片的一个属性（最后更新时间），
/// 而「其他天 / 从未拍」这类跨天分类随之失去意义。
///
/// 顶部的影片条（与分镜页同一个组件）就是导航器：菜单里列出拍过的每一部影片，
/// 用最后更新的日期加标题标识，选中即把它**载入**为当前影片——数据没有被复制
/// 或移动，只是当前指针换了目标，分镜页于是接着编辑它。
///
/// 页面主体是当前影片的拍摄记录：进度环 + 统计块 + 筛选 + 镜头卡片。
struct HistoryView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var sheet: ShotSheet?
    /// 默认看「全部」：进历史页就是想看这部影片一共拍了些什么。
    @State private var filter: Filter = .all

    /// 筛选项与统计块一一对应。「已拍 / 未拍」是不重不漏的二分，
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
            ScrollView {
                VStack(spacing: SLSpacing.medium) {
                    // 影片条常驻：这部影片没有分镜时，用户仍然要能切到别的影片
                    FilmBar()

                    if store.shots.isEmpty {
                        emptyState
                    } else {
                        progressCard
                        statRow
                        filterPicker
                        shotList
                    }
                }
                .padding(.horizontal, SLSpacing.medium)
                .padding(.bottom, SLSpacing.large)
            }
            .background(Color(.systemGroupedBackground))
            .contentMargins(.top, SLSpacing.pageTopInset, for: .scrollContent)
            .navigationTitle("历史记录")
            // 标题与右侧内容同行（inlineLarge），不单独占一行；三页起始位置一致
            .toolbarTitleDisplayMode(.inlineLarge)
        }
        .shotFlow(sheet: $sheet)
    }

    // MARK: - 数据

    private var recordedShots: [Shot] { store.shots.filter(\.hasClip) }

    private var pendingShots: [Shot] { store.shots.filter { !$0.hasClip } }

    private var filteredShots: [Shot] {
        switch filter {
        case .all: return store.shots
        case .recorded: return recordedShots
        case .pending: return pendingShots
        }
    }

    private var emptyFilterHint: String {
        switch filter {
        case .all: return "这部影片还没有分镜。"
        case .recorded: return "这部影片还没有拍过的镜头。"
        case .pending: return "这部影片的镜头都拍过了。"
        }
    }

    // MARK: - 概览

    private var progressCard: some View {
        CardContainer {
            HStack(spacing: SLSpacing.large) {
                ProgressRing(progress: store.progress)

                VStack(alignment: .leading, spacing: SLSpacing.small) {
                    Text("\(store.recordedCount) / \(store.shots.count)")
                        // bold 统一为 title3（20pt）：与进度环百分比、统计块数字同级同大
                        .font(.title3.weight(.bold).monospacedDigit())
                    Text("这部影片已经拍了 \(store.recordedCount) 个镜头")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    footnote
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)
            }
        }
    }

    /// 还有镜头没拍时给「下一个」的指路；都拍完了就给一句收尾。
    @ViewBuilder
    private var footnote: some View {
        if let next = pendingShots.first {
            Button {
                filter = .pending
            } label: {
                Label(
                    "还差 \(pendingShots.count) 个镜头 · 下一个：镜头 \(next.paddedNumber)",
                    systemImage: "arrow.right.circle.fill"
                )
                .font(.footnote)
            }
            .accessibilityHint("查看这部影片还没拍的全部镜头，包含以前拍过的镜头")
        } else {
            Label("这部影片的镜头都拍完了", systemImage: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        }
    }

    private var statRow: some View {
        HStack(spacing: SLSpacing.small) {
            statTile(
                value: recordedShots.count,
                systemImage: "checkmark.circle.fill",
                tint: .green,
                caption: "已拍",
                filterTarget: .recorded
            )
            statTile(
                value: pendingShots.count,
                systemImage: "circle.dashed",
                tint: .orange,
                caption: "未拍",
                filterTarget: .pending
            )
            statTile(
                value: store.shots.count,
                systemImage: "film.stack",
                tint: .indigo,
                caption: "全部",
                filterTarget: .all
            )
        }
    }

    private func statTile(
        value: Int,
        systemImage: String,
        tint: Color,
        caption: String,
        filterTarget: Filter
    ) -> some View {
        Button {
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
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(ShotCardButtonStyle())
        .accessibilityLabel("\(caption) \(value) 个镜头")
        .accessibilityHint("点按筛选出这些镜头")
    }

    private var filterPicker: some View {
        Picker("筛选", selection: $filter) {
            ForEach(Filter.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("按拍摄状态筛选镜头")
    }

    // MARK: - 列表

    private var shotList: some View {
        VStack(spacing: SLSpacing.small) {
            ForEach(filteredShots) { shot in
                card(for: shot)
            }

            if filteredShots.isEmpty {
                Text(emptyFilterHint)
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
            clipURL: store.clipURL(for: shot)
        ) {
            Haptics.impact(.light)
            sheet = .options(shot)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("这部影片还没有分镜", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("到「分镜」标签页添加镜头，这里就能回看这部影片拍了些什么。也可以用上方的影片菜单切换或新建影片。")
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(ShotStore())
}
