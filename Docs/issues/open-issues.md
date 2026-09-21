# 分镜助手 · 未关闭问题

更新日期：2026-09-21。共 **3 项未修复**：**P0 0 项、P1 0 项、P2 3 项**。保留原问题编号，按优先级及编号排序。

未修复问题保留在优先级分组；完成项移至 [resolved-issues](resolved-issues.md)，保留验证和修复提交以便追溯。复现状态沿用已有审查证据；涉及文件破坏或故障注入的步骤使用隔离测试数据。

## 汇总 Checklist

| 完成 | 编号 | 问题标题 |
|:--:|---|---|
| ☐ | P2-36 | [选择 4K 或 60 fps 后单条录制会更早触到 600 MB 上限，停止时不给任何说明](#p2-36) |
| ☐ | P2-49 | [体积上限随画质放宽后磁盘可能被录满，而写满时仍然只是「自己停了」且没有任何说明](#p2-49) |
| ☐ | P2-50 | [录制失败时残缺的临时视频不会被删除，一直占着磁盘到下次启动](#p2-50) |

☐ 未修复；☑ 修复并验证通过。

## P0

暂无未修复问题。

## P1

暂无未修复问题。

## P2

<a id="p2-36"></a>

### P2-36 · 选择 4K 或 60 fps 后单条录制会更早触到 600 MB 上限，停止时不给任何说明

**验证状态：** 代码级确认（未在真机实测触发）

**代码位置：** ShotList/Camera/CameraRecorder.swift · maximumFileSize / configureIfNeeded、fileOutput(_:didFinishRecordingTo:from:error:)

**预期结果：** 单条录制因体积或时长上限结束时，向用户说明「这条已达上限并被保存」，并且在选到高码率格式时不至于在远未到 10 分钟时就被截断。

**问题详情**

`maxRecordedFileSize` 固定为 600 MB，与选中的分辨率、帧率无关。录制设置放开之后，同样的时长在高分辨率/高帧率下会产生成倍的字节数：

- 4K 与 60 fps 的码率远高于 1080p 30 fps，因此体积上限会先于时长上限生效，拍摄在远未到 10 分钟时就自行停止；
- `fileOutput(_:didFinishRecordingTo:from:error:)` 只区分「成功返回」与「失败」，达到上限时 AVFoundation 会带着 `AVErrorMaximumFileSizeReached` / `AVErrorMaximumDurationReached` 并把 `recordingSuccessfullyFinished` 置为 true，现有代码据此判为成功，于是界面直接进入回看，用户看到的是「突然自己停了」而没有任何解释；
- `activeVideoMinFrameDuration` 由本应用设置为目标帧率，因此上限何时生效可确定由应用选择的格式决定，不是随机现象。

定级依据：正常使用（默认 1080p 30 fps）下一般碰不到；选择 4K/60 fps 并拍摄较长素材时会稳定触发，且素材被提前截断而用户无从判断原因。触发后素材仍在、可重拍，有绕行方式（改用较低画质或分段拍），因此定为 P2 而不是 P1。未在真机实测，具体在几分钟处停止取决于设备与编码器，本清单不给出未经测量的分钟数。

**复现方法**

1. 在真机上进入取景页，右上角打开拍摄设置，选择「4K」+「60 fps」。
2. 连续拍摄一段超过 1 分钟的素材（具体时长取决于设备码率）。
3. 观察：录制会在远未到 10 分钟时自行停止并直接进入回看，界面没有任何关于上限的说明；「回看第 N 条」正常，素材可用。
4. 对照 code 位置确认该次停止来自 `maxRecordedFileSize`，而不是时长上限或中断。

**修复状态：** 待验证

**修复说明：**

根因有两处，均在 `ShotList/Camera/CameraRecorder.swift`：

1. `fileOutput(_:didFinishRecordingTo:from:error:)` 只按 `recordingSuccessfullyFinished` 分「成功／失败」两类，撞上限（`error` 非空但素材完好）与用户主动停止（`error` 为 nil）被合并成同一个 `.success(URL)`，界面因此拿不到「是不是撞了上限」的信息。
2. `configureIfNeeded` 把 `movieOutput.maxRecordedFileSize` 设成写死的 `600 * 1024 * 1024`，且只在初次配置时赋值一次，不随分辨率、帧率变化。

修复：

- 新增 `CameraRecorder.StopReason`（`userRequested` / `reachedLimit`）与 `RecordingOutput`（`url` + `stopReason`），`startRecording(completion:)` 的回调类型从 `Result<URL, Error>` 改为 `Result<RecordingOutput, Error>`。
- `fileOutput(...)` 判定成功后，新增 `stopReason(matching:)`：把 `error` 转成 `AVError`，`.maximumFileSizeReached` / `.maximumDurationReached` 记为 `.reachedLimit`，其余情况（`error` 为 nil，或虽非 nil 但不是这两种 code，例如中断、磁盘写满）一律记为 `.userRequested`——不会把「来电中断但素材完好」误报成「撞了上限」。
- `CameraCaptureView.toggleRecording()` 读取 `output.stopReason`；`.reachedLimit` 时置位新的 `@State reachedRecordingLimit`，驱动一条新增的短提示 alert「已达录制上限」／「这段已保存，可以回看或重拍。」，`enterReview(output.url)` 两种情况下都照常执行，视频本身不受影响。
- 新增 `CameraRecorder.updateMaximumFileSize()`，在 `applyFormatLocked(...)` 每次成功套用格式后调用（覆盖初次进相机、设置面板改分辨率/帧率、切前后摄像头三个入口）：读 `movieOutput.outputSettings(for:)` 里 `AVVideoCompressionPropertiesKey/AVVideoAverageBitRateKey`——这是 AVFoundation 针对当前 `activeFormat` 实际会用的平均码率，不是自己按宽高猜的——按「码率 × 10 分钟时长上限 × 1.15 余量」换算成字节数，与原来的固定 600 MB 取较大值写回 `maxRecordedFileSize`。取不到码率（连接不存在、`AVVideoAverageBitRateKey` 缺失或为 0）时退回固定 600 MB。用 `max(...)` 兜底确保低码率格式下限不变，只对高码率格式放宽。
- 顺带修正了同一根因下两处现在已经过期的说明文案：`ShotList/Views/CameraSettingsSheet.swift` 设置面板底部说明（原文断言「4K 或 60 fps 会更早碰到体积上限」，修复后不再准确），以及 `README.md` 两处（功能列表一行 + 「已知限制」段落，原文同样断言 600 MB 是固定值）。

**验证结果：**

- 构建：`xcodebuild -project ShotList.xcodeproj -scheme ShotList -destination 'generic/platform=iOS Simulator' -configuration Debug build` → `** BUILD SUCCEEDED **`；核对完整日志无新增警告，唯一出现的 `appintentsmetadataprocessor` 提示（"Metadata extraction skipped, no AppIntents.framework dependency found"）是本项目固有提示，与本次改动无关。
- 隔离的代码级验证：把 `fileOutput(...)` 与 `stopReason(matching:)` 的判定逻辑原样搬到仓库外的独立 Swift 脚本，用真实 `AVError`/`NSError`（`AVFoundationErrorDomain`）构造样本，`swift <script>.swift` 直接执行，覆盖 6 种分支：① 用户主动停止（`error` 为 nil）→ `success(userRequested)`；② 撞 `.maximumFileSizeReached` 且 `recordingSuccessfullyFinished=true` → `success(reachedLimit)`；③ 撞 `.maximumDurationReached` 且 `recordingSuccessfullyFinished=true` → `success(reachedLimit)`；④ 其他「素材完好」但不属于这两种 code 的错误（用 `.diskFull` 代表）→ `success(userRequested)`，确认不会被误判成撞上限；⑤ `recordingSuccessfullyFinished=false` → `failure`；⑥ `userInfo` 完全不带该 key → `failure`。6 项全部通过。验证后已删除该临时脚本，未写入任何单元测试文件、未纳入提交。
- 待验证（需要真机摄像头，本环境沙盒无真机、模拟器无摄像头，无法执行）：`updateMaximumFileSize()` 在真实设备上从 `outputSettings(for:)` 实际读到的 `AVVideoAverageBitRateKey` 数值是否符合预期量级；4K / 60 fps 实拍时体积上限是否确实不再远早于 10 分钟触发、具体在第几分钟触发；撞上限后回看页新增的「已达录制上限」提示的真实弹出时机、文案排版与交互手感；`updateMaximumFileSize()` 在 `switchCamera()` 路径下前后摄像头来回切换时的实际取值表现。

**修复 commit：** `bdbbba6d337055543dcc7aea6f355f880aaf7063`

**编号说明：** 本条原登记为 P2-34。同一编号同时被 main 上并行登记的「相册导入触发系统整段转码，导入耗时长且画质被降」占用——本条登记于 2026-09-16 00:47，该条登记于同日 00:56，本条在先，但 main 为主干且其条目已先行合入，故由本条让号，改编号为 P2-36（当时 P2 前缀最大序号 35 加一）。原编号 P2-34 不再复用。

<a id="p2-49"></a>

### P2-49 · 体积上限随画质放宽后磁盘可能被录满，而写满时仍然只是「自己停了」且没有任何说明

**验证状态：** 代码级确认（未做磁盘写满的故障注入实测）

**代码位置：** ShotList/Camera/CameraRecorder.swift · `updateMaximumFileSize()`（第 614–629 行）、`stopReason(matching:)`（第 1033–1041 行）、`configureIfNeeded`（第 690–694 行，未设置 `minFreeDiskSpaceLimit`）

**问题详情**

**预期行为：** 单条录制不会把设备磁盘录到写满；真的写满时，界面要像撞上限那样明确说明「为什么停了、这条保没保住」。

**实际行为：** [P2-36](#p2-36) 的修复把 `maxRecordedFileSize` 从固定 600 MB 改成按当前格式码率估算（`码率 ÷ 8 × 600 秒 × 1.15`，再与 600 MB 取 `max`）。这一步本身是对的——体积上限不该早于时长上限生效——但它同时拿掉了原先那道「单条最多 600 MB」的磁盘保险，而没有补上替代品：

1. `AVCaptureMovieFileOutput.minFreeDiskSpaceLimit` 全项目没有设置过（已全仓检索确认），所以录制不会在剩余空间见底前主动收尾；
2. 真的写满时，AVFoundation 返回 `AVError.diskFull` 并把 `recordingSuccessfullyFinished` 置为 true（素材完好）。`stopReason(matching:)` 只把 `.maximumFileSizeReached` / `.maximumDurationReached` 记为 `.reachedLimit`，`.diskFull` 落进 `default` 分支被记为 `.userRequested`，于是走静默成功路径：直接进回看，不弹任何提示。

**根因证据：**

- `CameraRecorder.swift:628` `movieOutput.maxRecordedFileSize = max(Int64(estimatedBytes), Self.maximumFileSize)`——高码率格式下这个值远大于 600 MB，实际约束退化为 10 分钟时长上限；
- `CameraRecorder.swift:1036-1039` `case .maximumFileSizeReached, .maximumDurationReached: return .reachedLimit` / `default: return .userRequested`；
- `grep -rn "minFreeDiskSpaceLimit" ShotList/` 无结果。

**影响范围与定级依据：** 这正是 P2-36 原本要解决的症状（「突然自己停了、没有解释」），只是触发原因换成了磁盘写满；而 P2-36 的修复让单条录制可以写到 GB 级，使写满这条路径**更容易**碰到而不是更难。素材本身完好、可回看可保存，不丢数据，用户清理空间后可继续拍，有绕行方式，因此定为 P2 而不是 P1。**未实测**：具体在剩余多少空间时触发、以及 `.diskFull` 在本项目配置下的确切返回形态没有做故障注入验证，本条目不给出未经测量的数值。

**复现方法**

1. 隔离测试环境：真机，先用无关的大文件把可用空间压到很小（不要删除用户真实素材）。
2. 进入任意镜头的取景页，在拍摄设置里选「4K」+「60 fps」。
3. 开始录制，持续拍到磁盘写满。
4. 观察：录制自行停止并直接进入回看，界面没有任何说明；对照 P2-36 修复后的行为，撞体积/时长上限会弹「已达录制上限」，而写满不会。
5. 预期正确结果：要么在剩余空间见底前主动收尾并说明原因，要么在 `.diskFull` 路径上同样给出提示。
6. 验证完成后清理测试用的占位文件。

**修复状态：** 待验证

**修复说明：** 根因两处，均在 `ShotList/Camera/CameraRecorder.swift`：`movieOutput` 没有设 `minFreeDiskSpaceLimit`，而 P2-36 放宽 `maxRecordedFileSize` 之后它不再是磁盘的保险；`stopReason(matching:)` 把 `.diskFull` 落进 `default` 记成 `.userRequested`，走静默成功路径。

修复：

- 新增 `minimumFreeDiskSpace`（500 MB），在 `configureIfNeeded` 里与 `maxRecordedDuration` / `maxRecordedFileSize` 同处赋给 `movieOutput.minFreeDiskSpaceLimit`：剩余空间低于它时 AVFoundation 主动收尾，留出空间给 `films.json` 与系统。
- `StopReason` 新增 `.diskFull`，`stopReason(matching:)` 把 `AVError.diskFull` 归到它；其余 code 仍归 `.userRequested`，不误报。
- `CameraCaptureView` 把原来的「已达录制上限」提示与新增的「存储空间不足」（正文「已停止录制。请释放空间后再拍。」）合并成一个由 `RecordingNotice` 驱动的说明弹层，避免同一视图上叠第三个 `.alert`；照常进入回看，素材不受影响。

**验证结果：**

- 构建：Xcode 27.0，iPhone 17 Pro / iOS 26.5 模拟器，Debug 构建成功、无新增告警；既有 107 项测试全部通过。
- 隔离的代码级验证：把 `stopReason(matching:)` 的判定原样搬到仓库外的独立 Swift 脚本，用真实 `AVError` 构造样本，`nil` → `userRequested`、`.maximumFileSizeReached` / `.maximumDurationReached` → `reachedLimit`、`.diskFull` → `diskFull`、其他 `AVError` 与非 `AVError` → `userRequested`，6 项全部通过；验证后已删除脚本，未纳入提交。
- 界面：模拟器没有摄像头，用临时探针（启动参数直接触发，验证后已移除）分别弹出两种说明：「存储空间不足 / 已停止录制。请释放空间后再拍。」与只有标题的「已达录制上限」，版式与「好」按钮正常。
- 待验证（需要真机摄像头，无法在模拟器执行）：`minFreeDiskSpaceLimit` 在真实设备上收尾时返回的确切 error（预期为 `AVError.diskFull` 且 `recordingSuccessfullyFinished` 为 true）；把可用空间压到 500 MB 以下后录制的实际停止时机；500 MB 这个预留量是否合适；停止后回看页说明弹层的真实弹出时机。

**修复 commit：** `85382798cbe75097d734c8c950678d84124a2fab`

**来源：** 审查 [P2-36](#p2-36) 的修复实现时发现，属于独立根因（磁盘保险缺失 + `.diskFull` 未被识别），按 AGENTS.md 单独编号，不并入 P2-36 条目。

<a id="p2-50"></a>

### P2-50 · 录制失败时残缺的临时视频不会被删除，一直占着磁盘到下次启动

**验证状态：** 代码级确认（未在真机实测触发）

**代码位置：** ShotList/Camera/CameraRecorder.swift · `fileOutput(_:didFinishRecordingTo:from:error:)`；ShotList/Views/CameraCaptureView.swift · `toggleRecording()` 的 `.failure` 分支

**问题详情**

**预期行为：** 录制没有成功结束时，AVFoundation 已经写到临时目录里的 `shot-*.mov` 是残缺的，没有任何路径会再用它，应当随失败一起删掉。

**实际行为：** `didFinishRecordingTo` 在 `error != nil` 且 `recordingSuccessfullyFinished == false` 时只把 `.failure(error)` 交给回调；回调里没有 `outputFileURL`，界面也只弹「录制失败」，没有人删这个文件。只有「没人等这条视频」（相机已关）与「重拍 / 关页面」两条路径会删临时文件，失败路径漏了。残缺文件要等到下次启动时 `cleanUpTemporaryRecordings()` 统一回收。

**根因证据：** `CameraRecorder.swift` 的 `didFinishRecordingTo`：`.failure` 分支不删 `outputFileURL`；`CameraCaptureView.toggleRecording()` 的 `.failure` 只置 `errorMessage`。

**影响范围与定级依据：** 残缺文件的大小取决于失败前已经写出多少（高码率下可达 GB 级）；触发失败的常见原因之一就是磁盘写满（见 [P2-49](#p2-49)），此时留着它会让本来就紧张的空间更紧张，直到用户重启应用才回收。不丢用户数据，有绕行方式（重启应用），因此定为 P2。未实测：真机上失败时文件是否一定存在、大小多少，本条目不给未经测量的数值。

**复现方法**

1. 隔离测试环境：真机，用无关的大文件把可用空间压到很小（不要删除用户真实素材），拍摄设置选「4K」+「60 fps」。
2. 进入任意镜头的取景页开始录制，一直录到因写入失败而停止并弹出「录制失败」。
3. 观察：用「文件」App 或调试命令查看应用临时目录，`shot-*.mov` 仍在；退出并重新启动应用后才被清掉。
4. 预期正确结果：弹出「录制失败」的同时，这个残缺文件已被删除。
5. 验证完成后清理测试用的占位文件。

**修复状态：** 待验证

**修复说明：** 根因是失败路径漏了临时文件回收。修复：`didFinishRecordingTo` 回到主线程后，若结果是 `.failure` 就删除 `outputFileURL`，再走原有的「没人等这条视频就删掉」判断与回调；成功与撞上限的路径不变，文件照常交给回看。

**验证结果：** Xcode 27.0 构建成功、无新增告警，既有 107 项测试全部通过。改动落在真机录制回调上，模拟器没有摄像头，无法触发录制失败，故只做代码级确认。待验证（真机）：按复现方法把可用空间压到很小后录制到失败，确认弹出「录制失败」时临时目录里的 `shot-*.mov` 已被删除；正常录制并保存、撞上限、点「重拍」三条路径的文件处理不受影响。

**修复 commit：** `eafafc99176dff36f10b21fba524b677b3b13274`

**来源：** 复查 P2-36 / P2-49 相关的录制收尾回调时发现，属于独立根因（失败路径漏了临时文件回收），按 AGENTS.md 单独编号。
