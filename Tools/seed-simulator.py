#!/usr/bin/env python3
"""开发辅助脚本：把演示素材写进已安装的模拟器 App 容器，方便截图与人工验收。

一个镜头可以有多条片段，这里给镜头 1 塞了 3 条，用来验证多片段相关的界面。

跑之前会清空容器里的「分镜视频」目录：脚本每次都写同一批固定文件名，不清的话
上一轮的文件会留下当孤儿（既不被 shots.json 引用，也不会被导出带走）。

用法：
    python3 Tools/seed-simulator.py            # 只有一台模拟器启动时
    python3 Tools/seed-simulator.py <UDID>     # 同时启动多台时，指定设备

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

device = sys.argv[1] if len(sys.argv) > 1 else "booted"

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

# 清空片段目录（保留目录本身），否则上一轮的文件会变成无人引用的孤儿
if os.path.isdir(clips_dir):
    removed = len(os.listdir(clips_dir))
    shutil.rmtree(clips_dir)
    if removed:
        print(f"已清空上一轮的 {removed} 个片段文件")
os.makedirs(clips_dir, exist_ok=True)
os.makedirs(meta_dir, exist_ok=True)

now = time.time()
ref_now = now - REFERENCE_EPOCH_OFFSET
ref_yesterday = ref_now - 86400

# (编号, 分镜描述, [(源视频序号, 时长秒, 拍摄时间)])
plan = [
    (
        1,
        "无人机缓慢上升，配一句开场旁白",
        [(1, 6.0, ref_now - 1800), (2, 7.0, ref_now - 1500), (3, 5.0, ref_now - 900)],
    ),
    (2, "手持稳定器横摇，保持水平，速度放慢", [(4, 7.0, ref_now - 600)]),
    (3, "手冲壶出水特写，收环境音", [(5, 8.0, ref_yesterday)]),
    (4, "从背后跟拍走进地铁站，等待补拍", []),
    (5, "正对镜头说最后一句总结，等待补拍", []),
]

records = []
for number, note, takes in plan:
    clips = []
    for source, duration, recorded_at in takes:
        token = time.strftime(
            "%Y%m%d_%H%M%S",
            time.localtime(recorded_at + REFERENCE_EPOCH_OFFSET),
        )
        file_name = f"镜头{number:02d}_{token}.mov"
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
    records.append(
        {
            "id": str(uuid.uuid4()).upper(),
            "number": number,
            "note": note,
            "clips": clips,
        }
    )

with open(os.path.join(meta_dir, "shots.json"), "w", encoding="utf-8") as handle:
    json.dump(records, handle, ensure_ascii=False, indent=2)

total_clips = sum(len(record["clips"]) for record in records)
disk_files = len(os.listdir(clips_dir))
print(f"已写入分镜: {len(records)} 条，片段: {total_clips} 段，磁盘文件: {disk_files} 个")
# 两个数字必须相等：目录里多出来的就是孤儿文件，说明清空那一步没生效
if disk_files != total_clips:
    print(f"注意：磁盘文件数（{disk_files}）与片段数（{total_clips}）不一致，目录里有未使用的文件")
