import SwiftUI

/// 「今日」标签页：一眼看清每个镜头今天是拍了还是没拍。
struct TodayView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var sheet: ShotSheet?
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, pending, recorded

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .pending: return "未拍"
            case .recorded: return "已拍"
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

    private var todayRecorded: [Shot] { store.shots.filter { $0.status() == .shotToday } }
    private var earlierRecorded: [Shot] { store.shots.filter { $0.status() == .shotEarlier } }
    private var pendingShots: [Shot] { store.shots.filter { !$0.hasClip } }
    private var nextPending: Shot? { pendingShots.first }

    private var filteredShots: [Shot] {
        switch filter {
        case .all: return store.shots
        case .pending: return pendingShots
        case .recorded: return store.shots.filter(\.hasClip)
        }
    }

    private var emptyFilterHint: String {
        switch filter {
        case .all: return "还没有分镜。"
        case .pending: return "所有镜头都拍完了。"
        case .recorded: return "还没有拍好的镜头。"
        }
    }

    // MARK: - 头部

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: SLSpacing.tiny) {
            Text(SLDateText.monthDayWeekday(Date()))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("下面是每个镜头今天的拍摄状态，点一下就能补拍。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SLSpacing.small)
        .accessibilityElement(children: .combine)
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

                    if let next = nextPending {
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
                filterTarget: .recorded
            )
            statTile(
                value: earlierRecorded.count,
                status: .shotEarlier,
                caption: "往日已拍",
                filterTarget: .recorded
            )
            statTile(
                value: pendingShots.count,
                status: .notShot,
                caption: "还没拍",
                filterTarget: .pending
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
