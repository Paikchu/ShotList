import SwiftUI

/// 「今日」标签页：一眼看清每个镜头今天是拍了还是没拍。
struct TodayView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var sheet: ShotSheet?
    @State private var filter: Filter = .all

    /// 筛选项与上方三个统计块一一对应。
    ///
    /// 「今日已拍 / 往日已拍 / 还没拍」是不重不漏的三分，所以筛选项也按这三档来分
    /// （再加上一个不做过滤的「全部」，共四档）——共用一档「已拍」并集会让
    /// 「点 2 个的块、列出 3 张卡片」。
    enum Filter: String, CaseIterable, Identifiable {
        case all, today, earlier, never

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .today: return "今日"
            case .earlier: return "往日"
            case .never: return "未拍"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SLSpacing.medium) {
                    dateHeader

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
            .navigationTitle("今日拍摄")
            .navigationBarTitleDisplayMode(.large)
        }
        .shotFlow(sheet: $sheet)
    }

    // MARK: - 数据

    private var todayRecorded: [Shot] { store.todayRecordedShots }
    private var earlierRecorded: [Shot] { store.shots.filter { $0.status() == .shotEarlier } }
    /// 从未拍过的镜头 ——「还没拍」统计块与「未拍」筛选共用这个含义，
    /// 它与「今日已拍」「往日已拍」一起构成不重不漏的三分。
    private var neverShot: [Shot] { store.shots.filter { !$0.hasClip } }
    /// 今天还没拍的镜头（含往日拍过的，今天都可以补）——今日页的进度与提示用它
    private var nextTodayPending: Shot? { store.todayPendingShots.first }

    private var filteredShots: [Shot] {
        switch filter {
        case .all: return store.shots
        case .today: return todayRecorded
        case .earlier: return earlierRecorded
        case .never: return neverShot
        }
    }

    private var emptyFilterHint: String {
        switch filter {
        case .all: return "还没有分镜。"
        case .today: return "今天还没拍。"
        case .earlier: return "往日没拍过。"
        case .never: return "所有镜头都拍完了。"
        }
    }

    // MARK: - 头部

    private var dateHeader: some View {
        Text(SLDateText.monthDayWeekday(Date()))
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SLSpacing.small)
            .accessibilityAddTraits(.isHeader)
    }

    private var progressCard: some View {
        CardContainer {
            HStack(spacing: SLSpacing.large) {
                ProgressRing(progress: store.todayProgress)

                VStack(alignment: .leading, spacing: SLSpacing.small) {
                    Text("\(store.todayRecordedCount) / \(store.shots.count)")
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text("今天已经拍了 \(store.todayRecordedCount) 个镜头")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let next = nextTodayPending {
                        Label("下一个：镜头 \(next.paddedNumber)", systemImage: "arrow.right.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Label("今天的分镜都拍完了", systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)
            }
        }
    }

    private var statRow: some View {
        HStack(spacing: SLSpacing.small) {
            statTile(
                value: todayRecorded.count,
                status: .shotToday,
                caption: "今日已拍",
                filterTarget: .today
            )
            statTile(
                value: earlierRecorded.count,
                status: .shotEarlier,
                caption: "往日已拍",
                filterTarget: .earlier
            )
            statTile(
                value: neverShot.count,
                status: .notShot,
                caption: "还没拍",
                filterTarget: .never
            )
        }
    }

    private func statTile(
        value: Int,
        status: ShotStatus,
        caption: String,
        filterTarget: Filter
    ) -> some View {
        Button {
            filter = filterTarget
            Haptics.selection()
        } label: {
            VStack(spacing: SLSpacing.tiny) {
                Image(systemName: status.symbolName)
                    .font(.title3)
                    .foregroundStyle(status.tint)
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
                ShotCardView(shot: shot, clipURL: store.clipURL(for: shot)) {
                    Haptics.impact(.light)
                    sheet = .options(shot)
                }
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有分镜", systemImage: "checklist")
        } description: {
            Text("先到「分镜」标签页添加镜头，这里就会显示今天的拍摄进度。")
        }
    }
}

#Preview {
    TodayView()
        .environmentObject(ShotStore())
}
