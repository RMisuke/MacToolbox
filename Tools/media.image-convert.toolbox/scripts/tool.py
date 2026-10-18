#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MacToolbox 图片格式转换（Tool Protocol 实现）。

设计原则：
- 像素转换用 ffmpeg / cwebp / avifenc / sips / cjxl；
- EXIF/ICC 用 exiftool 单独复制，避免把元数据能力和编码器绑死；
- HEIC / AVIF / SVG / RAW 优先走 macOS 原生 sips，保留 alpha；
- 输出先写临时文件，成功后再原子替换，覆盖原图也不会产生半成品。
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

ANIMATED_INPUT_EXTS = {"gif", "webp", "apng"}
NATIVE_INPUT_EXTS = {
    "heic", "heif", "avif", "svg", "pdf", "icns",
    "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw",
}
META_OUTPUT_EXTS = {"jpg", "jpeg", "png", "tiff", "webp", "avif", "heic", "jxl"}
TARGET_EXTS = {
    "jpg": "jpg",
    "jpeg": "jpg",
    "png": "png",
    "webp": "webp",
    "avif": "avif",
    "heic": "heic",
    "tiff": "tiff",
    "tif": "tiff",
    "bmp": "bmp",
    "gif": "gif",
    "ico": "ico",
    "apng": "apng",
    "jxl": "jxl",
    "qoi": "qoi",
    "jp2": "jp2",
    "exr": "exr",
    "tga": "tga",
}
FORMAT_ALIASES = {"jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "heif": "heic"}


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

def run_process(cmd, cwd=None, env=None, log_cmd=True, on_stdout=None, on_stderr=None):
    if log_cmd:
        log("$ " + subprocess.list2cmdline([str(part) for part in cmd]))
    proc = subprocess.Popen(
        [str(part) for part in cmd],
        cwd=cwd,
        env=env,
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
    value = cfg_str(cfg, "image", "").strip()
    if not value:
        fail("没有选择图片", code="missing_image")
    path = Path(value).expanduser()
    if not path.is_file():
        fail("图片不存在：%s" % path, code="missing_image")
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
    raw = cfg_str(cfg, "format", "webp").strip().lower()
    raw = FORMAT_ALIASES.get(raw, raw)
    if raw not in TARGET_EXTS:
        fail("不支持的输出格式：%s" % raw, code="unsupported_format")
    return raw


def source_ext(path):
    ext = path.suffix.lower().lstrip(".")
    return FORMAT_ALIASES.get(ext, ext)


def format_quality(cfg):
    quality = cfg_int(cfg, "quality", 85)
    return max(1, min(100, quality))


def max_size(cfg):
    value = cfg_int(cfg, "maxSize", 0)
    return max(0, min(20000, value))


# ---------------------------------------------------------------- probe

def parse_sips_info(path, sips):
    code, out, err = run_quiet([sips, "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", "-g", "format", str(path)])
    if code != 0:
        return {}
    info = {}
    for line in out.splitlines():
        match = re.match(r"^\s*([A-Za-z]+):\s*(.*)$", line)
        if match:
            info[match.group(1)] = match.group(2).strip()
    return info


def probe_frames(path, ffprobe):
    cmd = [
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-count_frames", "-show_entries", "stream=nb_read_frames,nb_frames",
        "-of", "json", str(path),
    ]
    code, out, err = run_quiet(cmd)
    if code != 0:
        return 0
    try:
        data = json.loads("\n".join(out.splitlines()))
        stream = (data.get("streams") or [{}])[0]
        for key in ("nb_read_frames", "nb_frames"):
            raw = stream.get(key)
            if raw and str(raw).isdigit():
                return int(raw)
    except Exception:
        pass
    return 0


def probe_orientation(path, cfg):
    """EXIF orientation 的正交旋转值；ffprobe 对 JPEG 不一定暴露。"""
    exiftool = find_binary("exiftool", cfg_str(cfg, "exiftoolPath", ""))
    if not exiftool:
        return 0
    code, out, err = run_quiet([exiftool, "-s3", "-Orientation", "-n", str(path)])
    if code != 0:
        return 0
    value = first_line(out)
    try:
        return int(float(value))
    except Exception:
        return 0


def probe_image(path, cfg):
    ffprobe = find_binary("ffprobe", cfg_str(cfg, "ffprobePath", ""))
    sips = shutil.which("sips")
    ext = source_ext(path)
    stream = {}
    if ffprobe:
        cmd = [
            ffprobe, "-v", "error", "-select_streams", "v:0",
            "-show_entries",
            "stream=codec_name,width,height,pix_fmt,nb_frames:stream_side_data=rotation:format=format_name,duration",
            "-of", "json", str(path),
        ]
        code, out, err = run_quiet(cmd)
        if code == 0:
            try:
                data = json.loads("\n".join(out.splitlines()))
                stream = (data.get("streams") or [{}])[0]
            except Exception:
                stream = {}
    sips_info = parse_sips_info(path, sips) if sips else {}

    width = 0
    height = 0
    try:
        width = int(stream.get("width") or 0)
        height = int(stream.get("height") or 0)
    except Exception:
        width, height = 0, 0
    if (width <= 0 or height <= 0) and sips_info:
        try:
            width = int(sips_info.get("pixelWidth") or 0)
            height = int(sips_info.get("pixelHeight") or 0)
        except Exception:
            pass
    if (width <= 0 or height <= 0) and sips and ext in NATIVE_INPUT_EXTS:
        # SVG / PDF 等格式 sips -g 可能读不到尺寸，但可以栅格化。
        preview = job_dir(cfg) / (".probe-%s.png" % uuid.uuid4().hex)
        code, out, err = run_quiet([
            sips, "-s", "format", "png", str(path), "--out", str(preview),
        ])
        if code == 0 and preview.is_file():
            preview_info = parse_sips_info(preview, sips)
            if not sips_info:
                sips_info = preview_info
            try:
                width = int(preview_info.get("pixelWidth") or 0)
                height = int(preview_info.get("pixelHeight") or 0)
            except Exception:
                pass
            try:
                preview.unlink(missing_ok=True)
            except Exception:
                pass
    if width <= 0 or height <= 0:
        fail("无法读取图片尺寸：%s" % path.name, code="probe_failed",
             detail="ffprobe 和 sips 都未能解析这个文件")

    rotation = 0
    for item in stream.get("side_data_list") or []:
        if "rotation" in item:
            try:
                rotation = int(float(item["rotation"]))
            except Exception:
                rotation = 0
    tags = stream.get("tags") or {}
    if not rotation and tags.get("rotate"):
        try:
            rotation = int(float(tags["rotate"]))
        except Exception:
            rotation = 0
    # JPEG 的 EXIF orientation 在 ffprobe 9 里不一定出现在 side_data；
    # 用 exiftool 读一次，保证 90/270 度的缩放尺寸和元数据尺寸正确。
    exif_orientation = probe_orientation(path, cfg)
    if not rotation and exif_orientation in (5, 6, 7, 8):
        rotation = 90 if exif_orientation in (5, 6) else 270
    display_w, display_h = width, height
    if abs(rotation) % 180 == 90:
        display_w, display_h = height, width

    pix_fmt = str(stream.get("pix_fmt") or "")
    has_alpha = str(sips_info.get("hasAlpha", "")).lower() == "yes"
    if not has_alpha:
        # pal8 只说明是索引色，不代表一定有透明；以 sips 的 hasAlpha 为准。
        has_alpha = "a" in pix_fmt and pix_fmt != "pal8"
    if ext in ANIMATED_INPUT_EXTS:
        has_alpha = has_alpha or str(sips_info.get("hasAlpha", "")).lower() == "yes"

    frames = 1
    if ext in ANIMATED_INPUT_EXTS:
        try:
            frames = int(stream.get("nb_frames") or 0)
        except Exception:
            frames = 0
        if frames <= 0 and ffprobe:
            frames = probe_frames(path, ffprobe)
        if frames <= 0:
            frames = 1
    is_animated = frames > 1

    if not width or not height:
        fail("图片尺寸无效", code="probe_failed")

    info = {
        "width": width,
        "height": height,
        "display_width": display_w,
        "display_height": display_h,
        "rotation": rotation,
        "pix_fmt": pix_fmt,
        "has_alpha": has_alpha,
        "frames": frames,
        "is_animated": is_animated,
        "ext": ext,
        "format_name": str(stream.get("format_name") or ""),
        "sips_format": sips_info.get("format", ""),
    }
    log("图片：%s" % path.name)
    log("尺寸：%dx%d%s" % (
        display_w, display_h, " · alpha" if has_alpha else ""
    ))
    if is_animated:
        log("检测到动图（%d 帧）；静态输出只取第一帧" % frames, level="warn")
    return info


# ---------------------------------------------------------------- dimensions

def fit_dimensions(width, height, limit):
    if limit <= 0 or max(width, height) <= limit:
        return width, height
    ratio = limit / float(max(width, height))
    return max(1, int(round(width * ratio))), max(1, int(round(height * ratio)))


def output_dimensions(info, target, limit):
    if target == "ico":
        return 256, 256
    return fit_dimensions(info["display_width"], info["display_height"], limit)


# ---------------------------------------------------------------- normalize

def normalize_to_png(source, info, cfg, temp_png, dims):
    """把各种输入统一成 PNG；保留 alpha，按需缩放到 dims。"""
    width, height = dims
    ext = info["ext"]
    sips = shutil.which("sips")
    ffmpeg = find_binary("ffmpeg", cfg_str(cfg, "ffmpegPath", ""))

    if ext in NATIVE_INPUT_EXTS:
        if not sips:
            fail("缺少 sips，无法解码 %s" % ext.upper(), code="missing_sips")
        if ext == "pdf":
            log("PDF 仅取第一页", level="warn")
        cmd = [sips, "-s", "format", "png"]
        if (width, height) != (info["display_width"], info["display_height"]):
            # sips -z 的顺序是 height width
            cmd += ["-z", str(height), str(width)]
        cmd += [str(source), "--out", str(temp_png)]
        code, out, err = run_process(cmd)
        if code != 0 or not temp_png.is_file():
            fail("sips 解码失败", code="native_decode_failed",
                 detail="\n".join((err or out)[-15:]))
        return temp_png

    if ext == "jxl":
        djxl = find_binary("djxl", cfg_str(cfg, "djxlPath", ""))
        if not djxl:
            fail("输入 JPEG XL 需要 djxl", code="missing_djxl",
                 detail="brew install jpeg-xl")
        decoded = temp_png.with_name(temp_png.stem + "-jxl.png")
        code, out, err = run_process([djxl, str(source), str(decoded), "--quiet"])
        if code != 0 or not decoded.is_file():
            fail("djxl 解码失败", code="jxl_decode_failed",
                 detail="\n".join((err or out)[-15:]))
        if (width, height) == (info["display_width"], info["display_height"]):
            shutil.move(str(decoded), str(temp_png))
        else:
            if not sips:
                fail("缺少 sips，无法缩放 JPEG XL", code="missing_sips")
            code, out, err = run_process([
                sips, "-s", "format", "png", "-z", str(height), str(width),
                str(decoded), "--out", str(temp_png),
            ])
            try:
                decoded.unlink(missing_ok=True)
            except Exception:
                pass
            if code != 0 or not temp_png.is_file():
                fail("sips 缩放 JPEG XL 失败", code="native_decode_failed",
                     detail="\n".join((err or out)[-15:]))
        return temp_png

    if not ffmpeg:
        fail("未找到 ffmpeg", code="missing_ffmpeg",
             detail="brew install ffmpeg，或运行环境修复")

    cmd = [
        ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(source), "-frames:v", "1",
    ]
    if (width, height) != (info["display_width"], info["display_height"]):
        cmd += ["-vf", "scale=%d:%d:flags=lanczos" % (width, height)]
    cmd += ["-pix_fmt", "rgba", str(temp_png)]
    code, out, err = run_process(cmd)
    if code != 0 or not temp_png.is_file():
        fail("归一化失败", code="decode_failed",
             detail="\n".join(err[-15:]))
    return temp_png


# ---------------------------------------------------------------- ffmpeg encode

def flatten_filter(background):
    value = "255" if background == "white" else "0"
    return (
        "format=rgba,geq="
        "r='r(X,Y)*alpha(X,Y)/255+%s*(1-alpha(X,Y)/255)':"
        "g='g(X,Y)*alpha(X,Y)/255+%s*(1-alpha(X,Y)/255)':"
        "b='b(X,Y)*alpha(X,Y)/255+%s*(1-alpha(X,Y)/255)':a=255"
    ) % (value, value, value)


def ffmpeg_encode(input_path, target, output, dims, quality, background,
                  has_alpha, resize, animated, ffmpeg_path=""):
    ffmpeg = find_binary("ffmpeg", ffmpeg_path)
    if not ffmpeg:
        fail("未找到 ffmpeg", code="missing_ffmpeg")

    width, height = dims
    filters = []
    if target == "ico":
        filters.append(
            "scale=256:256:force_original_aspect_ratio=decrease:flags=lanczos,"
            "pad=256:256:(ow-iw)/2:(oh-ih)/2:color=white"
        )
    elif resize and (width, height) != (0, 0):
        filters.append("scale=%d:%d:flags=lanczos" % (width, height))

    if target in ("jpg", "bmp") and has_alpha:
        filters.append(flatten_filter(background))

    if target == "gif":
        if has_alpha:
            filters.append(
                "split[a][b];[a]palettegen=reserve_transparent=1:stats_mode=full[p];"
                "[b][p]paletteuse=alpha_threshold=128"
            )
        else:
            filters.append(
                "split[a][b];[a]palettegen=stats_mode=full[p];"
                "[b][p]paletteuse"
            )

    cmd = [ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", str(input_path)]
    if not (animated and target in ("gif", "apng")):
        cmd += ["-frames:v", "1"]
    if filters:
        cmd += ["-vf", ",".join(filters)]

    if target == "jpg":
        q = max(2, min(31, int(round(31 - quality * 29 / 100.0))))
        cmd += ["-q:v", str(q), "-pix_fmt", "yuvj420p"]
    elif target == "png":
        cmd += ["-compression_level", "9"]
    elif target == "tiff":
        cmd += ["-compression_algo", "deflate"]
    elif target == "bmp":
        cmd += ["-pix_fmt", "bgr24"]
    elif target == "gif":
        cmd += ["-loop", "0"] if animated else []
    elif target == "apng":
        cmd += ["-f", "apng"]
    elif target == "ico":
        cmd += ["-f", "ico"]
    elif target == "qoi":
        cmd += ["-c:v", "qoi"]
    elif target in ("jp2", "j2k"):
        cmd += ["-c:v", "jpeg2000"]
    elif target == "exr":
        cmd += ["-c:v", "exr"]
    elif target == "tga":
        cmd += ["-c:v", "targa"]

    cmd += [str(output)]
    code, out, err = run_process(cmd)
    if code != 0 or not output.is_file() or output.stat().st_size == 0:
        fail("转换为 %s 失败" % target.upper(), code="convert_failed",
             detail="\n".join(err[-20:]))
    return output


# ---------------------------------------------------------------- specialized encodes

def encode_webp(source, info, cfg, output, dims):
    cwebp = find_binary("cwebp", cfg_str(cfg, "cwebpPath", ""))
    if not cwebp:
        fail("WebP 输出需要 cwebp", code="missing_cwebp",
             detail="brew install webp，或运行环境修复")

    quality = format_quality(cfg)
    ext = info["ext"]
    if ext == "gif" and info["is_animated"] and max_size(cfg) == 0:
        gif2webp = find_binary("gif2webp", "")
        if gif2webp:
            cmd = [gif2webp, "-m", "6", "-metadata", "all"]
            if quality >= 100:
                cmd.append("-lossless")
            else:
                cmd += ["-q", str(quality)]
            cmd += [str(source), "-o", str(output)]
            code, out, err = run_process(cmd)
            if code == 0 and output.is_file() and output.stat().st_size > 0:
                log("保留 GIF 动画")
                return output
            log("gif2webp 失败，回退第一帧：%s" % first_line("\n".join(err)), level="warn")

    normalized = output.with_name(".mct-normalized-%s.png" % uuid.uuid4().hex)
    normalize_to_png(source, info, cfg, normalized, dims)
    try:
        cmd = [cwebp, "-quiet", "-m", "6", "-metadata", "all", "-alpha_q", "100"]
        if quality >= 100:
            cmd.append("-lossless")
        else:
            cmd += ["-q", str(quality)]
        cmd += [str(normalized), "-o", str(output)]
        code, out, err = run_process(cmd)
        if code != 0 or not output.is_file() or output.stat().st_size == 0:
            fail("WebP 编码失败", code="webp_failed",
                 detail="\n".join(err[-20:]))
    finally:
        try:
            normalized.unlink(missing_ok=True)
        except Exception:
            pass
    return output


def encode_avif(source, info, cfg, output, dims):
    avifenc = find_binary("avifenc", cfg_str(cfg, "avifencPath", ""))
    normalized = output.with_name(".mct-normalized-%s.png" % uuid.uuid4().hex)
    normalize_to_png(source, info, cfg, normalized, dims)
    try:
        quality = format_quality(cfg)
        if avifenc:
            cmd = [
                avifenc, "-q", str(quality), "--qalpha", str(quality),
                "-s", "6", "-j", "all", str(normalized), str(output),
            ]
            code, out, err = run_process(cmd)
            if code != 0 or not output.is_file() or output.stat().st_size == 0:
                fail("AVIF 编码失败", code="avif_failed",
                     detail="\n".join(err[-20:]))
        else:
            sips = shutil.which("sips")
            if not sips:
                fail("AVIF 输出需要 avifenc 或 sips", code="missing_avif")
            code, out, err = run_process([
                sips, "-s", "format", "avif", "-s", "formatOptions", str(quality),
                str(normalized), "--out", str(output),
            ])
            if code != 0 or not output.is_file() or output.stat().st_size == 0:
                fail("sips AVIF 编码失败", code="avif_failed",
                     detail="\n".join((err or out)[-20:]))
    finally:
        try:
            normalized.unlink(missing_ok=True)
        except Exception:
            pass
    return output


def encode_heic(source, info, cfg, output, dims):
    sips = shutil.which("sips")
    if not sips:
        fail("HEIC 输出需要 macOS sips", code="missing_sips")
    normalized = output.with_name(".mct-normalized-%s.png" % uuid.uuid4().hex)
    normalize_to_png(source, info, cfg, normalized, dims)
    try:
        quality = format_quality(cfg)
        code, out, err = run_process([
            sips, "-s", "format", "heic", "-s", "formatOptions", str(quality),
            str(normalized), "--out", str(output),
        ])
        if code != 0 or not output.is_file() or output.stat().st_size == 0:
            fail("HEIC 编码失败", code="heic_failed",
                 detail="\n".join((err or out)[-20:]))
    finally:
        try:
            normalized.unlink(missing_ok=True)
        except Exception:
            pass
    return output


def encode_jxl(source, info, cfg, output, dims):
    cjxl = find_binary("cjxl", cfg_str(cfg, "cjxlPath", ""))
    if not cjxl:
        fail("JPEG XL 输出需要 cjxl", code="missing_cjxl",
             detail="brew install jpeg-xl，或运行环境修复")
    normalized = output.with_name(".mct-normalized-%s.png" % uuid.uuid4().hex)
    normalize_to_png(source, info, cfg, normalized, dims)
    try:
        quality = format_quality(cfg)
        cmd = [cjxl, str(normalized), str(output), "-q", str(quality), "-e", "7"]
        code, out, err = run_process(cmd)
        if code != 0 or not output.is_file() or output.stat().st_size == 0:
            fail("JPEG XL 编码失败", code="jxl_failed",
                 detail="\n".join(err[-20:]))
    finally:
        try:
            normalized.unlink(missing_ok=True)
        except Exception:
            pass
    return output


# ---------------------------------------------------------------- metadata

def copy_metadata(source, output, target, dims, cfg):
    if not cfg_bool(cfg, "preserveMetadata", True):
        return
    if target not in META_OUTPUT_EXTS:
        log("目标格式 %s 不支持 EXIF，跳过元数据复制" % target.upper(), level="warn")
        return
    exiftool = find_binary("exiftool", cfg_str(cfg, "exiftoolPath", ""))
    if not exiftool:
        log("未找到 exiftool，跳过 EXIF/ICC；brew install exiftool 可启用", level="warn")
        return

    width, height = dims
    cmd = [
        exiftool, "-m", "-q", "-q", "-overwrite_original",
        "-TagsFromFile", str(source),
        "-EXIF:all", "-GPS:all", "-XMP:all", "-IPTC:all", "-ICC_Profile",
        "-Orientation#=1",
        "-ExifImageWidth#=%d" % width,
        "-ExifImageHeight#=%d" % height,
        "-ThumbnailImage=", "-PreviewImage=",
        str(output),
    ]
    code, out, err = run_process(cmd)
    if code != 0:
        log("元数据复制失败（成品仍可用）：%s" % first_line("\n".join(err or out)),
            level="warn")
    else:
        log("已复制 EXIF / ICC（如源文件存在）")


# ---------------------------------------------------------------- output

def make_output_path(source, directory, target, conflict):
    ext = TARGET_EXTS[target]
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


def temp_target_path(directory, target):
    ext = TARGET_EXTS[target]
    return directory / (".mct-image-%s.%s" % (uuid.uuid4().hex, ext))


# ---------------------------------------------------------------- run

def run(cfg):
    install_signals()
    if "_meta" not in cfg:
        fail("config 缺少 _meta", code="bad_config")
    source = source_path(cfg)
    target = target_format(cfg)
    info = probe_image(source, cfg)
    limit = max_size(cfg)
    dims = output_dimensions(info, target, limit)
    destination_dir = output_dir(cfg, source)
    destination = make_output_path(source, destination_dir, target, cfg_str(cfg, "conflict", "rename"))
    temp = temp_target_path(destination_dir, target)

    log("输出：%s" % target.upper())
    log("目标尺寸：%dx%d" % dims)
    step_event("probe", "分析图片", "done")
    progress(0.08, "probe", "已读取图片信息")

    try:
        step_event("convert", "转换格式", "running")
        progress(0.15, "convert", "准备编码")

        # 专用编码器（cwebp / avifenc / sips / cjxl）自己负责归一化，
        # 这样可以避免 WebP/AVIF 路径重复解码。
        if target in ("webp", "avif", "heic", "jxl"):
            if target == "webp":
                encode_webp(source, info, cfg, temp, dims)
            elif target == "avif":
                encode_avif(source, info, cfg, temp, dims)
            elif target == "heic":
                encode_heic(source, info, cfg, temp, dims)
            else:
                encode_jxl(source, info, cfg, temp, dims)
        else:
            needs_native_decode = info["ext"] in NATIVE_INPUT_EXTS or info["ext"] == "jxl"
            if needs_native_decode:
                normalized = temp.with_suffix(".normalized.png")
                normalize_to_png(source, info, cfg, normalized, dims)
                input_path = normalized
                resized = False
            else:
                input_path = source
                resized = (dims != (info["display_width"], info["display_height"]))

            animated = info["is_animated"] and target in ("gif", "apng") and not needs_native_decode
            ffmpeg_encode(
                input_path, target, temp, dims, format_quality(cfg),
                cfg_str(cfg, "background", "white"), info["has_alpha"],
                resized, animated, cfg_str(cfg, "ffmpegPath", ""),
            )
            if needs_native_decode:
                try:
                    input_path.unlink(missing_ok=True)
                except Exception:
                    pass

        progress(0.72, "convert", "编码完成")
        step_event("convert", "转换格式", "done")

        if temp.is_file() and temp.stat().st_size > 0 and cfg_bool(cfg, "preserveMetadata", True):
            step_event("metadata", "复制 EXIF / ICC", "running")
            copy_metadata(source, temp, target, dims, cfg)
            progress(0.9, "metadata", "元数据处理完成")
            step_event("metadata", "复制 EXIF / ICC", "done")
        elif temp.is_file() and temp.stat().st_size > 0:
            progress(0.9, "convert", "未启用元数据复制")

        if not temp.is_file() or temp.stat().st_size == 0:
            fail("没有生成输出文件", code="missing_output")

        # 临时文件和目标在同一目录，os.replace 可以原子替换。
        if destination.exists() and cfg_str(cfg, "conflict", "rename") == "fail":
            fail("目标文件已存在：%s" % destination, code="output_exists")
        os.replace(str(temp), str(destination))

        size_text = "%.1f KB" % (destination.stat().st_size / 1024.0)
        summary = "%s → %s · %dx%d · %s" % (
            source.name, target.upper(), dims[0], dims[1], size_text,
        )
        log("完成：%s" % destination)
        artifact("image", destination, "转换后的图片", "image")
        progress(1.0, "deliver", "完成")
        step_event("deliver", "交付", "done")
        emit(
            type="result",
            ok=True,
            summary=summary,
            artifacts=[
                {"id": "image", "kind": "image", "path": str(destination), "label": "转换后的图片"}
            ],
        )
        return 0
    except SystemExit:
        raise
    except Exception as exc:
        fail("图片转换失败：%s" % exc, code="convert_failed")
    finally:
        try:
            if temp.exists():
                temp.unlink()
        except Exception:
            pass


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
        add_check(checks, "ffmpeg", "ffmpeg", "ok", first_line(out), "brew install ffmpeg", True)
    else:
        add_check(checks, "ffmpeg", "ffmpeg", "fail", "未找到", "brew install ffmpeg", True)

    ffprobe = find_binary("ffprobe", cfg_str(cfg, "ffprobePath", ""))
    if ffprobe:
        code, out, err = run_quiet([ffprobe, "-version"])
        add_check(checks, "ffprobe", "ffprobe", "ok", first_line(out), "brew install ffmpeg", True)
    else:
        add_check(checks, "ffprobe", "ffprobe", "fail", "未找到", "brew install ffmpeg", True)

    sips = shutil.which("sips")
    add_check(
        checks, "sips", "sips（macOS 原生）",
        "ok" if sips else "fail",
        sips or "未找到",
        "macOS 自带，无需安装",
        False,
    )

    cwebp = find_binary("cwebp", cfg_str(cfg, "cwebpPath", ""))
    if cwebp:
        code, out, err = run_quiet([cwebp, "-version"])
        add_check(checks, "cwebp", "cwebp", "ok", first_line(err or out), "brew install webp", True)
    else:
        add_check(checks, "cwebp", "cwebp", "fail", "WebP 输出需要", "brew install webp", True)

    gif2webp = find_binary("gif2webp", "")
    add_check(
        checks, "gif2webp", "gif2webp（可选）",
        "ok" if gif2webp else "warn",
        gif2webp or "缺失时动图回退第一帧",
        "brew install webp",
        bool(gif2webp),
    )

    avifenc = find_binary("avifenc", cfg_str(cfg, "avifencPath", ""))
    add_check(
        checks, "avifenc", "avifenc（可选）",
        "ok" if avifenc else "warn",
        avifenc or "缺失时 AVIF 回退 sips",
        "brew install libavif",
        bool(avifenc),
    )

    exiftool = find_binary("exiftool", cfg_str(cfg, "exiftoolPath", ""))
    if exiftool:
        code, out, err = run_quiet([exiftool, "-ver"])
        add_check(checks, "exiftool", "exiftool（EXIF / ICC）", "ok", first_line(out),
                  "brew install exiftool", True)
    else:
        add_check(checks, "exiftool", "exiftool（EXIF / ICC）", "warn",
                  "缺失时只转换像素，不复制 EXIF", "brew install exiftool", True)

    cjxl = find_binary("cjxl", cfg_str(cfg, "cjxlPath", ""))
    add_check(
        checks, "cjxl", "cjxl（JPEG XL，可选）",
        "ok" if cjxl else "warn",
        cjxl or "缺失时 JXL 输出不可用",
        "brew install jpeg-xl",
        bool(cjxl),
    )

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
    if checks.get("cwebp", {}).get("status") == "fail":
        run_brew_install("webp", "cwebp")
    if checks.get("avifenc", {}).get("status") != "ok":
        run_brew_install("libavif", "avifenc")
    if checks.get("exiftool", {}).get("status") != "ok":
        run_brew_install("exiftool", "exiftool")
    if checks.get("cjxl", {}).get("status") != "ok":
        run_brew_install("jpeg-xl", "JPEG XL")

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
        fail("图片工具异常：%s" % exc, code="internal_error")


if __name__ == "__main__":
    raise SystemExit(main())
