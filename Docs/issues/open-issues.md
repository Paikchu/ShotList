# 分镜助手 · 未关闭问题

更新日期：2026-09-21。共 **6 项未修复**：**P0 0 项、P1 0 项、P2 6 项**。保留原问题编号，按优先级及编号排序。

未修复问题保留在优先级分组；完成项移至 [resolved-issues](resolved-issues.md)，保留验证和修复提交以便追溯。复现状态沿用已有审查证据；涉及文件破坏或故障注入的步骤使用隔离测试数据。

## 汇总 Checklist

| 完成 | 编号 | 问题标题 |
|:--:|---|---|
| ☐ | P2-52 | [片段文件已不在磁盘上时点播放，进入一块没有任何出口的黑屏，只能强杀应用](#p2-52) |
| ☐ | P2-53 | [应用内没有任何删除整部影片的入口，影片记录只增不减](#p2-53) |
| ☐ | P2-54 | [会话侧拒绝开始录制时，录制按钮只是闪一下又复原，不回调也不提示](#p2-54) |
| ☐ | P2-55 | [快速拍摄在相机页改走「导入」后取消选片，新建的空镜头不会被撤销](#p2-55) |
| ☐ | P2-56 | [批量添加入口移除后，ShotStore.addShots(count:) 只剩测试在调用](#p2-56) |
| ☐ | P2-57 | [首次进相机时体积上限可能仍停在 600 MB，P2-36 的按码率放宽只在改过画质或切过摄像头之后才生效](#p2-57) |

☐ 未修复；☑ 修复并验证通过。

## P0

暂无未修复问题。

## P1

暂无未修复问题。

## P2

<a id="p2-52"></a>

### P2-52 · 片段文件已不在磁盘上时点播放，进入一块没有任何出口的黑屏，只能强杀应用

**验证状态：** 代码级确认（未在模拟器构造记录与文件不一致的状态实测）

**代码位置：** ShotList/Views/ShotFlowModifier.swift · `fullScreenCover` 的 `.player` 分支（第 107–117 行，第 116 行 `Color.black.ignoresSafeArea()`）；ShotList/Views/ClipPlayerScreen.swift（关闭按钮只在这里面）；ShotList/Views/ClipOptionsSheet.swift · `clipRow`（第 298 行起，片段行的播放按钮）

**问题详情**

**预期行为：** 要播放的片段文件不存在时，要么不进入播放页，要么进入后能看到原因并关掉。

**实际行为：** `.player` 分支在 `store.clipURL(for: clip)` 为 nil 时渲染 `Color.black.ignoresSafeArea()`。关闭按钮（`xmark`）写在 `ClipPlayerScreen` 里面，这个 else 分支里**一个可点的元素都没有**；而 `fullScreenCover` 不支持下滑关闭。用户看到的是一整屏黑色，点哪里都没有反应，只能从多任务界面强杀应用。

**根因证据：**

- `ShotFlowModifier.swift:108-117`：`if let url = store.clipURL(for: clip) { ClipPlayerScreen(...) } else { Color.black.ignoresSafeArea() }`，else 分支没有任何按钮或 `dismiss`；
- `ClipPlayerScreen.swift:14/32/34`：`@Environment(\.dismiss)` 与关闭按钮只存在于正常分支的视图里；
- `store.clipURL(for:)` 只认 `existingClipFileNames` 缓存，文件不在时返回 nil；而 `ClipOptionsSheet.clipRow` 按 `live.clips`（JSON 记录）逐条画行，记录在、文件不在时这一行照样可点（缩略图此时已显示 `video.slash`）。

**影响范围与定级依据：** 前提是「JSON 里还有记录、文件已经不在磁盘上」——`reconcileClipsWithDisk` 每次切回前台都会清理这类记录，所以触发窗口窄；但一旦触发，界面完全卡死、没有任何出口，属于局部场景下的严重交互异常。不丢数据、重启后恢复，定为 P2。**未实测**：没有在模拟器上构造这一状态验证实际表现。

**复现方法**

1. 隔离测试数据：模拟器上准备一部测试影片，给某个镜头导入一段视频（不要使用用户真实素材）。
2. 代码级验证：在 `ShotFlowModifier` 的 `.player` 分支临时加探针，强制让 `store.clipURL(for: clip)` 返回 nil（或在应用运行期间从模拟器容器里删除该片段文件，并阻止 `refreshStorageStats()` 在此之前运行）。
3. 打开该镜头的面板，点「片段」里那一条的播放。
4. 观察：进入整屏黑色，没有关闭按钮，下滑无效。预期正确结果：不进入播放页并提示文件不存在，或播放页给出说明与关闭按钮。
5. 验证完成后移除探针与隔离数据。

**修复状态：** 未修复

**修复说明：** 待修复；建议在呈现前判断——`onPlay` 排队 `.player` 之前先确认 `store.clipURL(for:)` 非空，不存在就不进播放页并提示；else 分支本身也补一个关闭按钮作为兜底，免得以后别的路径再掉进来。

**验证结果：** 待验证；本轮仅做代码级确认。

**修复 commit：** 待提交；完成后填写实际修复提交的完整 SHA。

<a id="p2-53"></a>

### P2-53 · 应用内没有任何删除整部影片的入口，影片记录只增不减

**验证状态：** 代码级确认（全仓检索调用点）

**代码位置：** ShotList/Models/ShotStore.swift · `deleteFilm(_:)`（第 374 行）、`deleteCurrentFilm()`（第 384 行）、`discardBlankFilm(_:)`（第 394 行）；ShotList/Views/FilmBar.swift · `dropdownPanel` / `FilmSwitcherMenu`（影片列表与影片菜单）；ShotList/Views/ExportView.swift（原入口所在，已移除）

**问题详情**

**预期行为：** 用户能删除一部不再需要的影片（连同它的镜头与素材）。

**实际行为：** `deleteFilm` / `deleteCurrentFilm` 在生产代码里**零调用点**，只有 `ShotListTests` 在调。原先唯一的入口是导出页的「删除影片」，已在 [R-8](../requirements/delivered-requirements.md#r-8)（`0b3572a feat(R-8): 导出页精简…`，2026-09-20）中按需求移除；R-8 交付记录的「遗留」一栏写明「应用内不再有删除整部影片的入口，影片库只增不减；该入口放到哪里需要用户另行决定」。此后影片条下拉面板（重命名 / 新建影片）、分镜页影片菜单（重命名 / 模板 / 剪辑风格 / 新建影片）与影片列表行都没有补上删除入口，也没有滑动删除或长按菜单。这项遗留只记在已交付需求的备注里，不在任何未关闭清单上，因此在此登记跟踪。

**根因证据：**

- `grep -rn "\.deleteFilm\|\.deleteCurrentFilm" ShotList ShotListWidget` 无结果；
- `grep -n "swipeActions\|contextMenu\|role: .destructive\|删除" ShotList/Views/FilmBar.swift ShotList/Views/HistoryView.swift` 无结果；
- `discardBlankFilm` 只会在切换影片 / 新建影片时静默回收**完全空白**的影片（`Film.isBlank`：无镜头、无标题、无剪辑风格、无模板），写过任何一样的影片永远不会被回收。

**影响范围与定级依据：** 素材占用的磁盘**可以**回收——逐个删除镜头或清空片段即可，`commit()` 会删掉不再被引用的文件；删不掉的是影片记录本身。影片下拉面板与影片菜单会随使用一直变长。唯一的绕行方式是把该影片的所有镜头、标题、剪辑风格和模板逐项清空，再切换影片触发静默回收，不可发现且要求用户先亲手删掉自己写的内容。拍摄到导出的主路径不受影响，定为 P2。修复需要先由用户决定入口放在哪里（R-8 遗留的未决问题）。

**复现方法**

1. 模拟器安装 Debug 构建，新建两部影片并各起一个标题。
2. 依次检查：分镜页右上角影片菜单、历史页影片条下拉面板中的每一行（尝试左滑、长按）、导出页。
3. 观察：任何位置都没有删除影片的操作。
4. 预期正确结果：至少有一处可以删除当前影片（或指定影片），并有确认弹层说明镜头与素材会一起删除。

**修复状态：** 未修复

**修复说明：** 待修复；需先确定入口位置（候选：影片菜单末尾的破坏性项、影片列表行的左滑删除）。`ShotStore.deleteFilm` 已有完整实现与测试（含删除补偿日志），只需要接一个入口与确认弹层；删除后若库空了会由 `ensureFilmExists()` 补一部空白影片。

**验证结果：** 待验证；本轮为代码级确认与全仓检索。

**修复 commit：** 待提交；完成后填写实际修复提交的完整 SHA。

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

**修复状态：** 未修复

**修复说明：** 待修复；失败分支应调用 `handler(.failure(...))`（或新增一个「未能开始」的结果），由 `CameraCaptureView` 按现有的错误提示通道展示；也可在 `movieOutput` 收尾期间把录制按钮置为不可用，从源头避免乐观置位后再回滚。改动落在真机录制路径上，需真机验证。

**验证结果：** 待验证；本轮仅做代码级确认。

**修复 commit：** 待提交；完成后填写实际修复提交的完整 SHA。

<a id="p2-55"></a>

### P2-55 · 快速拍摄在相机页改走「导入」后取消选片，新建的空镜头不会被撤销

**验证状态：** 代码级确认（未在模拟器实测）

**代码位置：** ShotList/Views/ShotFlowModifier.swift · `drainQueue()`（第 221–239 行，第 231 行 `quickShotID = nil`）、`.onChange(of: pickerItems)`（第 141–150 行）、`finishQuickShoot()`（第 253–263 行）；ShotList/Views/CameraCaptureView.swift · `requestImport()`（第 519 行）及其入口（第 376、392、403 行）

**问题详情**

**预期行为：** 快速拍摄会先新建一个空镜头再开相机；用户最终没有拍到、也没有导入任何片段就离开时，这个空镜头应被撤销（`finishQuickShoot` 的注释：「点了快速拍摄又退出」是取消，不该在列表末尾留一个没人要的空镜头）。

**实际行为：** 在相机页点「导入」时，`drainQueue()` 走 `queuedImportShot` 分支，把「是否接着开描述页」记进 `pickerOpensDescription` 后**立刻清空 `quickShotID`**，收尾改由导入完成后接管。但用户若在系统选片器里点取消，`pickerItems` 保持为空，`.onChange(of: pickerItems)` 的 `guard !newValue.isEmpty` 直接返回，导入流程从未开始；`quickShotID` 又已经是 nil，`finishQuickShoot()` 永远不会撤销这个镜头。结果列表末尾多出一个没有内容、没有片段的镜头。

**根因证据：** `ShotFlowModifier.swift:230-231` 在选片器呈现**之前**就清空了 `quickShotID`；选片被取消这条路径上没有任何回调去补做 `finishQuickShoot()` 的撤销逻辑。

**影响范围与定级依据：** 相机页的「导入」按钮出现在未授权摄像头、首次请求权限、相机不可用三种页面上（`CameraCaptureView.swift:376/392/403`），模拟器没有摄像头，走的正是「相机不可用 → 导入」这条路，因此在模拟器上可稳定触发。后果是列表里多一个空镜头，用户可以手动删除，定为 P2。**未实测**。

**复现方法**

1. 在模拟器上（没有摄像头）打开分镜页，长按右上角加号，点「快速拍摄」。
2. 相机页显示「相机不可用」，点「导入」。
3. 在系统选片器里点取消。
4. 观察分镜列表末尾：多出一个空镜头。预期正确结果：列表恢复到快速拍摄之前的样子。

**修复状态：** 未修复

**修复说明：** 待修复；把 `quickShotID` 的清空推迟到导入真正开始（`onChange(of: pickerItems)` 拿到非空选择）时，并在选片器关闭且未选择任何内容时（`isPickerPresented` 变回 false 而 `pickerItems` 仍为空）调用 `finishQuickShoot()` 做撤销。

**验证结果：** 待验证；本轮仅做代码级确认。

**修复 commit：** 待提交；完成后填写实际修复提交的完整 SHA。

<a id="p2-56"></a>

### P2-56 · 批量添加入口移除后，ShotStore.addShots(count:) 只剩测试在调用

**验证状态：** 代码级确认（全仓检索调用点）

**代码位置：** ShotList/Models/ShotStore.swift · `addShots(count:)`（第 427 行）；ShotListTests/ShotStoreTests.swift（第 51、183 行）

**问题详情**

**预期行为：** 生产代码里的公开写入接口都有实际调用方；需求删除一个功能时，相应的接口一并移除。

**实际行为：** [R-11](../requirements/delivered-requirements.md#r-11)（`772ea00 feat(R-11): 长按加号去掉批量添加，只保留「快速拍摄」`，2026-09-20）按需求移除了「一次添加 3 / 5 / 10 个镜头」，但 `ShotStore.addShots(count:)` 保留了下来。现在它在生产代码中零调用点，只有 `ShotStoreTests` 的两处断言在用。

**根因证据：** `grep -rn "\.addShots" ShotList ShotListWidget` 无结果；`grep -rn "addShots" ShotListTests` 命中第 51、183 行。

**影响范围与维护成本：** 不影响任何用户可见行为。代价是 `ShotStore` 保留一条没有入口的写路径：它和 `addShot` / `insertShot` 走同一套 `normalize()` + `persist()`，今后改动编号或文件名规则时仍需同步维护它和它的测试，而它已经不对应任何功能。定为 P2（有明确维护成本的无用代码）。

**复现方法**

1. 在仓库根目录执行 `grep -rn "\.addShots" ShotList ShotListWidget`，确认无结果。
2. 执行 `grep -rn "addShots" ShotListTests`，确认只剩测试调用。
3. 预期正确结果：功能移除后接口与其测试一并删除，或该接口重新有调用方。

**修复状态：** 未修复

**修复说明：** 待修复；删除 `addShots(count:)` 与 `ShotStoreTests` 中对应的两处断言。两处分别测的是「读不出记录（`loadError`）」与「写盘失败（`saveError`）」时写入被拦截；同一块里紧挨着的 `XCTAssertNil(…addShot())`（第 50、182 行）已覆盖同类拦截，删除后覆盖不减。

**验证结果：** 待验证；本轮为全仓检索确认。

**修复 commit：** 待提交；完成后填写实际修复提交的完整 SHA。

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

**修复状态：** 未修复

**修复说明：** 待修复；最小改法是把首次配置路径上的 `updateMaximumFileSize()` 挪到外层 `commitConfiguration()` 之后（例如 `configureIfNeeded` 返回成功后、`start()` 里 `startRunning()` 之前再调一次），让它读到已提交的格式；`applyFormatLocked` 内部那次调用保留给单独改画质的路径。

**验证结果：** 待验证；需真机按上面的探针步骤确认推断是否成立，再决定是否修复。

**修复 commit：** 待提交；完成后填写实际修复提交的完整 SHA。
