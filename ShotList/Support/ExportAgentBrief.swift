import Foundation

/// 导出包里的 `AGENTS.md`：交给 AI 剪辑工具的粗剪任务说明。
///
/// 为什么要有这份文件：包里原本只有「逐镜内容」和「用户的剪辑要求」，没有流程、交付物与验收标准，
/// 也没有素材的实测参数，agent 只能靠用户一步步口头引导。说明跟着包走，换 agent、换电脑都能用。
///
/// 正文分两部分：通用的流程与规则是固定文字；第 4 节「本包素材情况」按实际素材生成，
/// **只列本包真的存在的情况**——列一条包里没有的坑，等于让剪辑侧去处理不存在的问题。
///
/// 正文的依据与试剪结果见 `Docs/export/粗剪任务说明模板.md`、`Docs/export/试剪记录-9.18Vlog.md`。
nonisolated enum ExportAgentBrief {

    /// Claude Code 2.1.277 起才会在没有 CLAUDE.md 时读 AGENTS.md，更早的版本只读 CLAUDE.md，
    /// 所以再放一个只做引入的 CLAUDE.md，两种版本都能自动带上任务说明。
    static let claudeImport = "@AGENTS.md\n"

    static func markdown(manifest: ExportManifest, filmDisplayTitle: String, sourceBytes: Int64) -> String {
        let film = manifest.film
        let styleLine = film.hasStylePrompt
            ? "`剪辑风格.md`：用户对整部片的要求（画幅、总长、单镜时长、声音、文字、片尾）。它优先于本文件的默认做法。"
            : "本片没有 `剪辑风格.md`，用户没有特别要求，画幅、节奏、文字样式全部按本文件的默认做法，并在报告里写明。"

        return ([
            head(filmDisplayTitle),
            read(styleLine: styleLine),
            limits(sourceBytes: sourceBytes),
            deliverables(filmTitle: filmDisplayTitle, labels: film.labels),
            facts(manifest),
            workflow,
            formats,
            acceptance,
            report,
            rerun
        ] as [String]).joined(separator: "\n")
    }

    // MARK: - 固定部分

    private static func head(_ title: String) -> String {
        """
        # 粗剪任务 · \(title)

        本目录是「分镜助手」导出的一部影片：拍好的素材、每个镜头要上屏的文字、用户写的剪辑要求。
        你的任务：独立完成粗剪，交付成片和可以继续精修的中间工程文件。

        - 全程不要向用户提问。遇到取舍按本文件处理，把决定和理由写进 `输出/剪辑报告.md`。
        - 用户在对话里给你的明确指令，优先于本文件。

        """
    }

    private static func read(styleLine: String) -> String {
        """
        ## 1. 先读

        1. \(styleLine)
        2. `manifest.json`：每个镜头的内容原文（`note`）和每条素材的实测参数。上屏文字、时长、尺寸、帧率、HDR、音轨一律以它为准。
        3. 本文件第 4 节：这一包素材的特殊情况。

        `分镜文字内容指南.md`、`分镜清单.csv`、`导出说明.txt` 是给人看的；和本文件或 `manifest.json` 不一致时，以本文件和 `manifest.json` 为准。

        """
    }

    private static func limits(sourceBytes: Int64) -> String {
        """
        ## 2. 边界

        - 只在 `输出/` 里写文件。不修改、不移动、不重命名本目录里的原文件。
        - 不从网络下载素材、音乐、字体。字体用本机已有的中文字体（macOS 上用 PingFang SC）。
        - Python 依赖装进 `输出/.venv`，不安装系统级软件。缺工具时按 5.0 降级，并在报告里写明缺什么、怎么装。
        - 开始前确认磁盘空间不少于素材总大小（\(sourceBytes.slByteText)）加 1 GB；中间临时文件用完即删。

        """
    }

    private static func deliverables(filmTitle: String, labels: [String]) -> String {
        let subtitleLines = labels.isEmpty
            ? ["│   ├── 上屏文字.srt         每类上屏文字一份，可直接导入剪映"]
            : labels.map { "│   ├── \($0).srt" }
        let name = filmTitle.replacingOccurrences(of: " ", with: "")

        return """
        ## 3. 交付物

        ```
        输出/
        ├── 成片.mp4
        ├── 剪辑决策.json          每镜用哪条素材、入出点、在成片里的位置、上屏文字与时间
        ├── 样式.json              从剪辑要求换算出的具体数值
        ├── 剪辑报告.md
        ├── 片段/                  按成片顺序裁好的每一镜，不带文字：01.mp4、02.mp4…
        ├── 字幕/
        │   ├── 字幕.ass           全部上屏文字（含片尾），带样式与位置，成片烧录用它
        \(subtitleLines.joined(separator: "\n"))
        │   └── 片尾.srt           有片尾卡时才有
        ├── 音频/
        │   └── 成片混音.wav        48 kHz、24-bit、立体声，与成片音轨一致
        ├── 工程/
        │   ├── \(name).fcpxml     Final Cut Pro、DaVinci Resolve
        │   ├── \(name).otio       OpenTimelineIO，DaVinci Resolve 可直接导入
        │   ├── \(name).edl        CMX 3600，只含剪切点
        │   └── 剪映草稿/           可选，见 5.8
        └── 中间/
            ├── 素材检查.md
            ├── 归一化/            统一格式后的整条素材；片段、成片、工程文件都从这里取
            ├── 联系表/            选段时看的缩略图拼图
            └── 抽检/              验收用的成片抽帧
        ```

        **唯一来源：** 成片、片段、字幕、音频、工程文件里的每个时间点，都由 `剪辑决策.json` 和 `样式.json` 生成。要改剪辑，先改这两个文件，再全部重新生成，不要单独改某个产物。

        """
    }

    private static let workflow = """
    ## 5. 流程

    ### 5.0 环境

    1. 烧录文字需要 ffmpeg 带 libass：`ffmpeg -hide_banner -filters | grep -E ' (ass|subtitles) '` 有输出才行。Homebrew 默认的 `ffmpeg` 不带，改用 `$(brew --prefix ffmpeg-full)/bin/ffmpeg`。都没有时，成片不烧文字，文字只交付在 `字幕/` 里，报告写明。
    2. HDR 转 SDR 用 macOS 自带的 `avconvert`。不在 macOS 上时改用 ffmpeg 的 `zscale` + `tonemap`。
    3. 可以用 `h264_videotoolbox` 硬件编码提速。
    4. 往 `输出/.venv` 装 `opentimelineio`；读回核对 EDL、FCPXML 时再装 `otio-cmx3600-adapter`、`otio-fcpx-xml-adapter`。

    ### 5.1 核对素材

    对每条要用的素材跑 ffprobe，核对时长、显示尺寸、帧率、HDR、音轨，写进 `中间/素材检查.md`。和 `manifest.json` 不一致时以实测为准，并在报告里记下。

    ### 5.2 定画布

    画布尺寸和帧率按用户的剪辑要求。没写，或写了「原分辨率」但素材分辨率不一致时：尺寸取素材里最多的那种（按显示方向），帧率取 30 fps。写进 `样式.json` 和报告。

    ### 5.3 统一格式

    每条要用的素材整条转成统一格式，存为 `中间/归一化/<原文件名>`：

    - SDR BT.709、8-bit 4:2:0、恒定帧率（等于画布帧率）、尺寸等于画布（等比缩放后居中裁切，不加黑边）、不带旋转元数据；
    - AAC 48 kHz 立体声，取原文件里 `preferredAudioIndex` 那条音轨（iPhone 为兼容专门写的立体声轨）；单声道复制成两声道。没有可用的 AAC 轨时，用 avconvert 输出里的音频降成立体声，并写进报告。

    ```bash
    # HDR 素材：用系统转换拿到 SDR 画面，同时摆正方向（画布 1080×1920 时换成 Preset1920x1080）
    avconvert -s <原文件> -p Preset3840x2160 -o 中间/归一化/tmp-<名>.mov --replace
    # 统一帧率、尺寸、音频：画面来自上一步，音频来自原文件；完成后删掉 tmp 文件
    ffmpeg -i 中间/归一化/tmp-<名>.mov -i <原文件> -map 0:v:0 -map 1:a:<preferredAudioIndex> \\
      -vf "fps=30,scale=2160:3840:force_original_aspect_ratio=increase,crop=2160:3840,setsar=1,format=yuv420p" \\
      -c:v h264_videotoolbox -b:v 40M -color_primaries bt709 -color_trc bt709 -colorspace bt709 \\
      -c:a aac -ac 2 -ar 48000 中间/归一化/<名>.mov
    # SDR 素材：跳过 avconvert，第二条命令只输入原文件，用 -map 0:v:0 -map 0:a:<preferredAudioIndex>
    ```

    不要直接用 ffmpeg 解 HDR 原片来做成片：不做色调映射，画面会发灰。

    ### 5.4 选条与入出点

    1. 每个已拍镜头默认用主素材（根目录里的那条）。主素材明显不能用（糊、被挡、没拍到内容里说的东西），且备用片段更好时才换，理由写进报告。一镜只用一条。
    2. 为每条归一化素材做联系表，每秒 4 帧：
       `ffmpeg -i 中间/归一化/<名>.mov -vf "fps=4,scale=180:-2,tile=8x3" 中间/联系表/<名>-%02d.jpg`
       第 k 张图覆盖第 6(k−1) 到 6k 秒；图里第 i 格（从 0 数，逐行）在 6(k−1) + i/4 秒。逐张看图挑段。
    3. 挑段：
       - 避开开头和结尾约 0.3 秒的起停晃动；素材不够长，或关键画面就在首尾（例如写完的数字最后才露出来）时除外。
       - 挑画面稳、对焦清楚、看得出内容里说的动作或信息的一段。
       - 动作镜头取一个完整动作（例如一次完整的引体），在动作的自然节点出点。
       - 有人说话时不要切在字中间：先用 `silencedetect` 找静音；说话连续、找不到静音时，按 50 毫秒一段算音量，把入出点放在最弱处。
    4. 时长：
       - 下限：剪辑要求里的单镜下限，和这一镜新出现文字的阅读时间（看得见的字符数 ÷ 9，单位秒；空格不算，✖️ 这类符号算 1 个），取大的。
       - 上限：剪辑要求里的单镜上限。
       - 先让每镜满足下限，再在上限内按画面需要加长（动作镜头取完整动作），总长落在要求的范围内即可。
       - 素材比下限还短就用整条，不变速、不定格、不重复同一段画面来凑时长，在报告里写明哪几镜的字可能来不及读。

    ### 5.5 上屏文字

    - 标签行：以第 4 节列出的标签加冒号（全角或半角）开头的行。一个标签的内容一直到下一个标签行为止；第一个标签行之前的文字是描述，不上屏。
    - 按标签的意思判断：写明要显示在屏幕上的（字幕、角标一类）上屏；说明拍什么、怎么处理的（描述、转场一类）只作剪辑依据，不上屏。认不出的标签不上屏，写进报告。
    - 标签和冒号不显示。冒号后的空格、紧跟冒号的换行不算内容，每行行尾空格去掉；其余换行照原样换行。
    - 原样使用，一个字都不增删改：不扩写、不精简、不改数字和符号（包括 ✖️）。内容里没写的就是这一镜没有，不要补。
    - 每段文字从这一镜开头显示到这一镜结尾。同一标签的文字在相邻镜头完全相同时，合并成一段跨切点连续显示，免得切点处闪一下。
    - 位置、字号、样式按用户的剪辑要求；没写的用默认值：下方字幕底部居中、最多两行、文字块中心约在屏高 71%；上方文字顶部居中、一行、顶边距约屏高 2%；白字黑描边，PingFang SC Semibold，字高约屏高 4.4%。一行放不下就在原文的空格处折行，不删字。
    - 片尾卡按剪辑要求做；没写时长时不少于 1.5 秒。

    ### 5.6 写 样式.json 和 剪辑决策.json

    格式见第 6 节。时间以秒计，全部对齐到画布帧率的整帧（30 fps 时是 1/30 秒的整数倍）。

    ### 5.7 生成成片、片段、字幕、音频

    1. `片段/NN.mp4`：从归一化素材按入出点裁出，不带文字；NN 是在成片里的顺序号。
    2. `字幕/`：由决策表生成 `字幕.ass`、每个上屏标签一份 SRT、片尾一份 SRT。
       - ASS 的 PlayResX / PlayResY 设为画布尺寸。
       - 字号：ASS 的 Fontsize 按行高算，不是字高。先用目标字体渲染一个汉字、量出实际字高，再换算 Fontsize（PingFang SC 实测字高约为 Fontsize 的 0.68 倍），换算系数写进 `样式.json`。
       - 时间：ASS 只精确到 0.01 秒，每个时间点向下取整到 0.01 秒，保证切点那一帧已经换成下一段文字；SRT 精确到毫秒，同样向下取整。
    3. 声音：
       - 每个切点两侧各做约 10 毫秒淡入淡出，防止爆音；最后一镜结尾 0.5 秒淡出，片尾静音。
       - 整片响度调到约 −14 LUFS、真峰值不超过 −1 dBTP（剪辑要求另有说明时按要求）：先测整片响度，用线性增益调到目标，再用限幅器只压超出的峰值（例如 `alimiter` 限在 −2 dBFS），不做整体压缩；实测不达标就调整后重做。
       - 结果另存为 `音频/成片混音.wav`。
    4. `成片.mp4`：按顺序拼接片段、接上片尾卡、烧录 `字幕.ass`、混入上一步的音频。H.264 High、yuv420p、BT.709、画布尺寸、恒定帧率、AAC 48 kHz 立体声、`-movflags +faststart`。

    ### 5.8 生成工程文件

    - FCPXML、OTIO、EDL 都引用 `中间/归一化/` 里的**整条素材**，按决策表的入出点剪，这样在剪辑软件里还能往两边拖长。媒体路径写绝对路径。
    - 时间线：主轨放素材；每个上屏标签各一条文字轨，放在素材上方；片尾卡是黑场加文字。
    - FCPXML 用 Final Cut Pro 与 DaVinci Resolve 都能读的版本（如 1.10），时间写成画布帧率的分数（如 `51/30s`）。
    - EDL 只放视频剪切点，片段名用镜头编号，片尾用 BL（黑场）。
    - 生成后用 OpenTimelineIO 把三个文件读回来，核对切点与决策表一致。本机没有对应的剪辑软件时，文字的位置和字号在报告里注明「需在剪辑软件里复核」。
    - 剪映草稿（可选）：可以用 Python 库 pyJianYingDraft 生成新草稿（素材轨、每个上屏标签一条文字轨、片尾），放进 `输出/工程/剪映草稿/`，不要直接写进剪映的草稿目录。
      - 建轨用 `append_track(TrackSpec(...))`；时间以微秒计，每段的起点和终点分别由帧号换算后再相减，否则相邻片段会因取整重叠。
      - 剪映 10.8 以后的版本（例如 11.5）草稿格式已经改变，生成的草稿很可能打不开：在报告里写明，并说明可以用 `片段/` 加 `字幕/*.srt` 在剪映里手动搭出同样的时间线。

    """

    private static let formats = """
    ## 6. 文件格式

    ### 剪辑决策.json

    ```json
    {
      "schemaVersion": 1,
      "film": "…",
      "revision": 1,
      "canvas": { "width": 2160, "height": 3840, "fps": 30 },
      "timeline": [
        {
          "order": 1,
          "shot": 1,
          "clipId": "…",
          "source": "…-01.mov",
          "normalized": "中间/归一化/…-01.mov",
          "in": 0.8,
          "out": 2.4,
          "start": 0.0,
          "duration": 1.6,
          "reason": "写完的读数清楚"
        }
      ],
      "texts": [
        { "label": "下方字幕", "text": "今日体重113.2KG", "shots": [1, 2], "start": 0.0, "end": 2.4 }
      ],
      "tailCard": { "text": "…", "start": 22.467, "duration": 1.5, "background": "#000000" },
      "audio": { "loudnessLUFS": -14, "truePeakDBTP": -1, "cutFadeMs": 10, "tailFadeOutMs": 500 },
      "totalDuration": 23.967
    }
    ```

    - `in` / `out` 是源素材里的时间，`start` / `duration` 是成片里的时间，都以秒计、对齐整帧。
    - `texts[].text` 是去掉标签后的原文，换行写成 `\\n`。
    - 上面的数值只是格式示例，不是这部片的答案。

    ### 样式.json

    ```json
    {
      "canvas": { "width": 2160, "height": 3840, "fps": 30 },
      "font": { "family": "PingFang SC", "weight": "Semibold" },
      "labels": {
        "下方字幕": { "align": "bottom-center", "centerY": 0.71, "maxLines": 2, "sizePx": 169,
                   "color": "#FFFFFF", "stroke": { "color": "#000000", "px": 12 } }
      },
      "tailCard": { "background": "#000000", "align": "center", "sizePx": 169, "color": "#FFFFFF" },
      "render": { "assGlyphHeightRatio": 0.68 },
      "notes": "剪辑要求里没写文字样式，用默认值"
    }
    ```

    `sizePx` 是汉字的实际高度；`render.assGlyphHeightRatio` 是实测的「字高 ÷ ASS Fontsize」。

    """

    private static let acceptance = """
    ## 7. 验收（全部通过才算完成）

    1. `成片.mp4` 用 ffprobe 核对：画布尺寸、恒定帧率、H.264、yuv420p、BT.709、AAC 48 kHz 立体声；帧数等于决策表的终点（误差不超过 1 帧），总长在要求的范围内（不在时报告写明原因）。
    2. 每个已拍镜头按编号恰好出现一次，未拍的镜头没有出现：逐镜取成片里的一帧，与决策表所指的素材帧比对（避开文字区域，PSNR 高于 30 dB）。
    3. 写脚本比对：决策表里每段文字，与 `manifest.json` 里对应镜头的 `note`（按 5.5 去掉标签和空白后）逐字相同；`字幕.ass`、各 SRT 与决策表逐条一致。
    4. 工程文件读回的切点与决策表一致。
    5. 抽检：在成片里每镜的中点抽一帧，拼成 `中间/抽检/成片抽帧.jpg`，自己看一遍：文字完整、没被裁掉、特殊符号显示出来了、位置对、字高与 `样式.json` 相差不超过 10%；前后镜头亮度和颜色一致（没有发灰的镜头）；没有黑帧、绿帧。再抽两处切点前后各一帧，确认文字在切点那一帧切换。
    6. 用 `ebur128` 实测响度与真峰值，达到 5.7 的目标。
    7. 第 3 节列出的文件都在；没做的项在报告里说明原因。

    验收脚本读不到某个值（例如日志级别把输出压掉了）时判为失败，不要默认通过。

    """

    private static let report = """
    ## 8. 剪辑报告

    `输出/剪辑报告.md` 写：

    - 概要：成片时长、画布、用了几镜、与剪辑要求不一致的地方；
    - 每镜一行：顺序｜镜头｜素材｜入点–出点｜成片时长｜上屏文字｜选段理由；
    - 取舍：素材不够长、字来不及读、分辨率不一致、折行等情况怎么处理的；
    - 降级：缺什么工具、哪项没做、怎么补；
    - 怎么改：用户可以直接说「第 N 镜换备用片段」「第 N 镜入点往后 0.5 秒」「整片短 3 秒」。

    """

    private static let rerun = """
    ## 9. 修改与重跑

    - `输出/剪辑决策.json` 已经存在时，这是一次修改：先把现有的 `剪辑决策.json`、`样式.json`、`剪辑报告.md` 复制到 `输出/历史/<时间>/`，只按用户这次的要求改决策表，`revision` 加 1，再重新生成全部产物。
    - 用户手改过决策表或样式时，以手改的为准，不要重新选段。
    - 用户在对话里要求改上屏文字时照做，并在报告里提醒：回 App 同步修改分镜内容，否则下次导出会还原。
    - 用户提供了上一版的 `剪辑决策.json` 时，按 `clipId` 对应沿用原来的入出点；对不上的镜头重新选。
    """
}

