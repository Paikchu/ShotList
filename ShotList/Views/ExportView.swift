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
    /// 打开「清理未使用的文件」确认弹窗时把数量拍成一句话。
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

    /// 删除确认的正文。
    ///
    /// 空白影片删完会立刻补一部新的，照抄「N 个分镜和 N 段视频都会被删除」会出现
    /// 「0 个分镜和 0 段视频」这种什么都没说的句子，所以这里分两句写。
    private var deleteMessage: String {
        guard !store.shots.isEmpty else {
            return "\(filmName)会从影片库里移除，并回到一部空白影片。其他影片不受影响。"
        }
        return "\(filmName)的 \(store.shots.count) 个分镜和 \(store.clipCount) 段视频都会被删除，无法恢复。其他影片不受影响。"
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
                        Text("分镜、素材或导出范围已变化，请重新生成导出包。")
                            .foregroundStyle(.secondary)
                    }
                }
                contentsSection
                clipsSection
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
        .alert("删除当前影片？", isPresented: $showClearConfirm) {
            Button("删除影片", role: .destructive) {
                store.deleteCurrentFilm()
                export.invalidate()
                Haptics.warning()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .alert("清理未使用的文件？", isPresented: orphanBinding) {
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

                VStack(alignment: .leading, spacing: SLSpacing.tiny) {
                    Text("已拍 \(store.recordedCount) / \(store.shots.count) 个镜头")
                        .font(.headline)
                    Text("共 \(store.clipCount) 段视频")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("总时长 \(store.totalDuration.slDurationText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("占用空间 \(store.totalClipBytes.slByteText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, SLSpacing.tiny)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("素材概览")
            .accessibilityValue(
                "\(filmName)，已经拍了 \(store.recordedCount) 个镜头，共 \(store.shots.count) 个，\(store.clipCount) 段视频，总时长 \(store.totalDuration.slDurationText)，占用空间 \(store.totalClipBytes.slByteText)"
            )
        } header: {
            SectionHeader(title: "素材概览", systemImage: "chart.pie")
        }
    }

    // MARK: - 剪辑风格

    /// 剪辑风格描述是这次导出的输入：改了它，已经生成的包就不再对应当前设定。
    private var stylePrompt: String { store.currentFilm?.stylePrompt ?? "" }

    /// 列表里那一行的副标题：没写就明说「未写」，
    /// 而不是显示一片空白——空白看起来像加载失败。
    private var styleSummary: String {
        guard !stylePrompt.isEmpty else { return "未写，这次导出不带风格要求" }
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
                HStack(spacing: SLSpacing.medium) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("剪辑风格")
                            // semibold 统一为 headline（17pt）：与其他页面的主文本同级同大
                            .font(.headline)
                        Text(styleSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: SLSize.minTouchTarget)
            }
            .accessibilityLabel("剪辑风格")
            .accessibilityValue(styleSummary)
            .accessibilityHint("写一段话说明这条片子该怎么剪")
        } header: {
            SectionHeader(title: "剪辑风格", systemImage: "text.alignleft")
        } footer: {
            Text("描述整部影片怎么剪，导出时写进包里的「剪辑风格.md」。每镜显示什么字，写在各个镜头的屏幕字幕与角标文字里。")
        }
    }

    // MARK: - 打包

    private var buildSection: some View {
        Section {
            // 作用域收敛到当前影片之后，这句话必须写出来：用户手上可能有好几部影片，
            // 而「导出」这个词本身不区分范围
            Text("只会导出\(filmName)的镜头，别的影片不会被一起带走。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("导出范围", selection: $scope) {
                ForEach(ExportScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("导出范围")

            // 默认「原片」：导入与拍摄都不转码，导出也就不该偷偷转一遍。
            // 需要发给别人、或者要在老设备上播放时，才在这一步换格式。
            Picker("视频格式", selection: $transcodeOption) {
                ForEach(ExportTranscodeOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityLabel("视频格式")
            .accessibilityValue(transcodeOption.title)
            .accessibilityHint(transcodeOption.detail)

            Button {
                build()
            } label: {
                HStack {
                    Label("生成导出包", systemImage: "shippingbox")
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
                Text("还没有可导出的视频。先到「分镜」里拍一段，再回来导出。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionHeader(title: "打包导出", systemImage: "shippingbox")
        } footer: {
            // 没有素材时不必先讲格式的取舍，先让用户去拍
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
                message: Text("共 \(package.clipCount) 段镜头视频")
            ) {
                Label("分享 / 存储到「文件」", systemImage: "square.and.arrow.up")
                    .frame(minHeight: SLSize.minTouchTarget)
            }
            .accessibilityHint("在分享面板里选剪映可以直接导入，选存储到文件可以保存到云盘或本机")
        } header: {
            SectionHeader(title: "刚刚生成的导出包", systemImage: "checkmark.seal")
        }
    }

    private var contentsSection: some View {
        Section {
            contentsRow(exampleMainFileName, "每个镜头最新的一条（主素材）；同一个分镜拍了好几条时，末尾的片段序号用来区分候选，只拍一条时不带")
            contentsRow(exampleAlternateFileName, "同一个分镜更早拍的片段，片段序号越小拍得越早")
            contentsRow("分镜清单.csv", "编号、描述、屏幕字幕、角标文字，以及每条片段的时长与文件名")
            contentsRow("分镜文字内容指南.md", "镜头文字内容与素材的对照表，可直接交给 AI 剪辑")
            contentsRow("剪辑风格.md", "你写的那段剪辑要求：怎么剪、要什么观感；没写就不产出这个文件")
            contentsRow("导出说明.txt", "解压、导入剪映、传到电脑的步骤")
        } header: {
            SectionHeader(title: "压缩包里有什么", systemImage: "doc.text.magnifyingglass")
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

    private func contentsRow(_ name: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 单条分享

    private var clipsSection: some View {
        Section {
            if recordedShots.isEmpty {
                Text("还没有拍好的镜头。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
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
                            .accessibilityLabel(
                                shot.clipCount > 1
                                ? "分享镜头 \(shot.number) 的 \(shot.clipCount) 段视频"
                                : "分享镜头 \(shot.number) 的视频"
                            )
                        }
                    }
                }
            }
        } header: {
            SectionHeader(title: "单独分享某个镜头", systemImage: "square.and.arrow.up.on.square")
        }
    }

    /// 例如「2 段 · 共 18 秒 · 今天 22:14」
    private func clipSummary(for shot: Shot) -> String {
        var parts: [String] = []
        if shot.clipCount > 1 { parts.append("\(shot.clipCount) 段") }
        parts.append("共 \(shot.totalDuration.slDurationText)")
        if let recordedAt = shot.shortRecordedAtText { parts.append(recordedAt) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 电脑

    private var computerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("在「文件」App 里")
                    .font(.subheadline)
                Text("我的 iPhone › 分镜助手 › 分镜视频")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 2) {
                Text("在 Mac 上")
                    .font(.subheadline)
                Text("访达 › 位置 › 分镜助手")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } header: {
            SectionHeader(title: "用数据线取到电脑", systemImage: "cable.connector")
        }
    }

    // MARK: - 维护

    private var maintenanceSection: some View {
        Section {
            // 只在真有这类文件时才出现。它们占着磁盘却不属于任何分镜，
            // 不出现这个入口的话用户看不到、也没法回收。
            if store.orphanFileCount > 0 {
                Button(role: .destructive) {
                    orphanPrompt = "\(store.orphanFileCount) 个文件（\(store.orphanBytes.slByteText)）不属于任何分镜，删除后无法恢复。"
                } label: {
                    HStack {
                        Label("清理未使用的文件", systemImage: "trash.slash")
                        Spacer(minLength: SLSpacing.small)
                        Text("\(store.orphanFileCount) 个 · \(store.orphanBytes.slByteText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: SLSize.minTouchTarget)
                }
                .accessibilityHint("删除「分镜视频」目录里没有被任何分镜引用的文件")
            }

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("删除当前影片", systemImage: "trash")
            }
            // 禁用条件按「空影片」的口径判（isBlank = 无分镜且无标题），不能只看分镜数：
            // 只剩一部「起了名字但还没加镜头」的影片时，分镜数也是 0，但它有标题要清，
            // 而全应用只有这一个删除入口，禁用了这部影片就再也删不掉。
            .disabled(store.films.count <= 1 && (store.currentFilm?.isBlank ?? true))
        } footer: {
            Text("所有数据只保存在这台设备上。")
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
