# 分镜助手 · ShotList

一个纯本地单机的 iOS 应用，用来在拍 Vlog 之前把分镜列清楚、拍的时候逐个打勾、拍完统一导出。

- **平台**：iOS 17.0+（原生 SwiftUI，iPhone 竖屏）
- **网络**：零网络请求。所有分镜数据与视频只保存在这台设备上
- **界面语言**：简体中文
- **包标识**：`com.max.ShotList`

---

## 功能

### 1. 录入编号 1、2、3… 的镜头分镜
「分镜」标签页支持逐个添加镜头，也可以一次批量添加 3 / 5 / 10 个空白镜头再逐条补标题。
镜头按拍摄顺序连续编号，拖动排序后编号会自动重排；在编辑页直接改编号，镜头会被移动到对应位置。

### 2. 分镜即「可点击添加视频的模块」
列表里每一张卡片就是一个视频模块：

- 还没有视频时显示虚线框 + 加号，并提示「点击拍摄或导入视频」
- 已经有视频时显示视频首帧缩略图、播放标识、时长与拍摄时间
- 点击卡片弹出操作面板：用相机拍摄 / 从相册导入 / 播放 / 分享 / 编辑 / 删除

### 3. 今日拍摄状态一目了然
「今日」标签页给出日期、环形进度、三个可点击的统计块（今日已拍 / 往日已拍 / 还没拍），
以及按状态筛选的镜头列表。点任意一张卡片就能直接补拍。
状态的表达始终是「图标 + 文字 + 颜色」三重信息，不依赖颜色单独区分。

### 4. 应用内直接调用原生摄像
点卡片 → 拍摄，即可在当前分镜里直接录像（AVFoundation）：

- 先给出自定义权限说明，再触发系统权限弹窗；权限被拒时引导到「设置」
- 支持前后摄像头切换、补光、录制计时
- 录完先回看，可以选择「重拍」或「使用这条」
- 来电、切后台等中断会先把已拍的片段保存下来
- 单条镜头最长 10 分钟、最大 600 MB

### 5. 统一管理 + 统一导出
「导出」标签页把所有镜头打包成一个 zip：

```
分镜导出_20260914/
├── 01_开场-城市天际线.mov
├── 02_街景横摇.mov
├── 03_咖啡店特写.mov
├── 分镜清单.csv      （带 UTF-8 BOM，Excel / Numbers 直接打开不乱码）
└── 导出说明.txt
```

视频以编号为前缀命名，导入剪映后素材顺序与分镜顺序一致。三条导出通道：

| 目标 | 方式 |
|---|---|
| 剪映 | 分享面板里直接选「剪映」 |
| 电脑 | 分享面板选「存储到文件」，或隔空投送到 Mac |
| 数据线 | 应用已开启文件共享，接上数据线后在「文件」App / 访达里直接取用 |

也可以「单独分享某一段」，或长按卡片分享单个视频。

---

## 运行

### 直接打开（推荐）

```bash
open ShotList.xcodeproj
```

选好模拟器或真机，`⌘R` 运行。命令行构建：

```bash
xcodebuild -project ShotList.xcodeproj -scheme ShotList \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build
```

### 修改工程结构后重新生成

工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `project.yml` 生成。
仓库里同时提交了生成好的 `ShotList.xcodeproj`，方便直接打开；如果改了 `project.yml`
或增删了源文件目录，需要重新生成：

```bash
brew install xcodegen
xcodegen generate
```

### 关于摄像头

**iOS 模拟器不提供摄像头。** 在模拟器里进入拍摄界面时，应用会明确提示
「这台设备没有可用的摄像头」，并给出「从相册导入」的替代路径，不会崩溃或卡死。
完整的拍摄链路需要在真机上验证。

---

## 目录结构

