import SwiftUI

/// 「导出」标签页：把所有镜头的视频统一打包，分享到剪映、文件或电脑。
struct ExportView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var scope: ExportScope = .recordedOnly
    @State private var package: ExportPackage?
    @State private var isBuilding = false
    @State private var errorMessage: String?
    @State private var showClearConfirm = false
    /// 打开「清理未使用的文件」确认弹窗时把数量拍成一句话。
    /// 不能等弹窗渲染时现读 `store`——那时文件已经删了，文案会变成「0 个」。
    @State private var orphanPrompt: String?

    private var recordedShots: [Shot] { store.shots.filter(\.hasClip) }

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                buildSection
                if let package {
                    resultSection(package)
                }
                contentsSection
                clipsSection
                computerSection
                maintenanceSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.large)
        }
        .alert("导出失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("清空所有分镜和视频？", isPresented: $showClearConfirm) {
            Button("全部清空", role: .destructive) {
                store.deleteEverything()
                package = nil
                Haptics.warning()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(store.shots.count) 个分镜和 \(store.recordedCount) 段视频都会被删除，无法恢复。")
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
                "已经拍了 \(store.recordedCount) 个镜头，共 \(store.shots.count) 个，\(store.clipCount) 段视频，总时长 \(store.totalDuration.slDurationText)，占用空间 \(store.totalClipBytes.slByteText)"
            )
        } header: {
            SectionHeader(title: "素材概览", systemImage: "chart.pie")
        }
    }

    // MARK: - 打包

    private var buildSection: some View {
        Section {
            Picker("导出范围", selection: $scope) {
                ForEach(ExportScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("导出范围")

            Button {
                build()
            } label: {
                HStack {
                    Label("生成导出包", systemImage: "shippingbox")
                    Spacer()
                    if isBuilding {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(minHeight: SLSize.minTouchTarget)
            }
            .disabled(isBuilding || store.recordedCount == 0)

            if store.recordedCount == 0 {
                Text("还没有拍好的视频。先到「分镜」里拍一段，再回来导出。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionHeader(title: "打包导出", systemImage: "shippingbox")
        }
    }

    private func resultSection(_ package: ExportPackage) -> some View {
        Section {
            HStack(spacing: SLSpacing.medium) {
                Image(systemName: "doc.zipper")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.fileName)
                        .font(.subheadline.weight(.semibold))
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
            contentsRow("01_无人机缓慢上升.mov", "每个镜头最新的一条，按编号前缀命名；扩展名跟随源文件")
            contentsRow("备用片段/01-1_….mov", "同一个镜头更早拍的片段")
            contentsRow("分镜清单.csv", "编号、描述、状态，以及每条片段的时长与文件名")
            contentsRow("分镜文字内容指南.md", "镜头文字内容与素材的对照表，可直接交给 AI 剪辑")
            contentsRow("导出说明.txt", "解压、导入剪映、传到电脑的步骤")
        } header: {
            SectionHeader(title: "压缩包里有什么", systemImage: "doc.text.magnifyingglass")
        }
    }

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
                Label("清空所有分镜和视频", systemImage: "trash")
            }
            .disabled(store.shots.isEmpty)
        } footer: {
            Text("所有数据只保存在这台设备上。")
        }
    }

    // MARK: - 动作

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in if !presented { errorMessage = nil } }
        )
    }

    private var orphanBinding: Binding<Bool> {
        Binding(
            get: { orphanPrompt != nil },
            set: { presented in if !presented { orphanPrompt = nil } }
        )
    }

    private func build() {
        guard !isBuilding else { return }
        isBuilding = true
        Haptics.impact(.light)

        let shots = store.shots
        let clipsDirectory = store.clipsDirectory
        let currentScope = scope

        Task {
            let outcome = await ExportPackageBuilder.buildOffMain(
                shots: shots,
                clipsDirectory: clipsDirectory,
                scope: currentScope
            )

            isBuilding = false
            switch outcome {
            case .success(let value):
                package = value
                Haptics.success()
            case .failure(let message):
                Haptics.error()
                errorMessage = message
            }
        }
    }
}

#Preview {
    ExportView()
        .environmentObject(ShotStore())
}
