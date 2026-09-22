# 分镜助手 · 未关闭问题

更新日期：2026-09-22。共 **2 项未修复**：**P0 0 项、P1 0 项、P2 2 项**。保留原问题编号，按优先级及编号排序。

未修复问题保留在优先级分组；完成项移至 [resolved-issues](resolved-issues.md)，保留验证和修复提交以便追溯。复现状态沿用已有审查证据；涉及文件破坏或故障注入的步骤使用隔离测试数据。

## 汇总 Checklist

| 完成 | 编号 | 问题标题 |
|:--:|---|---|
| ☐ | P2-54 | [会话侧拒绝开始录制时，录制按钮只是闪一下又复原，不回调也不提示](#p2-54) |
| ☐ | P2-57 | [首次进相机时体积上限可能仍停在 600 MB，P2-36 的按码率放宽只在改过画质或切过摄像头之后才生效](#p2-57) |

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
