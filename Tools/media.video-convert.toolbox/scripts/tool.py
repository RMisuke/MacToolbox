#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MacToolbox 视频格式转换（Tool Protocol 实现）。

设计原则：
- 一个表单完成封装 + 编码转换；默认 H.264 / AAC，兼顾兼容性；
- 支持复制流（remux）和软件重编码；不依赖额外二进制，只要 ffmpeg；
- 输出先写临时文件，成功后再原子替换；
- 不保留字幕/多音轨（复制流模式会保留全部流）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import uuid
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

CURRENT = {"proc": None, "cancelled": False}

VIDEO_CODECS = {
    "h264": "libx264",
    "hevc": "libx265",
    "av1": "libsvtav1",
    "vp9": "libvpx-vp9",
    "prores": "prores_ks",
    "copy": "copy",
}
AUDIO_CODECS = {
    "aac": "aac",
    "opus": "libopus",
    "mp3": "libmp3lame",
    "flac": "flac",
    "alac": "alac",
    "pcm": "pcm_s16le",
    "copy": "copy",
    "none": "none",
}
FORMAT_EXTS = {
    "mp4": "mp4",
    "mov": "mov",
    "mkv": "mkv",
    "webm": "webm",
    "avi": "avi",
    "gif": "gif",
}
FORMAT_LABELS = {
    "mp4": "MP4",
    "mov": "MOV",
    "mkv": "MKV",
    "webm": "WebM",
    "avi": "AVI",
    "gif": "GIF",
}
RESOLUTION_HEIGHTS = {
    "2160": 2160,
    "1440": 1440,
    "1080": 1080,
    "720": 720,
    "480": 480,
}
FPS_VALUES = {"60": 60, "30": 30, "24": 24, "15": 15, "12": 12}

CONTAINER_VIDEO = {
    "mp4": {"h264", "hevc", "av1", "mpeg4"},
    "mov": {"h264", "hevc", "prores", "av1", "mpeg4"},
    "mkv": {"h264", "hevc", "av1", "vp9", "vp8", "prores", "mpeg4"},
    "webm": {"vp9", "vp8", "av1"},
    "avi": {"h264", "mpeg4", "mjpeg"},
    "gif": set(),
}
CONTAINER_AUDIO = {
    "mp4": {"aac", "alac", "mp3"},
    "mov": {"aac", "alac", "mp3", "pcm_s16le"},
    "mkv": {"aac", "opus", "mp3", "flac", "alac", "pcm_s16le", "vorbis"},
    "webm": {"opus", "vorbis"},
    "avi": {"mp3", "pcm_s16le"},
    "gif": set(),
}
VIDEO_LABELS = {
    "h264": "H.264",
    "hevc": "H.265",
    "av1": "AV1",
    "vp9": "VP9",
    "prores": "ProRes",
    "copy": "复制原视频",
    "gif": "GIF",
}
AUDIO_CONTAINER_NAMES = {
    "aac": "aac",
    "opus": "opus",
    "mp3": "mp3",
    "flac": "flac",
    "alac": "alac",
    "pcm": "pcm_s16le",
}
AUDIO_LABELS = {
    "aac": "AAC",
    "opus": "Opus",
    "mp3": "MP3",
    "flac": "FLAC",
    "alac": "ALAC",
    "pcm": "PCM",
    "copy": "复制原音频",
    "none": "无音频",
}


# ---------------------------------------------------------------- protocol

def emit(**payload):
    try:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except Exception:
        pass


def log(message, level="info"):
    emit(type="log", level=level, message=str(message))


def progress(fraction, step=None, message=None):
    payload = {"type": "progress", "fraction": max(0.0, min(1.0, float(fraction)))}
    if step:
        payload["step"] = step
    if message:
        payload["message"] = message
    emit(**payload)


def step_event(step, title, state):
    emit(type="step", step=step, title=title, state=state)


def artifact(kind, path, label=None, artifact_id=None):
    item = {"id": artifact_id or kind, "kind": kind, "path": str(path)}
    if label:
        item["label"] = label
    emit(type="artifact", **item)
    return item


def fail(message, code="failed", detail=None):
    payload = {"type": "error", "code": code, "message": message}
    if detail:
        payload["detail"] = str(detail)
    emit(**payload)
    sys.exit(1)


