import SwiftUI

/// 「导出」标签页：把所有镜头的视频统一打包，分享到剪映、文件或电脑。
struct ExportView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var scope: ExportScope = .recordedOnly
    /// 导出格式是**用户偏好**，不是这一次导出的临时选择：写进偏好里，
    /// 镜头面板的文件名预览与这里读同一个键，改一处两边一致。
    @AppStorage(ExportTranscodeOption.storageKey) private var transcodeOption: ExportTranscodeOption = .original
    @StateObject private var export = ExportSession()
    @State private var showClearConfirm = false
    /// 打开「清理未使用文件」确认弹窗时把数量拍成文案。
    /// 不能等弹窗渲染时现读 `store`——那时文件已经删了，文案会变成「0 个」。
    @State private var orphanPrompt: String?

    /// 支持调试启动参数 `-preselectStylePage`：验收截图直接停在「剪辑风格」页。
    ///
    /// 与 `-preselectTab` / `-preselectFilm` / `-preselectShot` 同一套用法。
    /// 这一页是 `NavigationLink` 推出来的，没有参数就只能靠手点，
    /// 而本机没有可用的点击自动化（见 AGENTS.md 的验收方式）。
    @State private var isShowingStylePage =
        ProcessInfo.processInfo.arguments.contains("-preselectStylePage")

    /// 「已拍」读 `store` 的磁盘口径，与素材概览里的「已拍 N / M」是同一个判据
    private var recordedShots: [Shot] { store.recordedShots }

    /// 当前影片的展示名（带书名号），用在确认弹层与说明文字里
    private var filmName: String {
        guard let film = store.currentFilm else { return "当前影片" }
        return "《\(film.displayTitle)》"
    }

    /// 删除确认的正文：只写波及的数量与不可恢复。
    ///
    /// 空白影片删完会立刻补一部新的，没有数量可写，此时不写正文，
    /// 免得出现「0 个镜头、0 段视频」这种什么都没说的句子。
    private var deleteMessage: String? {
        guard !store.shots.isEmpty else { return nil }
        return "\(store.shots.count) 个镜头、\(store.clipCount) 段视频将被删除，无法恢复。"
    }

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                styleSection
                buildSection
                if let package = export.package {
                    resultSection(package)
                }
                if export.isStale {
                    Section {
                        Label("需重新打包", systemImage: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                }
                contentsSection
                if !recordedShots.isEmpty {
                    clipsSection
                }
                computerSection
                maintenanceSection
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, -SLSpacing.groupedListTopSlack, for: .scrollContent)
            .navigationTitle("导出")
            // 标题与右侧内容同行（inlineLarge），不单独占一行；三页起始位置一致
            .toolbarTitleDisplayMode(.inlineLarge)
            // 只在带了 `-preselectStylePage` 时才为 true，正常使用不受影响
            .navigationDestination(isPresented: $isShowingStylePage) {
                FilmStyleView()
            }
        }
        .onChange(of: store.shots) { _, _ in export.invalidate() }
        // 剪辑风格写进了包内的「剪辑风格.md」，改了它，已生成的包就是旧的
        .onChange(of: store.currentFilm?.stylePrompt) { _, _ in export.invalidate() }
        // 切到别的影片之后，已经生成的包不再属于「当前这部影片」，必须一起作废
        .onChange(of: store.currentFilmID) { _, _ in export.invalidate() }
        .onChange(of: scope) { _, _ in export.invalidate() }
        .onChange(of: transcodeOption) { _, _ in export.invalidate() }
        .alert("导出失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(export.errorMessage ?? "")
        }
        .alert("删除影片？", isPresented: $showClearConfirm) {
            Button("删除", role: .destructive) {
                store.deleteCurrentFilm()
                export.invalidate()
                Haptics.warning()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let deleteMessage {
                Text(deleteMessage)
            }
        }
        .alert("清理未使用文件？", isPresented: orphanBinding) {
            Button("删除", role: .destructive) {
                store.removeOrphanFiles()
                Haptics.warning()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(orphanPrompt ?? "")
        }
    }

    // MARK: - 概览

    private var overviewSection: some View {
        Section {
            HStack(spacing: SLSpacing.large) {
                ProgressRing(progress: store.progress, size: 76, lineWidth: 9)

                // 每一行都是「图标 + 数字」：已拍镜头、视频段数、总时长、占用空间
                VStack(alignment: .leading, spacing: SLSpacing.tiny) {
                    IconValue(systemImage: "checkmark.circle", text: "\(store.recordedCount) / \(store.shots.count)")
                        .font(.headline)
                    Group {
                        IconValue(systemImage: "square.stack.3d.up", text: "\(store.clipCount)")
                        IconValue(systemImage: "clock", text: store.totalDuration.slDurationText)
                        IconValue(systemImage: "internaldrive", text: store.totalClipBytes.slByteText)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, SLSpacing.tiny)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("素材")
            .accessibilityValue(
                "\(filmName)，已拍 \(store.recordedCount) / \(store.shots.count)，\(store.clipCount) 段，\(store.totalDuration.slDurationText)，\(store.totalClipBytes.slByteText)"
            )
        } header: {
            SectionHeader(title: "素材", systemImage: "chart.pie")
        }
    }

    // MARK: - 剪辑风格

    /// 剪辑风格描述是这次导出的输入：改了它，已经生成的包就不再对应当前设定。
    private var stylePrompt: String { store.currentFilm?.stylePrompt ?? "" }

    /// 列表里那一行的内容：没写就写「未设置」，
    /// 而不是显示一片空白——空白看起来像加载失败。
    private var styleSummary: String {
        guard !stylePrompt.isEmpty else { return "未设置" }
        // 多行描述压成一行预览，省得这几行把导出页撑得很长
        return stylePrompt
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    private var styleSection: some View {
        Section {
            NavigationLink {
                FilmStyleView()
            } label: {
                // 分组标题已经是「剪辑风格」，这一行只给内容，不再重复标题
                Text(styleSummary)
                    .foregroundStyle(stylePrompt.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: SLSize.minTouchTarget, alignment: .leading)
            }
            .accessibilityLabel("剪辑风格")
            .accessibilityValue(styleSummary)
        } header: {
            SectionHeader(title: "剪辑风格", systemImage: "text.alignleft")
        }
    }

    // MARK: - 打包

    private var buildSection: some View {
        Section {
            // 导出只针对当前影片：用户手上可能有好几部影片，
            // 而「导出」这个词本身不区分范围，所以把片名摆在这里
            Label(filmName, systemImage: "film")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("范围", selection: $scope) {
                ForEach(ExportScope.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("范围")

            // 默认「原片」：导入与拍摄都不转码，导出也就不该偷偷转一遍。
            // 需要发给别人、或者要在老设备上播放时，才在这一步换格式。
            Picker(selection: $transcodeOption) {
                ForEach(ExportTranscodeOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("格式", systemImage: "film")
            }
            .accessibilityLabel("格式")
            .accessibilityValue(transcodeOption.title)

            Button {
                build()
            } label: {
                HStack {
                    Label("打包", systemImage: "shippingbox")
                    Spacer()
                    if export.isBuilding {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(minHeight: SLSize.minTouchTarget)
            }
            .disabled(export.isBuilding || store.recordedCount == 0)

            if let progress = export.progress {
                buildProgress(progress)
            }

            if store.recordedCount == 0 {
                Label("无可导出视频", systemImage: "video.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionHeader(title: "打包导出", systemImage: "shippingbox")
        } footer: {
            // 没有素材时不必先讲格式的取舍
            if store.recordedCount > 0 {
                Text(transcodeOption.detail)
            }
        }
    }

    /// 转码一段素材要几十秒，进度得说明「动到哪了」——
    /// 只有一个转圈的话，包越大越像卡死。
    private func buildProgress(_ progress: ExportProgress) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.tiny) {
            ProgressView(value: progress.fraction)

            Text(progress.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.text)
        .accessibilityValue("已完成 \(Int(progress.fraction * 100))%")
    }

    private func resultSection(_ package: ExportPackage) -> some View {
        Section {
            HStack(spacing: SLSpacing.medium) {
                Image(systemName: "doc.zipper")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.fileName)
                        // semibold 统一为 headline（17pt）：与其他页面的主文本同级同大
                        .font(.headline)
                        .lineLimit(2)
                    Text(package.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(package.byteCount.slByteText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            ShareLink(
                item: package.zipURL,
                subject: Text("分镜导出包"),
                message: Text("\(package.clipCount) 段视频")
            ) {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(minHeight: SLSize.minTouchTarget)
            }
        } header: {
            SectionHeader(title: "导出包", systemImage: "checkmark.seal")
        }
    }

    private var contentsSection: some View {
        Section {
            contentsRow("film", exampleMainFileName, tag: "主素材")
            contentsRow("square.stack.3d.up", exampleAlternateFileName, tag: "备用")
            contentsRow("tablecells", "分镜清单.csv")
            contentsRow("doc.text", "分镜文字内容指南.md")
            contentsRow("text.alignleft", "剪辑风格.md")
            contentsRow("info.circle", "导出说明.txt")
        } header: {
            SectionHeader(title: "包内文件", systemImage: "doc.text.magnifyingglass")
        }
    }

    // MARK: - 压缩包内容示例

    /// 示例文件名取自真实的分镜，而不是写死的文案：
    /// 有已拍镜头就用它的实际命名，随拍摄动态变化；一个分镜都没有时退回通用占位。
    private var exampleShot: Shot? {
        recordedShots.first ?? store.shots.first
    }

    /// 主素材示例，例如「夏日vlog-01-3.mov」。
    /// 复用导出时的命名函数，页面展示与实际打包结果永远一致：
    /// 拍了多条的镜头带片段序号（主素材条号按拍摄时间确定），只拍一条时不带。
    ///
    /// 一个镜头都没有时给的是纯编号（`01.mov`）——文件名里已经没有描述这一节，
    /// 不必再编一段假描述当占位。
    private var exampleMainFileName: String {
        let takeIndex: Int? = {
            guard let shot = exampleShot, shot.clipCount > 1 else { return nil }
            return shot.latestTakeIndex
        }()
        return ExportPackageBuilder.exportedFileName(
            filmTitle: filmTitleToken,
            number: exampleShot?.number ?? 1,
            takeIndex: takeIndex,
            fileExtension: transcodeOption.exportedFileExtension(
                sourceExtension: exampleShot?.mainFileExtension ?? "mov"
            )
        )
    }

    /// 备用片段示例，例如「备用片段/夏日vlog-01-1.mov」，编号与主素材示例保持一致。
    private var exampleAlternateFileName: String {
        let name = ExportPackageBuilder.exportedFileName(
            filmTitle: filmTitleToken,
            number: exampleShot?.number ?? 1,
            takeIndex: 1,
            fileExtension: (exampleMainFileName as NSString).pathExtension
        )
        return "备用片段/\(name)"
    }

    /// 当前影片标题在文件名里的那一节；没起片名时为空串，文件名里就不出现标题
    private var filmTitleToken: String { store.currentFilm?.exportTitleToken ?? "" }

    /// 一行一个包内文件：图标表示类型，文件名等宽，需要区分的两类视频再加一个 2 字标签
    private func contentsRow(_ systemImage: String, _ name: String, tag: String? = nil) -> some View {
        HStack(spacing: SLSpacing.small) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(name)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: SLSpacing.small)
            if let tag {
                Text(tag)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 单条分享

    /// 只在有已拍镜头时出现（见 `body`），所以这里不需要空状态文字。
    private var clipsSection: some View {
        Section {
            ForEach(recordedShots) { shot in
                HStack(spacing: SLSpacing.medium) {
                    NumberBadge(number: shot.number, isRecorded: true, size: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(shot.displayDetail)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(clipSummary(for: shot))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: SLSpacing.small)

                    let urls = store.clipURLs(for: shot)
                    if !urls.isEmpty {
                        ShareLink(
                            items: urls,
                            subject: Text("镜头 \(shot.paddedNumber) \(shot.displayDetail)")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                        }
                        .accessibilityLabel("分享镜头 \(shot.number)")
                    }
                }
            }
        } header: {
            SectionHeader(title: "分享", systemImage: "square.and.arrow.up.on.square")
        }
    }

    /// 例如「2 段 · 18 秒 · 今天 22:14」
    private func clipSummary(for shot: Shot) -> String {
        var parts: [String] = []
        if shot.clipCount > 1 { parts.append("\(shot.clipCount) 段") }
        parts.append(shot.totalDuration.slDurationText)
        if let recordedAt = shot.shortRecordedAtText { parts.append(recordedAt) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 电脑

    private var computerSection: some View {
        Section {
            // 文件夹图标是「文件」App，显示器图标是 Mac；路径本身就是全部内容
            Label("我的 iPhone › 分镜助手 › 分镜视频", systemImage: "folder")
                .font(.subheadline)
                .accessibilityLabel("文件：我的 iPhone › 分镜助手 › 分镜视频")

            Label("访达 › 位置 › 分镜助手", systemImage: "desktopcomputer")
                .font(.subheadline)
                .accessibilityLabel("Mac：访达 › 位置 › 分镜助手")
        } header: {
            SectionHeader(title: "电脑", systemImage: "cable.connector")
        }
    }

    // MARK: - 维护

    private var maintenanceSection: some View {
        Section {
            // 只在真有这类文件时才出现。它们占着磁盘却不属于任何分镜，
            // 不出现这个入口的话用户看不到、也没法回收。
            if store.orphanFileCount > 0 {
                Button(role: .destructive) {
                    orphanPrompt = "\(store.orphanFileCount) 个文件 · \(store.orphanBytes.slByteText)，无法恢复。"
                } label: {
                    HStack {
                        Label("清理未使用文件", systemImage: "trash.slash")
                        Spacer(minLength: SLSpacing.small)
                        Text("\(store.orphanFileCount) 个 · \(store.orphanBytes.slByteText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: SLSize.minTouchTarget)
                }
            }

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("删除影片", systemImage: "trash")
            }
            // 禁用条件按「空影片」的口径判（isBlank = 无分镜且无标题），不能只看分镜数：
            // 只剩一部「起了名字但还没加镜头」的影片时，分镜数也是 0，但它有标题要清，
            // 而全应用只有这一个删除入口，禁用了这部影片就再也删不掉。
            .disabled(store.films.count <= 1 && (store.currentFilm?.isBlank ?? true))
        }
    }

    // MARK: - 动作

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { export.errorMessage != nil },
            set: { presented in if !presented { export.errorMessage = nil } }
        )
    }

    private var orphanBinding: Binding<Bool> {
        Binding(
            get: { orphanPrompt != nil },
            set: { presented in if !presented { orphanPrompt = nil } }
        )
    }

    private func build() {
        guard !export.isBuilding else { return }
        Haptics.impact(.light)
        // 快照这一份请求：打包期间用户改了范围或格式，结果就不该再被当成可分享的
        let request = ExportRequest(
            shots: store.shots,
            clipsDirectory: store.clipsDirectory,
            scope: scope,
            option: transcodeOption,
            filmTitle: store.currentFilm?.exportTitleToken ?? "",
            stylePrompt: stylePrompt
        )
        // 影片同样是这次导出的输入：切换影片后，这份结果就不再属于「刚刚生成的导出包」
        let filmID = store.currentFilmID
        Task {
            await export.build(request) {
                store.shots == request.shots
                    && scope == request.scope
                    && transcodeOption == request.option
                    && store.currentFilmID == filmID
                    && (store.currentFilm?.stylePrompt ?? "") == request.stylePrompt
            }
        }
    }

}

#Preview {
    ExportView()
        .environmentObject(ShotStore())
}
