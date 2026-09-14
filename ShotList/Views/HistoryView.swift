import SwiftUI

/// 「历史」标签页：选一天，看这一天每个镜头拍了什么。
///
/// 信息架构沿用原「今日」页（进度卡 + 统计块 + 筛选 + 卡片列表），
/// 把「固定看今天」换成「日历选任意一天」——结构上参考 PeakLog 历史记录页
/// 「先选日期、再看当天记录」的组织方式，但全部用系统原生组件搭：
/// 选日期用 `DatePicker(.graphical)`，不引入自绘日历。
/// 选中今天时就是原来的「今日」页，两页功能无缝接管。
struct HistoryView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var sheet: ShotSheet?
    @State private var selectedDate = Self.initialSelectedDate()
    /// 默认落在「当天」：历史页进来就是要看「这一天拍了什么」，
    /// 其余口径（全部 / 其他天 / 未拍）点统计块即可切换。
    @State private var filter: Filter = .thatDay

    /// 支持调试启动参数 `-preselectDay yyyy-MM-dd`：验收截图可以直接停在某个历史日期。
    private static func initialSelectedDate() -> Date {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-preselectDay"),
              index + 1 < arguments.count
        else { return Date() }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: arguments[index + 1]) ?? Date()
    }

    /// 筛选项与统计块一一对应。「当天已拍 / 其他天拍过 / 还没拍」是不重不漏的
    /// 三分——「其他天」专指有片段、但都不是这一天拍的镜头。
    enum Filter: String, CaseIterable, Identifiable {
        case all, thatDay, otherDays, never

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .thatDay: return "当天"
            case .otherDays: return "其他天"
            case .never: return "未拍"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SLSpacing.medium) {
                    if store.shots.isEmpty {
                        emptyState
                    } else {
                        calendarCard
                        dateHeader
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
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.large)
        }
        .shotFlow(sheet: $sheet)
    }

    // MARK: - 数据

    private var isSelectedToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    /// 这一天拍过的镜头（当天至少有一条片段）
    private var dayRecorded: [Shot] { store.recordedShots(on: selectedDate) }

    /// 有片段、但都不是这一天拍的镜头
    private var recordedOtherDays: [Shot] {
        let dayIDs = Set(dayRecorded.map(\.id))
        return store.shots.filter { $0.hasClip && !dayIDs.contains($0.id) }
    }

    /// 从未拍过的镜头
    private var neverShot: [Shot] { store.shots.filter { !$0.hasClip } }

    /// 这一天拍下的全部片段（跨镜头汇总，用于段数与总时长）
    private var dayClips: [ShotClip] {
        store.shots.flatMap { store.clips(of: $0, recordedOn: selectedDate) }
    }

    private var filteredShots: [Shot] {
        switch filter {
        case .all: return store.shots
        case .thatDay: return dayRecorded
        case .otherDays: return recordedOtherDays
        case .never: return neverShot
        }
    }

    private var emptyFilterHint: String {
        switch filter {
        case .all: return "还没有分镜。"
        case .thatDay: return isSelectedToday ? "今天还没拍。" : "这一天还没拍。"
        case .otherDays: return "没有在其他天拍过的镜头。"
        case .never: return "所有镜头都拍完了。"
        }
    }

    // MARK: - 选日期

    /// 系统月历。限定最晚只能选到今天——未来不会有拍摄记录。
    private var calendarCard: some View {
        CardContainer {
            DatePicker(
                "选择日期",
                selection: $selectedDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
    }

    private var dateHeader: some View {
        HStack(spacing: SLSpacing.small) {
            Text(SLDateText.monthDayWeekday(selectedDate))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let chip = relativeDayText {
                Text(chip)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, SLSpacing.small)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: SLSpacing.small)

            dayStepper
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// 「今天 / 昨天」角标；更早的日子日历里看得见，不必再标。
    private var relativeDayText: String? {
        if Calendar.current.isDateInToday(selectedDate) { return "今天" }
        if Calendar.current.isDateInYesterday(selectedDate) { return "昨天" }
        return nil
    }

    /// 前后翻一天。到今天为止——未来没有可回看的记录。
    private var dayStepper: some View {
        HStack(spacing: SLSpacing.tiny) {
            dayStepButton(systemImage: "chevron.left") { changeDay(-1) }
            dayStepButton(systemImage: "chevron.right", isDisabled: isSelectedToday) { changeDay(1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("切换日期")
    }

    private func dayStepButton(
        systemImage: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isDisabled ? Color(.tertiaryLabel) : Color.primary)
                .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(systemImage.contains("left") ? "前一天" : "后一天")
    }

    private func changeDay(_ offset: Int) {
        guard let day = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate),
              Calendar.current.startOfDay(for: day) <= Calendar.current.startOfDay(for: Date())
        else { return }
        selectedDate = day
        Haptics.selection()
    }

    // MARK: - 当天概览

    private var progressCard: some View {
        CardContainer {
            HStack(spacing: SLSpacing.large) {
                ProgressRing(progress: store.progress(on: selectedDate))

                VStack(alignment: .leading, spacing: SLSpacing.small) {
                    Text("\(dayRecorded.count) / \(store.shots.count)")
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text(summaryText)
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

    private var summaryText: String {
        if isSelectedToday { return "今天已经拍了 \(dayRecorded.count) 个镜头" }
        return dayRecorded.isEmpty ? "这一天还没有拍过" : "这一天拍了 \(dayRecorded.count) 个镜头"
    }

    /// 今天给「下一个」补拍提示（沿用今日页的习惯）；
    /// 历史日期给当天的段数与总时长；空空如就就不多说。
    @ViewBuilder
    private var footnote: some View {
        if isSelectedToday, let next = store.pendingShots(on: selectedDate).first {
            Label("下一个：镜头 \(next.paddedNumber)", systemImage: "arrow.right.circle.fill")
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
        } else if isSelectedToday {
            Label("今天的分镜都拍完了", systemImage: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        } else if let duration = dayDuration {
            Label("共 \(dayClips.count) 段 · 总时长 \(duration.slDurationText)", systemImage: "film.stack")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 这一天全部片段的总时长；一段都没有时为 nil
    private var dayDuration: TimeInterval? {
        let total = dayClips.reduce(0) { $0 + ($1.duration ?? 0) }
        return total > 0 ? total : nil
    }

    private var statRow: some View {
        HStack(spacing: SLSpacing.small) {
            statTile(
                value: dayRecorded.count,
                systemImage: "checkmark.circle.fill",
                tint: .green,
                caption: "当天已拍",
                filterTarget: .thatDay
            )
            statTile(
                value: recordedOtherDays.count,
                systemImage: "clock.badge.checkmark",
                tint: .indigo,
                caption: "其他天",
                filterTarget: .otherDays
            )
            statTile(
                value: neverShot.count,
                systemImage: "circle.dashed",
                tint: .orange,
                caption: "还没拍",
                filterTarget: .never
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

    /// 当天拍过的镜头，卡片按「当天最新一条」展示（缩略图、时长、时间都跟它走）；
    /// 当天没拍过的镜头维持默认口径（最近一条）。
    private func card(for shot: Shot) -> some View {
        let clipsOfDay = store.clips(of: shot, recordedOn: selectedDate)
        let latestOfDay = clipsOfDay.latestByRecordedAt

        return ShotCardView(
            shot: shot,
            clipURL: latestOfDay.map { store.clipURL(for: $0) } ?? store.clipURL(for: shot),
            displayClip: latestOfDay,
            takeCountOverride: latestOfDay == nil ? nil : clipsOfDay.count,
            totalDurationOverride: latestOfDay == nil
                ? nil
                : clipsOfDay.reduce(0) { $0 + ($1.duration ?? 0) }
        ) {
            Haptics.impact(.light)
            sheet = .options(shot)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有分镜", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("先到「分镜」标签页添加镜头，这里就能按日期回看每天的拍摄记录。")
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(ShotStore())
}
