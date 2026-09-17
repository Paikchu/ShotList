#!/usr/bin/env python3
"""开发辅助脚本：把演示素材写进已安装的模拟器 App 容器，方便截图与人工验收。

演示数据是**两部影片**：

* 「夏日vlog」——5 个镜头、3 个已拍（镜头 1 拍满 3 条），最后更新为今天；
* 「咖啡店探店」——3 个镜头全部已拍，最后更新为昨天。

每个镜头都带屏幕字幕与角标文字（留几个空着，用来对照「这一镜不出」的样子）；
「夏日vlog」另外带一段剪辑风格描述，用来验收导出包里的「剪辑风格.md」——
「咖啡店探店」刻意不写，用来对照「没有要求时不出那个文件」。
`--legacy` 写的是**真的**旧数据，会把这两个字段删掉。

两部影片的镜头 1 都命名为「镜头01_…」，这是刻意安排的：用来验证「未使用文件」
的判据覆盖全部影片。如果那个判据只看当前影片，切到第二部时第一部的素材会被
误判成可以清理的孤儿——点一次「清理未使用的文件」就永久删掉了它们。

跑之前会清空容器里的片段目录与全部元数据文件：脚本每次都写同一批固定文件名，
不清的话上一轮的文件会留下当孤儿（既不被记录引用，也不会被导出带走）。

用法：
    python3 Tools/seed-simulator.py                 # 只有一台模拟器启动时
    python3 Tools/seed-simulator.py <UDID>          # 同时启动多台时，指定设备
    python3 Tools/seed-simulator.py --legacy        # 写旧版 shots.json，用于验收升级路径
    python3 Tools/seed-simulator.py <UDID> --legacy

前置条件：/tmp/slseed/v1.mov … v5.mov 必须存在（脚本按序号取用），
缺失时只打印一句提示并退出，不抛栈。
"""
import json
import os
import shutil
import subprocess
import sys
import time
import uuid

BUNDLE = "com.max.ShotList"
REFERENCE_EPOCH_OFFSET = 978307200  # 2001-01-01 UTC 与 Unix epoch 的差值
SOURCE_DIR = "/tmp/slseed"
SOURCE_FILES = 5

arguments = sys.argv[1:]
flags = {item for item in arguments if item.startswith("--")}
positional = [item for item in arguments if not item.startswith("--")]
device = positional[0] if positional else "booted"
legacy = "--legacy" in flags

missing = [
    f"{SOURCE_DIR}/v{index}.mov"
    for index in range(1, SOURCE_FILES + 1)
    if not os.path.isfile(f"{SOURCE_DIR}/v{index}.mov")
]
if missing:
    print(f"缺少占位素材：{'、'.join(missing)}")
    print(f"请先准备 {SOURCE_DIR}/v1.mov … v{SOURCE_FILES}.mov（内容任意，脚本只做复制）")
    sys.exit(1)

container = subprocess.check_output(
    ["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"],
    text=True,
).strip()
print("容器路径:", container)

clips_dir = os.path.join(container, "Documents", "分镜视频")
meta_dir = os.path.join(container, "Library", "Application Support", "ShotList")

if os.path.isdir(clips_dir):
    removed = len(os.listdir(clips_dir))
    shutil.rmtree(clips_dir)
    if removed:
        print(f"已清空上一轮的 {removed} 个片段文件")
os.makedirs(clips_dir, exist_ok=True)
os.makedirs(meta_dir, exist_ok=True)

# 上一轮留下的元数据一并清掉。shots.json.migrated 是升级后保留的回滚保险，
# 留着它会让下一次启动把旧记录又搬回来，盖掉这一轮写的演示数据。
for name in ("films.json", "shots.json", "shots.json.migrated", "pending-deletions.json"):
    path = os.path.join(meta_dir, name)
    if os.path.exists(path):
        os.remove(path)

now = time.time()
ref_now = now - REFERENCE_EPOCH_OFFSET
ref_yesterday = ref_now - 86400

# (标题, 最后更新时间, 是否当前影片, [(编号, 分镜描述, 屏幕字幕, 角标文字, [(源视频序号, 时长秒, 拍摄时间)])])
#
# 屏幕字幕与角标文字是镜头级的**内容**，与风格无关，所以直接写进演示数据：
# 没有它们，导出包里的「屏幕字幕 / 角标」两列全是空的，验收时看不出这一步有没有生效。
# 角标刻意让连续几个镜头用同一段文字（镜头 2、3 都是「热量缺口：2318千卡」），
# 用来对照 App 里那个「沿用上一镜」按钮的实际效果。
FILMS = [
    (
        "夏日vlog",
        ref_now,
        True,
        [
            (
                1,
                "无人机缓慢上升，配一句开场旁白",
                "开场就下雨\n计划全改了",
                "热量缺口：1968千卡",
                [(1, 6.0, ref_now - 1800), (2, 7.0, ref_now - 1500), (3, 5.0, ref_now - 900)],
            ),
            (2, "手持稳定器横摇，保持水平，速度放慢", "街角这家店开了十二年", "热量缺口：2318千卡", [(4, 7.0, ref_now - 600)]),
            (3, "手冲壶出水特写，收环境音", "手冲 ⌄ 15g * 1 * 92°C", "热量缺口：2318千卡", [(5, 8.0, ref_yesterday)]),
            (4, "从背后跟拍走进地铁站，等待补拍", "", "", []),
            (5, "正对镜头说最后一句总结，等待补拍", "下次还来", "热量缺口：1168千卡", []),
        ],
    ),
    (
        "咖啡店探店",
        ref_yesterday,
        False,
        [
            (1, "推开玻璃门，跟拍进店", "第一次来这家", "热量缺口：768千卡", [(1, 5.0, ref_yesterday - 3600)]),
            (2, "吧台手冲过程特写", "吧台 ⌄ 2 分钟出杯", "", [(2, 9.0, ref_yesterday - 3000)]),
            (3, "坐下举杯对镜头说感受", "酸度比昨天那家高", "热量缺口：1500千卡", [(3, 6.0, ref_yesterday - 2400)]),
        ],
    ),
]


