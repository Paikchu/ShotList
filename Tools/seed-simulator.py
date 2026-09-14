#!/usr/bin/env python3
"""开发辅助脚本：把演示素材写进已安装的模拟器 App 容器，方便截图与人工验收。

用法：
    python3 Tools/seed-simulator.py

需要 ffmpeg（用于生成占位视频）。如果 /tmp/slseed 中已经有样例视频，则直接复用。
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
SEED_DIR = "/tmp/slseed"


def ensure_sample_clips():
    """生成 4 个色相不同的占位视频。"""
    if all(os.path.exists(os.path.join(SEED_DIR, f"v{i}.mov")) for i in range(1, 5)):
        return
    if shutil.which("ffmpeg") is None:
        sys.exit("缺少 ffmpeg，无法生成样例视频。请先安装：brew install ffmpeg")
    os.makedirs(SEED_DIR, exist_ok=True)
    for index, hue in enumerate((0, 90, 180, 270), start=1):
        duration = 5 + index
        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi",
                "-i", f"testsrc2=size=720x1280:rate=30:duration={duration}",
                "-vf", f"hue=h={hue}:s=1.3",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                os.path.join(SEED_DIR, f"v{index}.mov"),
            ],
            check=True,
        )


def main():
    ensure_sample_clips()

    container = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", "booted", BUNDLE, "data"],
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

    plan = [
        # (编号, 标题, 备注, 源视频序号, 时长, recordedAt)
        (1, "开场：城市天际线", "无人机缓慢上升，配一句开场旁白", 1, 6.0, ref_now),
        (2, "街景横摇", "手持稳定器，保持水平，速度放慢", 2, 7.0, ref_now),
        (3, "咖啡店特写", "手冲壶出水特写，收环境音", 3, 8.0, ref_now),
        (4, "人物跟拍", "从背后跟拍走进地铁站，昨天拍的", 4, 9.0, ref_yesterday),
        (5, "结尾口播", "正对镜头说最后一句总结，等待补拍", None, None, None),
        (6, "空镜：雨滴", "玻璃上的雨滴，做转场用，等待补拍", None, None, None),
    ]

    records = []
    for number, title, note, source, duration, recorded_at in plan:
        clip_name = None
        if source is not None:
            clip_name = f"镜头{number}_20260914_1200{source:02d}.mov"
            shutil.copyfile(os.path.join(SEED_DIR, f"v{source}.mov"), os.path.join(clips_dir, clip_name))
        records.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "number": number,
                "title": title,
                "note": note,
                "clipFileName": clip_name,
                "recordedAt": recorded_at,
                "clipDuration": duration,
            }
        )

    with open(os.path.join(meta_dir, "shots.json"), "w", encoding="utf-8") as handle:
        json.dump(records, handle, ensure_ascii=False, indent=2)

    print("已写入分镜:", len(records), "条，视频:", len(os.listdir(clips_dir)), "个")


if __name__ == "__main__":
    main()
