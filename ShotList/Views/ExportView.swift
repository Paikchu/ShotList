import SwiftUI

/// 「导出」标签页：把所有镜头的视频统一打包，分享到剪映、文件或电脑。
struct ExportView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var scope: ExportScope = .recordedOnly
    /// 导出格式是**用户偏好**，不是这一次导出的临时选择：写进偏好里，
    /// 镜头面板的文件名预览与这里读同一个键，改一处两边一致。
    @AppStorage(ExportTranscodeOption.storageKey) private var transcodeOption: ExportTranscodeOption = .original
    @StateObject private var export = ExportSession()
    /// 打开「清理未使用文件」确认弹窗时把数量拍成文案。
    /// 不能等弹窗渲染时现读 `store`——那时文件已经删了，文案会变成「0 个」。
    @State private var orphanPrompt: String?

    /// 当前影片的展示名（带书名号），用在导出设置与素材概览的朗读文本里
    private var filmName: String {
        guard let film = store.currentFilm else { return "当前影片" }
        return "《\(film.displayTitle)》"
    }

    var body: some View {
        NavigationStack {
            List {
                overviewSection
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
                // 只在磁盘上确有无归属文件时才出现
                if store.orphanFileCount > 0 {
                    maintenanceSection
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, SLSpacing.pageTopInset, for: .scrollContent)
            // 主操作固定在底部，不随列表滚动；列表末行自动让出它占的高度，
            // 滚到它下面的内容由系统做柔化，不会和按钮糊在一起
            .safeAreaBar(edge: .bottom) { exportButton }
            .navigationTitle("导出")
            // 标题与右侧内容同行（inlineLarge），不单独占一行；三页起始位置一致
            .toolbarTitleDisplayMode(.inlineLarge)
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
        }
    }

    // MARK: - 打包

    /// 剪辑风格描述是这次导出的输入：改了它，已经生成的包就不再对应当前设定。
    /// 风格本身在分镜页的影片菜单里写（`FilmStyleView`），导出页只读它。
    private var stylePrompt: String { store.currentFilm?.stylePrompt ?? "" }


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

            if let progress = export.progress {
                buildProgress(progress)
            }

            if store.recordedCount == 0 {
                Label("无可导出视频", systemImage: "video.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 固定在页面底部的独立主按钮：强调色实心，通栏。
    ///
    /// 没有已拍镜头或正在打包时置灰；打包中图标换成转圈。
    private var exportButton: some View {
        Button {
            build()
        } label: {
            HStack(spacing: SLSpacing.small) {
                if export.isBuilding {
                    // 与图标同高，按钮不因为转圈变高
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "shippingbox")
                }
                Text("打包导出")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(export.isBuilding || store.recordedCount == 0)
        .padding(.horizontal, SLSpacing.medium)
        .padding(.vertical, SLSpacing.small)
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

    // MARK: - 维护

    /// 只在真有无归属文件时才由 `body` 摆出来。它们占着磁盘却不属于任何分镜，
    /// 不出现这个入口的话用户看不到、也没法回收。
    private var maintenanceSection: some View {
        Section {
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