# 每部影片的剪辑风格描述（影片级，存整段文字）。
# 只给第一部写：第二部留空，用来验收「没有要求时导出包里不出剪辑风格.md」。
STYLE_PROMPTS = {
    "夏日vlog": (
        "竖屏 1080×1920、30fps，总长 20 秒左右，单镜 0.5–2.5 秒，快切不拖沓。\n"
        "保留现场原声，不加解说、不加背景音乐。\n"
        "顶部居中一行角标（不透明黑底条），底部居中两行以内字幕，"
        "都是白色粗体加黑描边，字高约占屏高 4.4%。\n"
        "结尾 0.7 秒黑底卡，居中写一句收尾。"
    ),
}


def timestamp_token(recorded_at):
    """文件名里的时间戳，与 ShotStore.timestampToken() 同一格式。"""
    return time.strftime("%Y%m%d_%H%M%S", time.localtime(recorded_at + REFERENCE_EPOCH_OFFSET))


def build_film(title, updated_at, shots_spec):
    shots = []
    for number, note, caption, badge_text, takes in shots_spec:
        clips = []
        for source, duration, recorded_at in takes:
            file_name = f"镜头{number:02d}_{timestamp_token(recorded_at)}.mov"
            shutil.copyfile(
                os.path.join(SOURCE_DIR, f"v{source}.mov"),
                os.path.join(clips_dir, file_name),
            )
            clips.append(
                {
                    "id": str(uuid.uuid4()).upper(),
                    "fileName": file_name,
                    "duration": duration,
                    "recordedAt": recorded_at,
                }
            )
        shots.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "number": number,
                "note": note,
                "caption": caption,
                "badgeText": badge_text,
                "clips": clips,
            }
        )
    return {
        "id": str(uuid.uuid4()).upper(),
        "title": title,
        "stylePrompt": STYLE_PROMPTS.get(title, ""),
        "shots": shots,
        "createdAt": updated_at,
        "updatedAt": updated_at,
    }


if legacy:
    # 旧版布局：一份全局分镜清单，没有影片层级、没有标题。
    # 只造第一部影片的镜头——旧版本里根本没有「多部影片」这回事，
    # 多写一部只会平白多出几个无人引用的孤儿文件。
    title, updated_at, _, shots_spec = FILMS[0]
    records = build_film(title, updated_at, shots_spec)["shots"]
    # 旧数据里没有屏幕字幕与角标这两个字段，去掉才是真的旧数据。
    # 留着它们只能验证「新版读新版」，验不到缺字段时会不会整份读不出来。
    for record in records:
        record.pop("caption", None)
        record.pop("badgeText", None)
    with open(os.path.join(meta_dir, "shots.json"), "w", encoding="utf-8") as handle:
        json.dump(records, handle, ensure_ascii=False, indent=2)
    expected = sum(len(takes) for _, _, _, _, takes in shots_spec)
    print(f"已写入旧版 shots.json：{len(records)} 条分镜，{expected} 段片段")
else:
    films = [build_film(title, updated_at, shots) for title, updated_at, _, shots in FILMS]
    current = next(
        film["id"]
        for film, (_, _, is_current, _) in zip(films, FILMS)
        if is_current
    )
    library = {"films": films, "currentFilmID": current}
    with open(os.path.join(meta_dir, "films.json"), "w", encoding="utf-8") as handle:
        json.dump(library, handle, ensure_ascii=False, indent=2)
    for film in films:
        clips = sum(len(shot["clips"]) for shot in film["shots"])
        print(f"影片「{film['title']}」：{len(film['shots'])} 个镜头，{clips} 段片段"
              + ("（当前影片）" if film["id"] == current else ""))
    expected = sum(
        len(takes)
        for _, _, _, shots_spec in FILMS
        for _, _, _, _, takes in shots_spec
    )

disk_files = len(os.listdir(clips_dir))
print(f"磁盘文件: {disk_files} 个")
# 两个数字必须相等：目录里多出来的就是孤儿文件，说明清空那一步没生效
if disk_files != expected:
    print(f"注意：磁盘文件数（{disk_files}）与预期片段数（{expected}）不一致，目录里有未使用的文件")
