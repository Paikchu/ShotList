# 分镜助手 · 未关闭问题

更新日期：2026-09-23。共 **5 项未修复**：**P0 0 项、P1 0 项、P2 5 项**。保留原问题编号，按优先级及编号排序。

未修复问题保留在优先级分组；完成项移至 [resolved-issues](resolved-issues.md)，保留验证和修复提交以便追溯。复现状态沿用已有审查证据；涉及文件破坏或故障注入的步骤使用隔离测试数据。

## 汇总 Checklist

| 完成 | 编号 | 问题标题 |
|:--:|---|---|
| ☐ | P2-54 | [会话侧拒绝开始录制时，录制按钮只是闪一下又复原，不回调也不提示](#p2-54) |
| ☐ | P2-57 | [首次进相机时体积上限可能仍停在 600 MB，P2-36 的按码率放宽只在改过画质或切过摄像头之后才生效](#p2-57) |
| ☐ | P2-59 | [导出说明.txt 不管包里有没有，都列出「备用片段/」和「剪辑风格.md」](#p2-59) |
| ☐ | P2-60 | [分镜文字内容指南的「总时长」把备用片段也算进去，按它估算可用素材会多算](#p2-60) |
| ☐ | P2-61 | [相册导入的片段把导入时间记成拍摄时间，导出清单与指南里的「拍摄时间」不是素材实际拍摄的时间](#p2-61) |

☐ 未修复；☑ 修复并验证通过。

## P0

暂无未修复问题。

## P1

暂无未修复问题。

## P2

<a id="p2-54"></a>

### P2-54 · 会话侧拒绝开始录制时，录制按钮只是闪一下又复原，不回调也不提示

**验证状态：** 代码级确认（需真机摄像头，未实测）

**代码位置：** ShotList/Camera/CameraRecorder.swift · `startRecording(completion:)`（第 343–369 行，第 357–366 行的会话侧校验）；ShotList/Views/CameraCaptureView.swift · `toggleRecording()`

**问题详情**

**预期行为：** 点了录制却没能开始时，用户要知道没开始、最好知道为什么；调用方要能收到结果。

**实际行为：** `startRecording` 先在主线程乐观置位（`isRecording = true`、启动计时器、`Haptics.impact(.medium)`），再到 `sessionQueue` 做二次校验 `!movieOutput.isRecording && movieOutput.connection(with: .video) != nil`。校验失败时只回主线程把 `isRecording`、计时器、`elapsed` 复原，并 `completion = nil`——**既不调用 completion，也不置任何错误信息**。用户看到的是：按钮变成录制态、手上有一下震动，随即又变回去，没有任何说明；调用方的回调永远不会触发，无法区分「没开始」与「还在录」。

**根因证据：** `CameraRecorder.swift:357-366` 失败分支里只有状态复原与 `self.completion = nil`，没有 `handler(.failure(...))`，也没有写 `settingsError` 之类的界面可读状态。

**影响范围与定级依据：** 会话侧校验失败需要 `movieOutput` 仍在收尾上一段（`isRecording` 尚未归 false）或视频连接不存在，属于时序边界，正常点按一般碰不到；但碰到时用户只会以为按钮坏了，并会连续重试。不丢数据，定为 P2。**未实测**：模拟器没有摄像头，无法触发。

**复现方法**

1. 真机上进入任意镜头的取景页，开始录制一段，点停止后**立刻**再点一次录制（在上一段文件收尾完成之前）。
2. 或代码级验证：在 `sessionQueue` 的校验处临时让条件为假。
3. 观察：录制按钮短暂进入录制态并伴随震动，随即复原，界面无任何提示，回看页不会出现。
4. 预期正确结果：给出一句说明（例如「上一段还在保存，请稍候」），或在上一段收尾期间禁用录制按钮；completion 以失败回调通知调用方。

**修复状态：** 待验证

**修复说明：** 会话侧校验失败分支（`CameraRecorder.swift`）在清空 `completion` 之前先取出它，再以 `.failure(CameraError.recordingNotReady)` 调用；新增的 `CameraError.recordingNotReady` 描述「上一段还在保存，请稍候再试。」。`CameraCaptureView.toggleRecording()` 的 `.failure(let error):` 分支已有 `errorMessage = "录制失败：\(error.localizedDescription)"`，不需要改动就能接住这条新错误，走现成的「操作未完成」提示弹层展示。未采用「收尾期间禁用按钮」的替代方案：回调已能让调用方区分「没开始」与「还在录」，改动范围更小。

**验证结果：** 代码级确认：已读代码确认失败分支现在会调用 `handler(.failure(CameraError.recordingNotReady))`，且 `CameraCaptureView` 的现有 `.failure` 分支未改动、能原样接住。Debug 构建 `BUILD SUCCEEDED`，无新增告警。**未验证**：本环境模拟器没有摄像头，`CameraRecorder.status` 到不了 `.ready`（`start()` 在 `configureIfNeeded` 处就会转入 `.unavailable`），`startRecording` 顶部的 `guard status == .ready` 会先一步拦下，根本进不到本次改动的会话侧校验分支，因此复现方法第 1、2 步的实际按钮行为与回看页表现均未能在此环境验证，需要真机确认。

**修复 commit：** 32f793cb7dfb643fdde9e86fb16204f7f19598e2

<a id="p2-57"></a>

### P2-57 · 首次进相机时体积上限可能仍停在 600 MB，P2-36 的按码率放宽只在改过画质或切过摄像头之后才生效

**验证状态：** 待验证（代码级推断，需真机确认 `outputSettings(for:)` 在嵌套配置块里的返回值）

**代码位置：** ShotList/Camera/CameraRecorder.swift · `configureIfNeeded(position:preferred:)`（第 690–745 行：第 700 行 `beginConfiguration()`、第 701 行 `defer { commitConfiguration() }`、第 733 行调用 `applyFormatLocked`）、`applyFormatLocked`（第 586–632 行：第 604 行 `beginConfiguration()`、第 624 行 `commitConfiguration()`、第 629 行 `updateMaximumFileSize()`）、`updateMaximumFileSize()`（第 643–658 行）

**问题详情**

**预期行为：** [P2-36](resolved-issues.md#p2-36) 的修复让体积上限按当前格式的实际码率放宽（`码率 ÷ 8 × 600 秒 × 1.15`，与 600 MB 取较大值），而且从第一次进相机就生效。

**实际行为（推断）：** 首次进相机时，`configureIfNeeded` 先 `beginConfiguration()` 并用 `defer` 把 `commitConfiguration()` 推到函数末尾，然后在这个**未提交的外层配置块内部**调用 `applyFormatLocked`。`applyFormatLocked` 自己再做一对 begin / commit，并在内层 commit 之后**立刻**调 `updateMaximumFileSize()` 读 `movieOutput.outputSettings(for:)`。`AVCaptureSession` 的 begin / commit 是按嵌套计数处理的，内层 commit 不会真正提交配置，所以此刻读到的输出设置可能还不对应新的 `activeFormat`，甚至是空字典；那样 `guard` 取不到 `AVVideoAverageBitRateKey`，就回落到固定的 600 MB。

后果是：用户一进相机就用默认档（或上次记住的 4K / 60 fps）开拍，体积上限仍是 600 MB——正是 P2-36 要修的症状；只有在拍摄设置里改过一次分辨率或帧率（`applyCaptureSettings` → `applyFormatLocked`，外面没有包配置块），或切过一次前后摄像头（`switchCamera` 在自己的 commit 之后才调 `applyFormatLocked`）之后，放宽才真正生效。

**根因证据：** 调用顺序可从代码直接确认——`configureIfNeeded` 第 700–701 行开外层块，第 733 行在块内调用 `applyFormatLocked`，后者第 629 行在内层 commit 后立即读取输出设置。**未证实**的是 `outputSettings(for:)` 在嵌套配置块内的确切返回值：Apple 文档没有明确说明，本环境没有真机摄像头无法测量，因此本条标记为待验证，而不是代码级确认。

**与 P2-36 的关系：** P2-36 已按用户验收结论移入已修复。本条是其修复实现上的一个独立缺陷（调用时机），不是原症状的同一根因，按 AGENTS.md 单独编号，不重开 P2-36。

**影响范围与定级依据：** 若推断成立，P2-36 的修复在最常见的路径（进相机直接拍）上不生效，高码率格式仍会远早于 10 分钟被截断；撞上限时已有「已达录制上限」提示，素材完好。定为 P2。

**复现方法**

1. 真机，在拍摄设置里选好 4K + 60 fps 后**完全关闭相机页**（让下次进入时走首次配置路径）。
2. 在 `updateMaximumFileSize()` 里临时加一条探针，打印读到的 `AVVideoAverageBitRateKey` 与最终写入的 `maxRecordedFileSize`。
3. 重新进入取景页（走 `configureIfNeeded`），观察探针：若码率为空、上限为 600 MB，则推断成立。
4. 对照：在拍摄设置里把帧率切到 30 再切回 60（走 `applyCaptureSettings`），观察探针此时读到的码率与上限。
5. 预期正确结果：两条路径写入的上限一致，都按码率放宽。
6. 验证完成后移除探针。

**修复状态：** 待验证

**修复说明：** 按最小改法实现：`start()` 里 `configureIfNeeded` 返回 `.success` 之后、`configureAudioSession()` / `session.startRunning()` 之前，加一次 `self.updateMaximumFileSize()`；这一步已经在外层 `commitConfiguration()`（`configureIfNeeded` 的 `defer`）执行之后，能读到已提交的格式。`applyFormatLocked` 内部那次调用原样保留，给单独改画质（`applyCaptureSettings`）与切摄像头（`switchCamera`）两条路径用——那两条路径本来就不在嵌套配置块里，不受影响。新增调用与原有调用一样只在 `sessionQueue` 上执行。`configureIfNeeded` 已配置过（`isConfigured` 为真）时也会走到这次新增调用，属于对同一份已生效格式的重复估算，结果不变，无副作用。

**验证结果：** 代码级确认：已读代码确认新调用点在外层 `commitConfiguration()` 之后、`sessionQueue` 内执行。Debug 构建 `BUILD SUCCEEDED`，无新增告警。**未验证**：本环境模拟器没有摄像头，`configureIfNeeded` 会直接返回 `.failure(CameraError.noCameraAvailable)`，`switch` 走不到本次改动所在的 `.success` 分支，因此完全没有机会触发这次改动，复现方法第 1–4 步的探针数值均未能在此环境验证；`outputSettings(for:)` 在嵌套配置块内的确切返回值这一推断本身仍未证实，需要真机按原复现方法确认。

**修复 commit：** a9a9d13dcc65ae2948f19274817f5e8d8b8a193e

<a id="p2-59"></a>

### P2-59 · 导出说明.txt 不管包里有没有，都列出「备用片段/」和「剪辑风格.md」

**验证状态：** 代码级确认；用户真机导出的 9.18Vlog 包（旧版构建）里同样出现

**代码位置：** ShotList/Support/ExportPackageBuilder.swift · `writeReadme`（第 780–850 行；目录一节第 813 行写「备用片段/」、第 816 行写「剪辑风格.md」，两行都不看条件）

**问题详情**

**预期行为：** 导出说明里的目录只列包内实际产出的文件。同一个文件里的指南（`writeTextGuide`）已经按 `hasStylePrompt` 分两种写法，说明也应如此。

**实际行为：** 目录说明是一段固定文字。每个镜头都只拍了一条时，包里不会有「备用片段」目录（`didCreateAlternateFolder` 一直为假）；没写剪辑风格时不会产出「剪辑风格.md」（`writeStylePrompt` 在描述为空时直接返回）；但导出说明照样列出这两行。

**根因证据：** `writeReadme` 拼接的 `text` 里，目录一节是无条件的多行字符串，只有后面的「备用片段（N）」清单与「待拍」清单才按数量判断。用户 9.18Vlog 导出包每镜 1 条、没有备用片段目录，`导出说明.txt` 仍写着「* 备用片段/ 更早的片段，如 9.18Vlog-01-1.mov」。

**影响范围与定级依据：** 读说明的人或 AI 会去找包里不存在的文件。只是说明文字不准，素材与清单不受影响；定为 P2。

**复现方法**

1. 模拟器安装 Debug 构建，准备一部影片：每个镜头只拍一条片段，且不写剪辑风格。
2. 「导出」页选「已拍」「原片」，点「打包导出」，把压缩包存到「文件」并解压。
3. 打开包内 `导出说明.txt`，看「目录」一节。
4. 实际：列出「* 备用片段/」与「* 剪辑风格.md」，而包里没有这两项；预期：这两行不出现。

**修复状态：** 未修复

**修复说明：** 待修复。按 `didCreateAlternateFolder`（或清单里有没有备用片段行）与 `stylePrompt` 是否为空拼目录，判据与产出条件同源。

**验证结果：** 待验证。

**修复 commit：** 待提交。

<a id="p2-60"></a>

### P2-60 · 分镜文字内容指南的「总时长」把备用片段也算进去，按它估算可用素材会多算

**验证状态：** 代码级确认

**代码位置：** ShotList/Support/ExportPackageBuilder.swift · `buildChecked` 第 483 行 `totalDuration += clip.duration ?? 0`（在主素材与备用片段共用的循环里）；`writeTextGuide` 第 1030 行「总时长」；同一个值还回传给 `ExportPackage.totalDuration`

**问题详情**

**预期行为：** 指南「四、汇总」里的「总时长」是给 AI 估算成片节奏用的。指南第二节第 2 条写明每个镜头只取一条素材，所以这个数应当是主素材的总长，或者至少说清口径。

**实际行为：** 累加的是包内每一条片段，包括「备用片段」目录里的。一个镜头拍了 3 条各 5 秒，就算成 15 秒。9.18Vlog 这类每镜一条的包看不出差别，拍过多条的影片会明显偏大。

**根因证据：** `totalDuration` 在 `for (offset, clip) in available` 循环体内累加，该循环同时处理主素材与备用片段；`writeTextGuide` 直接把它写成「总时长」，没有任何限定词。

**影响范围与定级依据：** AI 按它估算可用素材会多算，进而误判节奏；数字本身不影响素材与文件名。导出页结果一节的「N 段 · 时长」与「N 段」口径一致，可以保留。定为 P2。

**复现方法**

1. 模拟器，准备一部影片：镜头 1 拍 3 条（各约 5 秒），镜头 2 拍 1 条（约 5 秒）。
2. 「导出」页打包并解压。
3. 打开 `分镜文字内容指南.md` 的「四、汇总」。
4. 实际：总时长约 20 秒；预期：主素材总时长约 10 秒，或写明「全部片段合计」并另给主素材合计。

**修复状态：** 未修复

**修复说明：** 待修复。分别统计主素材与全部片段，指南里写清是哪一个。

**验证结果：** 待验证。

**修复 commit：** 待提交。

<a id="p2-61"></a>

### P2-61 · 相册导入的片段把导入时间记成拍摄时间，导出清单与指南里的「拍摄时间」不是素材实际拍摄的时间

**验证状态：** 代码级确认；用户真机导出的 9.18Vlog 包数据佐证

**代码位置：** ShotList/Models/ShotStore.swift · `addClip(from:duration:to:)` 第 636 行 `ShotClip(fileName:duration:recordedAt: Date())`；ShotList/Support/ExportPackageBuilder.swift · 第 723 行 CSV 的「拍摄时间」列、第 1004 行指南的「拍摄时间」；ShotList/Models/Shot.swift · `ShotClip.recordedAt`（注释写的是「这一条的拍摄时间」）、`status(relativeTo:)` 第 313 行

**问题详情**

**预期行为：** 导出包里写着「拍摄时间」的那一列，应当是这段素材真正拍摄的时间；相机拍的片段本来就是，相册导入的片段应取素材自带的拍摄时间。

**实际行为：** `addClip` 一律用 `Date()`，相册导入的片段记的是导入那一刻。导出的 CSV 与指南照抄这个值，字面写着「拍摄时间」。

**根因证据：** 9.18Vlog 导出包里，镜头 10 的 `分镜清单.csv` 写「9月18日 19:28」，而素材自带的 `com.apple.quicktime.creationdate` 是 `2026-09-18T10:27:58+08:00`；镜头 11 是「19:29」对 `18:04:39`。相机拍摄路径写入的同样是 `Date()`，但那一刻就是拍摄时刻，所以只有导入路径不准。

**影响范围与定级依据：** 导出包里的时间对不上实际拍摄，人和 AI 都无从校正；历史页按 `recordedAt` 归日期，导入的素材也会落在导入那天（这一条是否算缺陷取决于产品口径，修复前需确认）。不影响素材本身与成片，定为 P2。

**复现方法**

1. 准备一段前一天拍的视频，放进模拟器（或真机）相册。
2. 在任一镜头里用「导入」选中它。
3. 「导出」页打包并解压，看 `分镜清单.csv` 的「拍摄时间」列与指南里的「拍摄时间」。
4. 实际：写的是今天的导入时刻；预期：写素材自带的拍摄时间（`AVAsset` 的 `creationDate`）。
5. 对照：用相机现拍一条，两者应当一致。

**修复状态：** 未修复

**修复说明：** 待修复。两种改法待用户定：①（推荐）导入时读 `AVAsset` 的 `creationDate` 作为 `recordedAt`，读不到再退回 `Date()`；②保留现有语义，把导出里的列名改成「加入时间」。选 ① 时要一并确认历史页按拍摄日归类是否符合预期。

**验证结果：** 待验证。

**修复 commit：** 待提交。