// MARK: - 第 4 节：本包素材情况

/// 按实际素材生成，只列本包存在的情况。
///
/// 每一条都对应试剪里真撞过的坑（HDR 混剪发灰、空间音轨解不了、按编码宽高算错画幅……），
/// 但**不存在的情况一条都不写**：列一条包里没有的坑，剪辑侧会去处理不存在的问题。
nonisolated extension ExportAgentBrief {

    fileprivate static func facts(_ manifest: ExportManifest) -> String {
        let shots = manifest.shots
        let mains: [(number: Int, clip: ExportManifest.ClipEntry)] = shots.compactMap { shot in
            shot.clips.first { $0.role == "main" }.map { (shot.number, $0) }
        }
        // 事实按**包里全部素材**算，不只看主素材：备用片段也会被换上时间线，
        // 它的音轨顺序、动态范围与主素材未必一样。
        let entries: [(number: Int, clip: ExportManifest.ClipEntry)] = shots.flatMap { shot in
            shot.clips.map { (shot.number, $0) }
        }
        var lines: [String] = [overview(shots, mains: mains), labelsLine(manifest)]
        // 一个镜头的几条素材参数可能不同（重拍时换了画质、换了麦克风），
        // 所以事实按「镜头号-条号」标注；整镜一致时再收回镜头号。
        let list: ([(number: Int, clip: ExportManifest.ClipEntry)]) -> String = { self.tokens($0, in: shots) }

        let hdr = entries.filter { $0.clip.video?.hdr != nil }
        if !hdr.isEmpty {
            let kinds = Set(hdr.compactMap { $0.clip.video?.hdr }).sorted().joined(separator: " / ")
            let sdr = entries.filter { $0.clip.video?.hdr == nil }
            let sdrText = sdr.isEmpty ? "" : "，\(list(sdr)) 是 SDR"
            lines.append("- 画面：\(list(hdr)) 是 \(kinds) HDR\(sdrText)。混剪前必须全部转成 SDR（见 5.3），否则 HDR 镜头会发灰。")
        }

        let rotated = entries.filter { ($0.clip.video?.rotation ?? 0) != 0 }
        if !rotated.isEmpty {
            lines.append("- 方向：\(list(rotated)) 是横向编码加旋转元数据，实际画面是竖的。尺寸按 `manifest.json` 的 `displaySize` 算，不要按编码宽高。")
        }

        let sizes = group(entries, in: shots) { clip in clip.video?.displaySize.map { "\($0[0])×\($0[1])" } }
        if sizes.count > 1 {
            lines.append("- 分辨率：\(describe(sizes))。画布按 5.2 取最多的那一种，其余缩放到画布尺寸。")
        }

        let rates = group(entries, in: shots) { clip in clip.video?.fps.map { "\(Int($0.rounded())) fps" } }
        let variable = entries.filter { $0.clip.video?.variableFrameRate == true }
        if rates.count > 1 || !variable.isEmpty {
            var text = "- 帧率：\(describe(rates))"
            if !variable.isEmpty { text += "；\(list(variable)) 是可变帧率，剪之前统一成画布帧率" }
            lines.append(text + "。")
        }

        if let audio = audioLine(entries, list: list) { lines.append(audio) }

        let short = entries.filter { ($0.clip.duration ?? .greatestFiniteMagnitude) < 2 }
        if !short.isEmpty {
            let detail = short.map { "\(list([$0])) 只有 \(String(format: "%.2f", $0.clip.duration ?? 0)) 秒" }
            lines.append("- 短素材：\(detail.joined(separator: "，"))，按 5.4 用整条，不变速、不定格。")
        }

        if let symbols = symbolLine(shots, labels: manifest.film.labels) { lines.append(symbols) }
        if let repeated = repeatedTextLine(shots, labels: manifest.film.labels) { lines.append(repeated) }

        let unreadable = entries.filter { $0.clip.video == nil || $0.clip.duration == nil }
        if !unreadable.isEmpty {
            lines.append("- 参数缺失：\(list(unreadable)) 没读出素材参数（`manifest.json` 里留空），按 5.1 以 ffprobe 实测为准。")
        }

        return """
        ## 4. 本包素材情况

        \(lines.joined(separator: "\n"))

        """
    }

    // MARK: 逐条

    private static func overview(_ shots: [ExportManifest.ShotEntry], mains: [(number: Int, clip: ExportManifest.ClipEntry)]) -> String {
        let pending = shots.filter { $0.status != "recorded" }
        let alternates = shots.flatMap { $0.clips }.filter { $0.role == "alternate" }
        var text = "- 共 \(shots.count) 个镜头：已拍 \(mains.count)"
        if !pending.isEmpty {
            text += "，未拍 \(pending.count)（\(numbers(pending.map(\.number)))，按 5.4 跳过，不占时间线）"
        }
        if alternates.isEmpty {
            text += "。每镜一条，没有备用片段。"
        } else {
            let numbersWithAlternates = shots.filter { $0.clips.contains { $0.role == "alternate" } }.map(\.number)
            text += "。\(numbers(numbersWithAlternates)) 有备用片段（共 \(alternates.count) 条，在「备用片段」目录里），主素材不能用时才换。"
        }
        return text
    }

    private static func labelsLine(_ manifest: ExportManifest) -> String {
        guard !manifest.film.labels.isEmpty else {
            return "- 上屏标签：本片的内容没有按「标签：内容」写。按整段内容判断哪些字要上屏，拿不准就不上屏，并在报告里说明。"
        }
        let quoted = manifest.film.labels.map { "「\($0)」" }.joined()
        return "- 上屏标签：\(quoted)。标签行只认这些标签开头的行（见 5.5），内容里其它带冒号的句子不是标签。"
    }

    private static func audioLine(
        _ entries: [(number: Int, clip: ExportManifest.ClipEntry)],
        list: ([(number: Int, clip: ExportManifest.ClipEntry)]) -> String
    ) -> String? {
        let notFirst = entries.filter { ($0.clip.preferredAudioIndex ?? 0) != 0 }
        let mono = entries.filter { entry in entry.clip.audio.first { $0.index == entry.clip.preferredAudioIndex }?.channels == 1 }
        let missing = entries.filter { $0.clip.preferredAudioIndex == nil && !$0.clip.audio.isEmpty }
        let exotic = Set(entries.flatMap { $0.clip.audio }.map(\.codec)).subtracting(["aac"]).sorted()
        guard !notFirst.isEmpty || !mono.isEmpty || !missing.isEmpty || !exotic.isEmpty else { return nil }

        var parts: [String] = []
        if !notFirst.isEmpty {
            let codecs = exotic.isEmpty ? "另一种编码" : exotic.joined(separator: " / ")
            parts.append("\(list(notFirst)) 的第一条音轨是 \(codecs)（iPhone 的空间音频，ffmpeg 解不了），可用的 AAC 在后面")
        } else if !exotic.isEmpty {
            parts.append("有 \(exotic.joined(separator: " / ")) 音轨，多数工具解不了")
        }
        if !mono.isEmpty { parts.append("\(list(mono)) 只有单声道，按 5.3 复制成两声道") }
        if !missing.isEmpty { parts.append("\(list(missing)) 没有可用的 AAC 轨，按 5.3 用 avconvert 的输出") }
        return "- 音轨：\(parts.joined(separator: "；"))。每条素材的音轨顺序都可能不同，逐条用 `manifest.json` 的 `preferredAudioIndex`，不要对所有素材用同一个映射。"
    }

    private static func symbolLine(_ shots: [ExportManifest.ShotEntry], labels: [String]) -> String? {
        let hits = shots.filter { shot in
            ExportLabels.labeled(shot.note, labels: labels).contains { entry in
                entry.text.unicodeScalars.contains { !$0.isASCII && $0.properties.isEmoji }
            }
        }
        guard !hits.isEmpty else { return nil }
        return "- 特殊符号：\(numbers(hits.map(\.number))) 的上屏文字里有 emoji 一类的符号，照原样显示，抽检时确认它们显示出来了。"
    }

    private static func repeatedTextLine(_ shots: [ExportManifest.ShotEntry], labels: [String]) -> String? {
        var runs: [String] = []
        for label in labels {
            var current: (text: String, numbers: [Int])?
            var groups: [[Int]] = []
            for shot in shots.sorted(by: { $0.number < $1.number }) {
                let text = ExportLabels.labeled(shot.note, labels: labels).first { $0.label == label }?.text
                if let text, let running = current, running.text == text, running.numbers.last == shot.number - 1 {
                    current = (text, running.numbers + [shot.number])
                } else {
                    if let running = current, running.numbers.count > 1 { groups.append(running.numbers) }
                    current = text.map { ($0, [shot.number]) }
                }
            }
            if let running = current, running.numbers.count > 1 { groups.append(running.numbers) }
            for group in groups { runs.append("\(numbers(group)) 的「\(label)」相同") }
        }
        guard !runs.isEmpty else { return nil }
        return "- 重复文字：\(runs.joined(separator: "；"))，按 5.5 合并成一段跨切点连续显示。"
    }

    // MARK: 格式化

    /// `[1, 3, 4, 5]` → `01、03–05`：连着三个以上收成区间，短清单一眼能看完
    fileprivate static func numbers(_ list: [Int]) -> String {
        let sorted = Set(list).sorted()
        guard !sorted.isEmpty else { return "" }
        var parts: [String] = []
        var start = sorted[0], previous = sorted[0]
        func flush() {
            let head = String(format: "%02d", start)
            if previous - start >= 2 { parts.append("\(head)–\(String(format: "%02d", previous))") }
            else if previous == start { parts.append(head) }
            else { parts.append(head); parts.append(String(format: "%02d", previous)) }
        }
        for number in sorted.dropFirst() {
            if number == previous + 1 { previous = number; continue }
            flush(); start = number; previous = number
        }
        flush()
        return parts.joined(separator: "、")
    }

    /// 按某个属性把素材分组，保持首次出现的顺序
    private static func group(
        _ entries: [(number: Int, clip: ExportManifest.ClipEntry)],
        in shots: [ExportManifest.ShotEntry],
        by value: (ExportManifest.ClipEntry) -> String?
    ) -> [(value: String, tokens: String)] {
        var groups: [(value: String, entries: [(number: Int, clip: ExportManifest.ClipEntry)])] = []
        for entry in entries {
            guard let key = value(entry.clip) else { continue }
            if let index = groups.firstIndex(where: { $0.value == key }) { groups[index].entries.append(entry) }
            else { groups.append((key, [entry])) }
        }
        return groups.map { ($0.value, tokens($0.entries, in: shots)) }
    }

    /// 素材的短称呼：整镜只有一条、或整镜都在这一组里时写镜头号（`03`），否则写到条（`01-2`）
    fileprivate static func tokens(
        _ entries: [(number: Int, clip: ExportManifest.ClipEntry)],
        in shots: [ExportManifest.ShotEntry]
    ) -> String {
        let packaged = Dictionary(uniqueKeysWithValues: shots.map { ($0.number, $0.clips.count) })
        var parts: [String] = []
        var run: [Int] = []   // 连着的整镜收成区间，断开时立刻落袋，顺序仍按镜头号
        func flushRun() {
            guard !run.isEmpty else { return }
            parts.append(numbers(run))
            run = []
        }
        for (number, group) in Dictionary(grouping: entries, by: { $0.number }).sorted(by: { $0.key < $1.key }) {
            if group.count >= packaged[number] ?? 1 {
                run.append(number)
            } else {
                flushRun()
                parts.append(contentsOf: group.sorted { $0.clip.take < $1.clip.take }
                    .map { String(format: "%02d-%d", number, $0.clip.take) })
            }
        }
        flushRun()
        return parts.joined(separator: "、")
    }

    /// `02 是 1080×1920，其余 2160×3840`：数量最多的那组写成「其余」；只有一种时写「全部」
    private static func describe(_ groups: [(value: String, tokens: String)]) -> String {
        guard let largest = groups.max(by: { $0.tokens.count < $1.tokens.count }) else { return "" }
        if groups.count == 1 { return "全部 \(largest.value)" }
        let others = groups.filter { $0.value != largest.value }
        let text = others.map { "\($0.tokens) 是 \($0.value)" }
        return (text + ["其余 \(largest.value)"]).joined(separator: "，")
    }
}
