#!/usr/bin/env python3
"""开发辅助脚本：把演示素材写进已安装的模拟器 App 容器，方便截图与人工验收。

一个镜头可以有多条片段，这里给镜头 1 塞了 3 条，用来验证多片段相关的界面。

用法：
    python3 Tools/seed-simulator.py            # 只有一台模拟器启动时
    python3 Tools/seed-simulator.py <UDID>     # 同时启动多台时，指定设备
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

device = sys.argv[1] if len(sys.argv) > 1 else "booted"

container = subprocess.check_output(
    ["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"],
    text=True,
).strip()
print("容器路径:", container)

clips_dir = os.path.join(container, "Documents", "分镜视频")
meta_dir = os.path.join(container, "Library", "Application Support", "ShotList")
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
        shutil.copyfile(f"/tmp/slseed/v{source}.mov", os.path.join(clips_dir, file_name))
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
print(
    f"已写入分镜: {len(records)} 条，片段: {total_clips} 段，"
    f"磁盘文件: {len(os.listdir(clips_dir))} 个"
)