def install_signals():
    def handler(signum, frame):
        CURRENT["cancelled"] = True
        proc = CURRENT.get("proc")
        if proc and proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception:
                try:
                    proc.terminate()
                except Exception:
                    pass
        emit(type="error", code="cancelled", message="任务已取消")
        sys.exit(130)

    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


# ---------------------------------------------------------------- process

def run_process(cmd, log_cmd=True, on_stdout=None, on_stderr=None):
    if log_cmd:
        log("$ " + subprocess.list2cmdline([str(part) for part in cmd]))
    proc = subprocess.Popen(
        [str(part) for part in cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        start_new_session=True,
    )
    CURRENT["proc"] = proc
    stdout_lines, stderr_lines = [], []

    def pump(stream, callback, sink):
        try:
            for raw in iter(stream.readline, ""):
                line = raw.rstrip("\n")
                sink.append(line)
                if callback:
                    callback(line)
        finally:
            try:
                stream.close()
            except Exception:
                pass

    threads = [
        threading.Thread(target=pump, args=(proc.stdout, on_stdout, stdout_lines), daemon=True),
        threading.Thread(target=pump, args=(proc.stderr, on_stderr, stderr_lines), daemon=True),
    ]
    for thread in threads:
        thread.start()
    code = proc.wait()
    for thread in threads:
        thread.join(timeout=2)
    CURRENT["proc"] = None
    return code, stdout_lines, stderr_lines


def run_quiet(cmd, timeout=15):
    try:
        result = subprocess.run(
            [str(part) for part in cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode, (result.stdout or "").strip(), (result.stderr or "").strip()
    except Exception as exc:
        return 127, "", str(exc)


def first_line(text):
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line
    return ""


def find_binary(name, configured=""):
    if configured:
        path = Path(configured).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return shutil.which(name)


# ---------------------------------------------------------------- config

def load_config(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def cfg_str(cfg, key, default=""):
    value = cfg.get(key, default)
    if value is None:
        return default
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def cfg_int(cfg, key, default):
    try:
        return int(float(cfg.get(key, default)))
    except (TypeError, ValueError):
        return default


def cfg_bool(cfg, key, default=False):
    value = cfg.get(key, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def job_dir(cfg):
    path = Path(cfg["_meta"]["jobDir"]).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def source_path(cfg):
    raw = cfg_str(cfg, "video", "").strip()
    if not raw:
        fail("没有选择视频", code="missing_video")
    path = Path(raw).expanduser()
    if not path.is_file():
        fail("视频不存在：%s" % path, code="missing_video")
    return path


def output_dir(cfg, source):
    raw = cfg_str(cfg, "outputDir", "").strip()
    path = Path(raw).expanduser() if raw else source.parent
    try:
        path.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        fail("无法创建输出目录：%s" % exc, code="output_dir_failed", detail=str(path))
    if not path.is_dir():
        fail("输出目录不是目录：%s" % path, code="output_dir_failed")
    return path


def target_format(cfg):
    value = cfg_str(cfg, "format", "mp4").lower()
    if value not in FORMAT_EXTS:
        fail("不支持的封装格式：%s" % value, code="unsupported_format")
    return value


def quality_value(cfg):
    return max(1, min(100, cfg_int(cfg, "quality", 80)))


def audio_bitrate(cfg):
    return max(64, min(512, cfg_int(cfg, "audioBitrate", 192)))


# ---------------------------------------------------------------- probe

def parse_rate(value):
    if not value or value in ("0/0", "N/A"):
        return 0.0
    if "/" in value:
        try:
            num, den = value.split("/", 1)
            return float(num) / float(den)
        except Exception:
            return 0.0
    try:
        return float(value)
    except Exception:
        return 0.0


def probe_video(path, cfg):
    ffprobe = find_binary("ffprobe", cfg_str(cfg, "ffprobePath", ""))
    if not ffprobe:
        fail("未找到 ffprobe", code="missing_ffprobe",
             detail="brew install ffmpeg")
    code, out, err = run_quiet([
        ffprobe, "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", str(path),
    ], timeout=60)
    if code != 0:
        fail("ffprobe 读取失败", code="probe_failed",
             detail="\n".join((err or out).splitlines()[-15:]))
    try:
        data = json.loads("\n".join(out.splitlines()))
    except Exception as exc:
        fail("无法解析 ffprobe 输出：%s" % exc, code="probe_failed")

    streams = data.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    if not video:
        fail("输入文件没有视频流", code="no_video")
    audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
    subtitle_count = len([s for s in streams if s.get("codec_type") == "subtitle"])

    width = int(video.get("width") or 0)
    height = int(video.get("height") or 0)
    if width <= 0 or height <= 0:
        fail("无法读取视频尺寸", code="probe_failed")

    rotation = 0
    for item in video.get("side_data_list") or []:
        if "rotation" in item:
            try:
                rotation = int(float(item["rotation"]))
            except Exception:
                rotation = 0
    tags = video.get("tags") or {}
    if not rotation and tags.get("rotate"):
        try:
            rotation = int(float(tags["rotate"]))
        except Exception:
            rotation = 0
    display_w, display_h = width, height
    if abs(rotation) % 180 == 90:
        display_w, display_h = height, width

    duration = 0.0
    for raw in (data.get("format", {}).get("duration"), video.get("duration")):
        try:
            duration = float(raw)
            if duration > 0:
                break
        except (TypeError, ValueError):
            continue

    info = {
        "width": width,
        "height": height,
        "display_width": display_w,
        "display_height": display_h,
        "rotation": rotation,
        "duration": duration,
        "video_codec": str(video.get("codec_name") or ""),
        "pix_fmt": str(video.get("pix_fmt") or ""),
        "fps": parse_rate(video.get("avg_frame_rate") or video.get("r_frame_rate")),
        "has_audio": bool(audio_streams),
        "audio_codec": str(audio_streams[0].get("codec_name") or "") if audio_streams else "",
        "audio_channels": int(audio_streams[0].get("channels") or 0) if audio_streams else 0,
        "audio_count": len(audio_streams),
        "subtitle_count": subtitle_count,
        "format_name": str(data.get("format", {}).get("format_name") or ""),
        "size": int(data.get("format", {}).get("size") or 0),
    }
    log("视频：%s" % path.name)
    log("时长：%s" % format_duration(info["duration"]))
    log("画面：%dx%d%s" % (
        display_w, display_h,
        " · %.2f fps" % info["fps"] if info["fps"] else "",
    ))
    log("源编码：%s%s" % (
        info["video_codec"] or "?",
        " / " + info["audio_codec"] if info["has_audio"] else " / 无音频",
    ))
    if subtitle_count:
        log("检测到 %d 条字幕；重编码模式会丢弃字幕（复制流模式保留）" % subtitle_count,
            level="warn")
    if info["audio_count"] > 1:
        log("检测到 %d 条音轨；重编码模式只保留首条（复制流模式保留全部）"
            % info["audio_count"], level="warn")
    return info


def format_duration(seconds):
    if not seconds or seconds <= 0:
        return "未知"
    total = int(round(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return "%d:%02d:%02d" % (hours, minutes, secs)
    return "%d:%02d" % (minutes, secs)


# ---------------------------------------------------------------- validation

def validate_target(cfg, info):
    fmt = target_format(cfg)
    video_codec = cfg_str(cfg, "videoCodec", "h264").lower()
    audio_codec = cfg_str(cfg, "audioCodec", "aac").lower()
    if video_codec not in VIDEO_CODECS:
        fail("不支持的视频编码：%s" % video_codec, code="unsupported_video_codec")
    if audio_codec not in AUDIO_CODECS:
        fail("不支持的音频编码：%s" % audio_codec, code="unsupported_audio_codec")

    format_name = fmt
    if format_name == "gif":
        # GIF 不支持音频和普通编码参数。
        if audio_codec != "none":
            log("GIF 没有音频，已忽略音频设置", level="warn")
        audio_codec = "none"
        video_codec = "gif"
    else:
        allowed_video = CONTAINER_VIDEO[format_name]
        actual_video = info["video_codec"] if video_codec == "copy" else video_codec
        if actual_video not in allowed_video:
            fail(
                "%s 不支持视频编码 %s" % (FORMAT_LABELS[format_name], VIDEO_LABELS.get(video_codec, video_codec)),
                code="incompatible_codec",
                detail="可选：%s" % " / ".join(sorted(VIDEO_LABELS.get(v, v) for v in allowed_video)),
            )

        allowed_audio = CONTAINER_AUDIO[format_name]
        if audio_codec not in ("none", "copy"):
            actual_audio = AUDIO_CONTAINER_NAMES.get(audio_codec, audio_codec)
            if actual_audio not in allowed_audio:
                fail(
                    "%s 不支持音频编码 %s" % (FORMAT_LABELS[format_name], AUDIO_LABELS.get(audio_codec, audio_codec)),
                    code="incompatible_audio",
                    detail="可选：%s" % " / ".join(sorted(AUDIO_LABELS.get(v, v) for v in allowed_audio)),
                )
        elif audio_codec == "copy" and info["has_audio"]:
            actual_audio = info["audio_codec"]
            if actual_audio not in allowed_audio:
                fail(
                    "%s 不支持复制源音频编码 %s" % (
                        FORMAT_LABELS[format_name], actual_audio or "未知",
                    ),
                    code="incompatible_audio",
                    detail="请改为 AAC / Opus / MP3 等重编码，或改用 MKV。",
                )

        if video_codec == "copy":
            if cfg_str(cfg, "resolution", "original") != "original":
                fail("复制视频流时不能修改分辨率", code="copy_with_resize")
            if cfg_str(cfg, "fps", "original") != "original":
                fail("复制视频流时不能修改帧率", code="copy_with_fps")

    return {
        "format": fmt,
        "video_codec": video_codec,
        "audio_codec": audio_codec,
        "quality": quality_value(cfg),
        "resolution": cfg_str(cfg, "resolution", "original"),
        "fps": cfg_str(cfg, "fps", "original"),
        "audio_bitrate": audio_bitrate(cfg),
    }


# ---------------------------------------------------------------- dimensions

def even(value):
    value = max(2, int(value))
    return value if value % 2 == 0 else value - 1


def target_dimensions(info, resolution):
    if resolution == "original" or resolution not in RESOLUTION_HEIGHTS:
        return None
    max_height = RESOLUTION_HEIGHTS[resolution]
    width = info["display_width"]
    height = info["display_height"]
    if height <= max_height:
        return None
    target_h = max_height
    target_w = int(round(width * target_h / float(height)))
    return even(target_w), even(target_h)


def target_fps(settings, info):
    if settings["format"] == "gif":
        return FPS_VALUES.get(settings["fps"], 12)
    if settings["fps"] == "original":
        return None
    return FPS_VALUES.get(settings["fps"])


# ---------------------------------------------------------------- encoder options

def crf_for(codec, quality):
    if codec == "h264":
        return max(14, min(36, int(round(36 - 22 * quality / 100.0))))
    if codec == "hevc":
        return max(14, min(38, int(round(38 - 24 * quality / 100.0))))
    if codec == "av1":
        return max(18, min(45, int(round(45 - 25 * quality / 100.0))))
    if codec == "vp9":
        return max(18, min(45, int(round(45 - 25 * quality / 100.0))))
    return 0


def video_arguments(settings, info):
    codec = settings["video_codec"]
    if codec == "copy":
        return ["-c:v", "copy"]
    if codec == "prores":
        return [
            "-c:v", "prores_ks",
            "-profile:v", "3",
            "-pix_fmt", "yuv422p10le",
        ]
    if codec == "vp9":
        return [
            "-c:v", "libvpx-vp9",
            "-crf", str(crf_for(codec, settings["quality"])),
            "-b:v", "0",
            "-row-mt", "1",
            "-deadline", "good",
            "-cpu-used", "2",
            "-pix_fmt", "yuv420p",
        ]
    if codec == "av1":
        return [
            "-c:v", "libsvtav1",
            "-preset", "6",
            "-crf", str(crf_for(codec, settings["quality"])),
            "-pix_fmt", "yuv420p",
        ]
    if codec == "hevc":
        args = [
            "-c:v", "libx265",
            "-preset", "medium",
            "-crf", str(crf_for(codec, settings["quality"])),
            "-pix_fmt", "yuv420p",
        ]
        if settings["format"] in ("mp4", "mov"):
            args += ["-tag:v", "hvc1"]
        return args
    return [
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", str(crf_for("h264", settings["quality"])),
        "-pix_fmt", "yuv420p",
    ]


def audio_arguments(settings, info):
    codec = settings["audio_codec"]
    if codec == "none" or not info["has_audio"]:
        return ["-an"]
    if codec == "copy":
        return ["-c:a", "copy"]
    bitrate = str(settings["audio_bitrate"]) + "k"
    if codec == "aac":
        return ["-c:a", "aac", "-b:a", bitrate]
    if codec == "opus":
        return ["-c:a", "libopus", "-b:a", bitrate]
    if codec == "mp3":
        return ["-c:a", "libmp3lame", "-b:a", bitrate]
    if codec == "flac":
        return ["-c:a", "flac", "-compression_level", "8"]
    if codec == "alac":
        return ["-c:a", "alac"]
    if codec == "pcm":
        return ["-c:a", "pcm_s16le"]
    return ["-an"]


def build_filter(settings, info):
    if settings["format"] == "gif":
        fps = target_fps(settings, info) or 12
        parts = ["fps=%d" % fps]
        dims = target_dimensions(info, settings["resolution"])
        if dims:
            parts.append("scale=%d:%d:flags=lanczos" % dims)
        colors = max(32, min(256, int(round(settings["quality"] * 2.56))))
        parts.append(
            "split[a][b];[a]palettegen=max_colors=%d:stats_mode=diff[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=5" % colors
        )
        return ",".join(parts), fps

    parts = []
    dims = target_dimensions(info, settings["resolution"])
    if dims:
        parts.append("scale=%d:%d:flags=lanczos" % dims)
    fps = target_fps(settings, info)
    if fps:
        parts.append("fps=%d" % fps)
    return (",".join(parts) if parts else None), fps


# ---------------------------------------------------------------- output

def make_output_path(source, directory, fmt, conflict):
    ext = FORMAT_EXTS[fmt]
    candidate = directory / (source.stem + "." + ext)
    if not candidate.exists():
        return candidate
    if conflict == "overwrite":
        return candidate
    if conflict == "fail":
        fail("目标文件已存在：%s" % candidate, code="output_exists")
    index = 1
    while True:
        candidate = directory / ("%s-%d.%s" % (source.stem, index, ext))
        if not candidate.exists():
            return candidate
        index += 1


def temp_target_path(directory, fmt):
    return directory / (".mct-video-%s.%s" % (uuid.uuid4().hex, FORMAT_EXTS[fmt]))


# ---------------------------------------------------------------- run

def run(cfg):
    install_signals()
    if "_meta" not in cfg:
        fail("config 缺少 _meta", code="bad_config")
    source = source_path(cfg)
    info = probe_video(source, cfg)
    settings = validate_target(cfg, info)
    fmt = settings["format"]
    destination_dir = output_dir(cfg, source)
    destination = make_output_path(
        source, destination_dir, fmt, cfg_str(cfg, "conflict", "rename"),
    )
    temp = temp_target_path(destination_dir, fmt)
    duration = info["duration"]
    ffmpeg = find_binary("ffmpeg", cfg_str(cfg, "ffmpegPath", ""))
    if not ffmpeg:
        fail("未找到 ffmpeg", code="missing_ffmpeg",
             detail="brew install ffmpeg")

    log("封装：%s" % FORMAT_LABELS[fmt])
    log("视频编码：%s%s" % (
        VIDEO_LABELS.get(settings["video_codec"], settings["video_codec"]),
        " · CRF %d" % crf_for(settings["video_codec"], settings["quality"])
        if settings["video_codec"] not in ("copy", "gif", "prores") else "",
    ))
    log("音频编码：%s" % AUDIO_LABELS.get(settings["audio_codec"], settings["audio_codec"]))
    dims = target_dimensions(info, settings["resolution"])
    if dims:
        log("输出尺寸：%dx%d" % dims)
    fps = target_fps(settings, info)
    if fps:
        log("输出帧率：%d fps" % fps)

    step_event("convert", "转换视频", "running")
    progress(0.03, "convert", "准备编码")

    try:
        filter_spec, _ = build_filter(settings, info)
        cmd = [
            ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
            "-progress", "pipe:1", "-nostats", "-i", str(source),
        ]

        copy_all = (
            settings["video_codec"] == "copy"
            and settings["audio_codec"] == "copy"
            and cfg_bool(cfg, "preserveMetadata", True)
        )
        if copy_all and info["subtitle_count"] and fmt != "mkv":
            fail(
                "复制全部流会保留字幕，但 %s 不支持当前字幕流" % FORMAT_LABELS[fmt],
                code="incompatible_subtitles",
                detail="请改用 MKV；或关闭「保留元数据与章节」后复制，或改为重编码丢弃字幕。",
            )
        if copy_all:
            cmd += ["-map", "0", "-c", "copy"]
        else:
            if fmt == "gif":
                cmd += ["-map", "0:v:0"]
            else:
                cmd += ["-map", "0:v:0", "-map", "0:a:0?"]
            if filter_spec:
                cmd += ["-vf", filter_spec]
            if fmt == "gif":
                cmd += ["-c:v", "gif", "-an"]
            else:
                cmd += video_arguments(settings, info)
                cmd += audio_arguments(settings, info)

        if cfg_bool(cfg, "preserveMetadata", True):
            cmd += ["-map_metadata", "0", "-map_chapters", "0"]
        else:
            cmd += ["-map_metadata", "-1", "-map_chapters", "-1"]

        if fmt in ("mp4", "mov"):
            cmd += ["-movflags", "+faststart"]
        if fmt == "gif":
            cmd += ["-loop", "0", "-f", "gif"]
        else:
            cmd += ["-f", "matroska" if fmt == "mkv" else fmt]
        cmd += [str(temp)]

        last_fraction = {"value": 0.0}

        def on_stdout(line):
            seconds = None
            if line.startswith("out_time_us="):
                try:
                    seconds = int(line.split("=", 1)[1]) / 1_000_000.0
                except Exception:
                    seconds = None
            elif line.startswith("out_time_ms="):
                try:
                    seconds = int(line.split("=", 1)[1]) / 1_000_000.0
                except Exception:
                    seconds = None
            elif line.startswith("out_time="):
                seconds = parse_timecode(line.split("=", 1)[1])
            if seconds is None or duration <= 0:
                return
            fraction = min(0.95, max(0.03, seconds / duration))
            if fraction - last_fraction["value"] >= 0.01:
                last_fraction["value"] = fraction
                progress(fraction, "convert", "编码 %d%%" % int(fraction * 100))

        code, out, err = run_process(cmd, on_stdout=on_stdout)
        if code != 0 or not temp.is_file() or temp.stat().st_size == 0:
            fail("视频转换失败", code="encode_failed",
                 detail="\n".join(err[-30:]))

        progress(0.96, "convert", "写入成品")
        if destination.exists() and cfg_str(cfg, "conflict", "rename") == "fail":
            fail("目标文件已存在：%s" % destination, code="output_exists")
        os.replace(str(temp), str(destination))

        size_text = format_bytes(destination.stat().st_size)
        summary = "%s → %s · %s%s%s · %s" % (
            source.name,
            FORMAT_LABELS[fmt],
            VIDEO_LABELS.get(settings["video_codec"], settings["video_codec"]),
            " / " + AUDIO_LABELS.get(settings["audio_codec"], settings["audio_codec"])
            if info["has_audio"] or settings["audio_codec"] == "none" else "",
            " · %dx%d" % (dims[0], dims[1]) if dims else "",
            size_text,
        )
        log("完成：%s" % destination)
        artifact("video", destination, "转换后的视频", "video")
        progress(1.0, "deliver", "完成")
        step_event("convert", "转换视频", "done")
        step_event("deliver", "交付", "done")
        emit(
            type="result",
            ok=True,
            summary=summary,
            artifacts=[
                {"id": "video", "kind": "video", "path": str(destination), "label": "转换后的视频"}
            ],
        )
        return 0
    except SystemExit:
        raise
    except Exception as exc:
        fail("视频转换失败：%s" % exc, code="encode_failed")
    finally:
        try:
            if temp.exists():
                temp.unlink()
        except Exception:
            pass


def parse_timecode(value):
    value = value.strip()
    match = re.match(r"^(\d+):(\d+):(\d+(?:\.\d+)?)$", value)
    if not match:
        return 0.0
    return int(match.group(1)) * 3600 + int(match.group(2)) * 60 + float(match.group(3))


def format_bytes(size):
    value = float(size)
    if value < 1024:
        return "%.0f B" % value
    if value < 1024 * 1024:
        return "%.1f KB" % (value / 1024)
    if value < 1024 * 1024 * 1024:
        return "%.1f MB" % (value / 1024 / 1024)
    return "%.2f GB" % (value / 1024 / 1024 / 1024)


# ---------------------------------------------------------------- doctor

def add_check(checks, check_id, label, status, detail="", fix_command=None, fixable=False):
    checks.append({
        "id": check_id,
        "label": label,
        "status": status,
        "detail": detail,
        "fixCommand": fix_command,
        "fixable": fixable,
    })


def collect_checks(cfg):
    checks = []
    add_check(checks, "python", "Python", "ok", "%s · %s" % (
        "%d.%d.%d" % sys.version_info[:3], sys.executable,
    ))

    ffmpeg = find_binary("ffmpeg", cfg_str(cfg, "ffmpegPath", ""))
    if ffmpeg:
        code, out, err = run_quiet([ffmpeg, "-version"])
        add_check(checks, "ffmpeg", "ffmpeg", "ok", first_line(out),
                  "brew install ffmpeg", True)
        code, out, err = run_quiet([ffmpeg, "-hide_banner", "-encoders"])
        encoders = set()
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("V") or len(parts) >= 2 and parts[0].startswith("A"):
                encoders.add(parts[1])
        required = {
            "libx264": "H.264",
            "libx265": "H.265",
            "libsvtav1": "AV1",
            "libvpx-vp9": "VP9",
            "prores_ks": "ProRes",
            "aac": "AAC",
            "libopus": "Opus",
            "libmp3lame": "MP3",
        }
        missing = [label for name, label in required.items() if name not in encoders]
        add_check(
            checks, "encoders", "视频/音频编码器",
            "ok" if not missing else "warn",
            "完整" if not missing else "缺失：" + "、".join(missing),
            "brew install ffmpeg" if missing else None,
            bool(missing),
        )
    else:
        add_check(checks, "ffmpeg", "ffmpeg", "fail", "未找到", "brew install ffmpeg", True)
        add_check(checks, "encoders", "视频/音频编码器", "fail", "ffmpeg 未安装")

    ffprobe = find_binary("ffprobe", cfg_str(cfg, "ffprobePath", ""))
    if ffprobe:
        code, out, err = run_quiet([ffprobe, "-version"])
        add_check(checks, "ffprobe", "ffprobe", "ok", first_line(out),
                  "brew install ffmpeg", True)
    else:
        add_check(checks, "ffprobe", "ffprobe", "fail", "未找到", "brew install ffmpeg", True)

    try:
        job = job_dir(cfg)
        probe = job / ".write-test"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        add_check(checks, "jobdir", "任务目录可写", "ok", str(job))
    except Exception as exc:
        add_check(checks, "jobdir", "任务目录可写", "fail", str(exc))
    return checks


def doctor(cfg):
    checks = collect_checks(cfg)
    emit(type="env", checks=checks)
    missing = [c for c in checks if c["status"] == "fail"]
    emit(type="result", ok=True, summary="环境检测完成，缺失 %d 项" % len(missing))
    return 0


# ---------------------------------------------------------------- setup

def run_brew_install(package, label):
    brew = shutil.which("brew")
    if not brew:
        fail("未找到 Homebrew，无法自动安装 %s" % label, code="no_brew",
             detail="请先安装 Homebrew：https://brew.sh")
    log("安装 %s（brew install %s）…" % (label, package))
    code, out, err = run_process([brew, "install", package])
    if code != 0:
        fail("安装 %s 失败" % label, code="brew_failed",
             detail="\n".join(err[-20:]))
    log("%s 安装完成" % label)


def setup(cfg):
    install_signals()
    step_event("setup", "环境修复", "running")
    checks = {c["id"]: c for c in collect_checks(cfg)}
    if checks.get("ffmpeg", {}).get("status") == "fail" or checks.get("ffprobe", {}).get("status") == "fail":
        run_brew_install("ffmpeg", "ffmpeg / ffprobe")
    checks = collect_checks(cfg)
    emit(type="env", checks=checks)
    step_event("setup", "环境修复", "done")
    remaining = [c for c in checks if c["status"] == "fail"]
    emit(type="result", ok=not remaining, summary="修复完成，仍缺失 %d 项" % len(remaining))
    return 0


# ---------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run", "doctor", "setup"])
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = load_config(args.config)
    try:
        if args.command == "doctor":
            return doctor(cfg)
        if args.command == "setup":
            return setup(cfg)
        return run(cfg)
    except SystemExit:
        raise
    except Exception as exc:
        fail("视频工具异常：%s" % exc, code="internal_error")


if __name__ == "__main__":
    raise SystemExit(main())