```
ShotList/
├── App/
│   └── ShotListApp.swift            应用入口，注入数据仓库与区域设置
├── Models/
│   ├── Shot.swift                   分镜模型、拍摄状态、无障碍描述
│   └── ShotStore.swift              数据仓库：JSON 持久化 + 视频文件管理
├── Camera/
│   ├── CameraRecorder.swift         AVFoundation 会话、录制、前后摄、补光、中断处理
│   └── CameraPreview.swift          预览层桥接到 SwiftUI
├── Views/
│   ├── RootTabView.swift            分镜 / 今日 / 导出 三标签
│   ├── ShotListView.swift           分镜清单
│   ├── ShotCardView.swift           可点击添加视频的模块卡片
│   ├── ShotEditorView.swift         编辑镜头信息
│   ├── ShotFlowModifier.swift       拍摄 / 导入 / 播放 / 编辑的统一弹层流程
│   ├── ClipOptionsSheet.swift       卡片操作面板
│   ├── ClipThumbnailView.swift      视频首帧缩略图
│   ├── CameraCaptureView.swift      应用内相机（含权限说明与降级路径）
│   ├── ClipPlayerScreen.swift       整屏播放
│   ├── TodayView.swift              今日拍摄状态
│   └── ExportView.swift             统一导出
├── Support/
│   ├── DesignSystem.swift           间距、尺寸、状态徽标、进度环等基础组件
│   ├── AppLocale.swift              格式化区域固定为简体中文
│   ├── ExportPackageBuilder.swift   打包 zip、分镜清单、导出说明
│   ├── Haptics.swift                触觉反馈、视频元数据、缩略图缓存
│   └── MediaImport.swift            相册导入的 Transferable 实现
└── Resources/
    └── Assets.xcassets              应用图标与强调色（含深色变体）

Tools/
├── generate-icon.swift              用 CoreGraphics 生成 1024×1024 应用图标
└── seed-simulator.py                开发辅助：往模拟器里灌演示数据

project.yml                          XcodeGen 工程定义（权限键、部署目标等）
```

---

## 数据存放位置

| 内容 | 位置 |
|---|---|
| 分镜元数据 | `Application Support/ShotList/shots.json` |
| 分镜视频 | `Documents/分镜视频/` |
| 导出压缩包 | 临时目录，分享完即可丢弃 |

`Documents` 目录已通过 `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`
对「文件」App 和访达开放，因此视频不需要额外导出就能取到电脑。

---

## Apple 开发标准与无障碍

- **导航**：`TabView` 三个顶层标签，无抽屉菜单；`NavigationStack` 层级导航；不覆盖系统返回手势
- **触控**：所有可点元素不小于 44×44pt；间距遵循 8pt 网格（4pt 仅用于细调）
- **排版**：全部使用语义化文字样式，支持 Dynamic Type；无障碍字号下卡片自动改为上下布局
- **颜色**：全部使用语义色与系统色；自定义强调色在资源目录里提供了深色变体
- **无障碍**：交互元素均有 `accessibilityLabel` / `accessibilityHint`；
  卡片会一次朗读「镜头编号 + 标题 + 状态 + 时长 + 可执行动作」；
  进度环、录制计时等有独立的无障碍值；状态不依赖颜色单独传达
- **减弱动态效果**：卡片按压缩放、进度环动画、录制红点闪烁在开启后全部关闭
- **权限**：在用户点开相机时才申请，且先给出自定义说明；被拒后引导至「设置」
- **模态**：不使用叠层模态，切换弹层时先关闭当前弹层再呈现下一个；弹层均提供关闭路径
- **提示与反馈**：删除分镜、删除视频使用 `confirmationDialog` / `alert` 二次确认并标红；
  关键操作配合触觉反馈；导入过程用轻量胶囊提示，不用全屏 spinner
- **生命周期**：录制中切后台或来电会先保存已拍片段

---

## 已知限制

- 仅支持 iPhone 竖屏。这是相机类应用的刻意取舍，避免上下颠倒的录制结果
- 视频编码使用系统默认的 H.264，未提供码率 / 分辨率选项
- 导出包生成在临时目录，系统回收后需要重新生成
