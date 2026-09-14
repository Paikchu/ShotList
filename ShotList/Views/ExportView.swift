import SwiftUI

/// 「导出」标签页：把所有镜头的视频统一打包，分享到剪映、文件或电脑。
struct ExportView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var scope: ExportScope = .recordedOnly
    @State private var package: ExportPackage?
    @State private var isBuilding = false
    @State private var errorMessage: String?
    @State private var showClearConfirm = false

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
    }

    // MARK: - 概览

    private var overviewSection: some View {
        Section {
            HStack(spacing: SLSpacing.large) {
                ProgressRing(progress: store.progress, size: 76, lineWidth: 9)

                VStack(alignment: .leading, spacing: SLSpacing.tiny) {
                    Text("已拍 \(store.recordedCount) / \(store.shots.count) 个镜头")
                        .font(.headline)
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
                "已经拍了 \(store.recordedCount) 个镜头，共 \(store.shots.count) 个，总时长 \(store.totalDuration.slDurationText)，占用空间 \(store.totalClipBytes.slByteText)"
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

            Text(scope.footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)

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
        } footer: {
            Text("会生成一个压缩包：视频按编号前缀命名，另外附一份分镜清单 CSV 和导出说明。")
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
                message: Text("共 \(package.clipCount) 个镜头视频")
            ) {
                Label("分享 / 存储到「文件」", systemImage: "square.and.arrow.up")
                    .frame(minHeight: SLSize.minTouchTarget)
            }
            .accessibilityHint("在分享面板里选剪映可以直接导入，选存储到文件可以保存到云盘或本机")
        } header: {
            SectionHeader(title: "刚刚生成的导出包", systemImage: "checkmark.seal")
        } footer: {
            Text("分享面板里可以选「剪映」直接导入素材，选「存储到文件」保存到 iCloud 云盘或本机，也可以隔空投送到 Mac。")
        }
    }

    private var contentsSection: some View {
        Section {
            contentsRow("01_开场-城市天际线.mov", "视频按编号前缀命名，导入剪映后顺序与分镜一致")
            contentsRow("分镜清单.csv", "每个镜头的编号、标题、状态、时长与备注")
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
                            Text(shot.displayTitle)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: SLSpacing.small) {
                                if let duration = shot.durationText { Text(duration) }
                                if let recordedAt = shot.recordedAtText { Text(recordedAt) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: SLSpacing.small)

                        if let url = store.clipURL(for: shot) {
                            ShareLink(
                                item: url,
                                subject: Text("镜头 \(shot.paddedNumber) \(shot.displayTitle)")
                            ) {
                                Image(systemName: "square.and.arrow.up")
                                    .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                            }
                            .accessibilityLabel("分享镜头 \(shot.number) 的视频")
                        }
                    }
                }
            }
        } header: {
            SectionHeader(title: "单独分享某一段", systemImage: "square.and.arrow.up.on.square")
        }
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
        } footer: {
            Text("分镜视频都放在本应用的文稿目录里，并且已经对「文件」App 和访达开放，接上数据线就能直接拖走，不必另外导出。")
        }
    }

    // MARK: - 维护

    private var maintenanceSection: some View {
        Section {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空所有分镜和视频", systemImage: "trash")
            }
            .disabled(store.shots.isEmpty)
        } footer: {
            Text("本应用是纯本地单机应用，所有数据只保存在这台设备上，清空之后无法恢复。")
        }
    }

    // MARK: - 动作

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in if !presented { errorMessage = nil } }
        )
    }

    private func build() {
        guard !isBuilding else { return }
        isBuilding = true
        Haptics.impact(.light)

        let shots = store.shots
        let clipsDirectory = store.clipsDirectory
        let currentScope = scope

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try ExportPackageBuilder.build(
                    shots: shots,
                    clipsDirectory: clipsDirectory,
                    scope: currentScope
                )
            }

            DispatchQueue.main.async {
                isBuilding = false
                switch outcome {
                case .success(let value):
                    package = value
                    Haptics.success()
                case .failure(let error):
                    Haptics.error()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    ExportView()
        .environmentObject(ShotStore())
}
