#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MacToolbox 字幕工具（Tool Protocol 实现）。

子命令：
  doctor  环境检测
  setup   自动修复缺失依赖（brew / 模型下载 / jieba）
  run     执行字幕流水线

事件通过 stdout JSON Lines 输出，人类可读日志也封装成 log 事件。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DEFAULT_MODEL = "/Volumes/APPLE 1TB/Whisper/models/ggml-large-v3-turbo.bin"
DEFAULT_JIEBA_LIB = "/Volumes/APPLE 1TB/Whisper/lib"
MODEL_URLS = {
    "ggml-large-v3-turbo.bin": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
    "ggml-medium.bin": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
    "ggml-small.bin": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
    "ggml-base.bin": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
}

CURRENT = {"proc": None, "cancelled": False}


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

def run_process(cmd, cwd=None, env=None, on_stdout=None, on_stderr=None):
    log("$ " + subprocess.list2cmdline(cmd))
    proc = subprocess.Popen(
        cmd,
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


def find_binary(name, configured=""):
    if configured:
        path = Path(configured).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return shutil.which(name)


def parse_timecode(value):
    value = value.strip()
    match = re.match(r"^(\d+):(\d+):(\d+(?:\.\d+)?)$", value)
    if not match:
        return 0.0
    return int(match.group(1)) * 3600 + int(match.group(2)) * 60 + float(match.group(3))


# ---------------------------------------------------------------- config

def load_config(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def cfg_str(cfg, key, default=""):
    # 敏感字段不再写 config.json；JobRunner 通过 MCT_SECRET_* 环境变量注入。
    env_value = os.environ.get("MCT_SECRET_" + key)
    if env_value:
        return env_value
    value = cfg.get(key, default)
    if value is None:
        return default
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def cfg_bool(cfg, key, default=False):
    value = cfg.get(key, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def cfg_float(cfg, key, default):
    try:
        return float(cfg.get(key, default))
    except (TypeError, ValueError):
        return default


def model_path(cfg):
    value = cfg_str(cfg, "modelPath", "").strip()
    return value or DEFAULT_MODEL


def jieba_lib(cfg):
    return cfg_str(cfg, "jiebaLib", "").strip() or DEFAULT_JIEBA_LIB


def output_directory(cfg):
    raw = cfg_str(cfg, "outputDir", "").strip()
    video = Path(cfg_str(cfg, "video", "")).expanduser()
    if raw:
        return Path(raw).expanduser()
    return video.parent


# ---------------------------------------------------------------- environment checks

def check_jieba(lib):
    if not lib or not os.path.isdir(lib):
        return False, "目录不存在：%s" % lib
    probe = (
        "import sys; sys.path.insert(0, %r); import jieba; "
        "print(getattr(jieba, '__version__', 'ok'))" % lib
    )
    try:
        result = subprocess.run(
            [sys.executable, "-c", probe],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode == 0:
            return True, (result.stdout.strip() or "ok")
        return False, (result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "import 失败")
    except Exception as exc:
        return False, str(exc)


def collect_checks(cfg):
    checks = []

    def add(check_id, label, status, detail="", fix_command=None, fixable=False):
        checks.append({
            "id": check_id,
            "label": label,
            "status": status,
            "detail": detail,
            "fixCommand": fix_command,
            "fixable": fixable,
        })

    version = "%d.%d.%d" % sys.version_info[:3]
    add("python", "Python", "ok", "%s · %s" % (version, sys.executable))

    ffmpeg = find_binary("ffmpeg", cfg_str(cfg, "ffmpegPath", ""))
    if ffmpeg:
        add("ffmpeg", "ffmpeg", "ok", ffmpeg, "brew install ffmpeg", True)
    else:
        add("ffmpeg", "ffmpeg", "missing", "未找到，需安装后重新检测", "brew install ffmpeg", True)

    ffprobe = find_binary("ffprobe", cfg_str(cfg, "ffprobePath", ""))
    if ffprobe:
        add("ffprobe", "ffprobe", "ok", ffprobe, "brew install ffmpeg", True)
    else:
        add("ffprobe", "ffprobe", "missing", "未找到，需安装后重新检测", "brew install ffmpeg", True)

    backend = cfg_str(cfg, "backend", "local")
    whisper = find_binary("whisper-cli", cfg_str(cfg, "whisperCLI", ""))
    if whisper:
        add("whisper", "whisper-cli", "ok", whisper, "brew install whisper.cpp", True)
    elif backend == "local":
        add("whisper", "whisper-cli", "missing", "本地转写需要 whisper.cpp", "brew install whisper.cpp", True)
    else:
        add("whisper", "whisper-cli", "warn", "云端模式不需要", "brew install whisper.cpp", False)

    model = Path(model_path(cfg)).expanduser()
    if backend == "local":
        if model.is_file() and model.stat().st_size > 50 * 1024 * 1024:
            add("model", "Whisper 模型", "ok", "%s · %.2f GB" % (model, model.stat().st_size / 1024 ** 3))
        else:
            add("model", "Whisper 模型", "missing", "模型缺失或过小：%s" % model, "自动下载模型", True)

    lib = jieba_lib(cfg)
    jieba_ok, jieba_detail = check_jieba(lib)
    add(
        "jieba", "jieba 分词", "ok" if jieba_ok else "warn",
        jieba_detail if jieba_ok else "缺失会静默退化为按字断行：" + jieba_detail,
        "python3 -m pip install --target \"%s\" jieba" % lib,
        True,
    )

    if backend == "cloud":
        base = cfg_str(cfg, "cloudBaseURL", "").strip()
        cloud_model = cfg_str(cfg, "cloudModel", "").strip()
        key = cfg_str(cfg, "cloudAPIKey", "").strip()
        missing = []
        if not base:
            missing.append("Base URL")
        if not cloud_model:
            missing.append("模型名")
        local_endpoint = base.startswith("http://127.0.0.1") or base.startswith("http://localhost")
        if not key and not local_endpoint:
            missing.append("API Key")
        add(
            "cloud", "云端转写配置", "ok" if not missing else "warn",
            "已配置" if not missing else "缺少：" + "、".join(missing),
            None, False,
        )

    if cfg_str(cfg, "reviewMode", "off") == "llm":
        base = cfg_str(cfg, "llmBaseURL", "").strip()
        model_name = cfg_str(cfg, "llmModel", "").strip()
        key = cfg_str(cfg, "llmAPIKey", "").strip()
        missing = []
        if not base:
            missing.append("Base URL")
        if not model_name:
            missing.append("模型名")
        local_endpoint = base.startswith("http://127.0.0.1") or base.startswith("http://localhost")
        if not key and not local_endpoint:
            missing.append("API Key")
        add(
            "llm", "LLM 校对配置", "ok" if not missing else "warn",
            "已配置" if not missing else "缺少：" + "、".join(missing),
            None, False,
        )

    # 输入视频属于任务输入，不放进环境检测；由 App 的表单校验负责。
    return checks


def doctor(cfg):
    checks = collect_checks(cfg)
    emit(type="env", checks=checks)
    missing = [c for c in checks if c["status"] == "missing"]
    emit(type="result", ok=True, summary="环境检测完成，缺失 %d 项" % len(missing))
    return 0


# ---------------------------------------------------------------- setup

def run_brew_install(package, label):
    brew = shutil.which("brew")
    if not brew:
        fail("未找到 Homebrew，无法自动安装 %s" % label, code="no_brew",
             detail="请先安装 Homebrew：https://brew.sh")
    log("安装 %s（brew install %s）…" % (label, package))
    code, _, err = run_process([brew, "install", package])
    if code != 0:
        fail("安装 %s 失败" % label, code="brew_failed", detail="\n".join(err[-20:]))
    log("%s 安装完成" % label)


def download_model(path, cfg):
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    url = cfg_str(cfg, "modelURL", "").strip() or MODEL_URLS.get(path.name, MODEL_URLS["ggml-large-v3-turbo.bin"])
    log("下载模型：%s" % url)
    partial = path.with_suffix(path.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "MacToolboxDemo/0.1"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, open(partial, "wb") as target:
            total = int(response.headers.get("Content-Length") or 0)
            done = 0
            last_tick = 0.0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                target.write(chunk)
                done += len(chunk)
                now = time.time()
                if now - last_tick > 0.3:
                    last_tick = now
                    fraction = (done / total) if total else 0.0
                    progress(fraction, step="setup", message="下载模型 %.0f MB" % (done / 1024 ** 2))
        partial.replace(path)
    except Exception as exc:
        try:
            partial.unlink(missing_ok=True)
        except Exception:
            pass
        fail("模型下载失败：%s" % exc, code="download_failed")
    expected = cfg_str(cfg, "modelSHA256", "").strip()
    if expected:
        log("校验 SHA-256…")
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest().lower() != expected.lower():
            fail("模型校验失败", code="checksum_failed", detail=digest.hexdigest())
    log("模型下载完成：%s" % path)


def install_jieba(lib):
    lib = Path(lib).expanduser()
    lib.mkdir(parents=True, exist_ok=True)
    log("安装 jieba 到 %s" % lib)
    code, _, err = run_process(
        [sys.executable, "-m", "pip", "install", "--target", str(lib), "jieba"]
    )
    if code != 0:
        fail("jieba 安装失败", code="pip_failed", detail="\n".join(err[-20:]))
    log("jieba 安装完成")


def setup(cfg):
    install_signals()
    step_event("setup", "环境修复", "running")
    checks = collect_checks(cfg)
    missing = {c["id"]: c for c in checks if c["status"] in ("missing", "warn")}

    if "ffmpeg" in missing or "ffprobe" in missing:
        run_brew_install("ffmpeg", "ffmpeg / ffprobe")

    if "whisper" in missing and cfg_str(cfg, "backend", "local") == "local":
        run_brew_install("whisper.cpp", "whisper-cli")

    if "model" in missing and cfg_str(cfg, "backend", "local") == "local":
        download_model(model_path(cfg), cfg)

    if "jieba" in missing:
        install_jieba(jieba_lib(cfg))

    checks = collect_checks(cfg)
    emit(type="env", checks=checks)
    step_event("setup", "环境修复", "done")
    remaining = [c for c in checks if c["status"] == "missing"]
    emit(type="result", ok=not remaining, summary="修复完成，仍缺失 %d 项" % len(remaining))
    return 0


# ---------------------------------------------------------------- subtitle pipeline

STEPS = [
    ("probe", "预检视频", 0.03),
    ("extract", "提取音轨", 0.07),
    ("transcribe", "语音转写", 0.60),
    ("review", "校对", 0.10),
    ("build", "字幕工程", 0.10),
    ("qc", "质量检查", 0.05),
    ("deliver", "交付", 0.05),
]
STEP_BASE = {}
_cursor = 0.0
WEIGHT = {}
for _id, _title, _weight in STEPS:
    STEP_BASE[_id] = _cursor
    WEIGHT[_id] = _weight
    _cursor += _weight


def step_progress(step, fraction, message=None):
    fraction = max(0.0, min(1.0, fraction))
    overall = STEP_BASE.get(step, 0.0) + WEIGHT.get(step, 0.0) * fraction
    progress(overall, step=step, message=message)


def probe_video(cfg):
    resume = cfg_bool(cfg, "resume", False)
    meta_path = Path(cfg["_meta"]["jobDir"]) / "probe.json"
    if resume and meta_path.is_file():
        try:
            cached = json.loads(meta_path.read_text(encoding="utf-8"))
            if cached.get("duration") and cached.get("has_audio"):
                log("断点续跑：复用 probe.json")
                artifact("json", meta_path, "视频信息", "probe")
                return cached
        except Exception:
            pass

    ffprobe = find_binary("ffprobe", cfg_str(cfg, "ffprobePath", ""))
    if not ffprobe:
        fail("未找到 ffprobe", code="missing_ffprobe", detail="请运行环境修复，或 brew install ffmpeg")
    video = cfg_str(cfg, "video", "")
    if not Path(video).expanduser().is_file():
        fail("输入视频不存在：%s" % video, code="missing_video")

    code, out, err = run_process([
        ffprobe, "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", str(Path(video).expanduser()),
    ])
    if code != 0:
        fail("ffprobe 读取失败", code="probe_failed", detail="\n".join(err[-20:]))
    try:
        data = json.loads("\n".join(out))
    except Exception as exc:
        fail("无法解析 ffprobe 输出：%s" % exc, code="probe_parse_failed")

    duration = float(data.get("format", {}).get("duration") or 0)
    streams = data.get("streams", [])
    has_audio = any(s.get("codec_type") == "audio" for s in streams)
    if not has_audio:
        fail("输入文件没有音轨", code="no_audio")
    if duration <= 0:
        fail("无法读取视频时长", code="bad_duration")

    video_stream = next((s for s in streams if s.get("codec_type") == "video"), {})
    log("视频：%s" % Path(video).name)
    log("时长：%.1f 秒（%.1f 分钟）" % (duration, duration / 60))
    log("分辨率：%sx%s" % (video_stream.get("width", "?"), video_stream.get("height", "?")))

    result = {
        "duration": duration,
        "has_audio": has_audio,
        "width": video_stream.get("width"),
        "height": video_stream.get("height"),
    }
    meta_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    artifact("json", meta_path, "视频信息", "probe")
    return result


def extract_audio(cfg, duration):
    job_dir = Path(cfg["_meta"]["jobDir"])
    job_dir.mkdir(parents=True, exist_ok=True)
    if cfg_bool(cfg, "resume", False):
        for name in ("audio.wav", "audio.mp3"):
            cached_audio = job_dir / name
            if cached_audio.is_file() and cached_audio.stat().st_size > 0:
                log("断点续跑：复用 %s" % name)
                artifact("audio", cached_audio, "音轨", "audio")
                return cached_audio

    ffmpeg = find_binary("ffmpeg", cfg_str(cfg, "ffmpegPath", ""))
    if not ffmpeg:
        fail("未找到 ffmpeg", code="missing_ffmpeg", detail="请运行环境修复，或 brew install ffmpeg")

    backend = cfg_str(cfg, "backend", "local")
    audio = job_dir / ("audio.wav" if backend == "local" else "audio.mp3")

    cmd = [
        ffmpeg, "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
        "-i", str(Path(cfg_str(cfg, "video", "")).expanduser()),
        "-map", "0:a:0", "-vn",
    ]
    if backend == "local":
        cmd += ["-c:a", "pcm_s16le", "-ar", "16000", "-ac", "1", str(audio)]
    else:
        cmd += ["-c:a", "libmp3lame", "-b:a", "64k", "-ac", "1", str(audio)]

    def on_stdout(line):
        if line.startswith("out_time="):
            seconds = parse_timecode(line.split("=", 1)[1])
            if duration > 0:
                step_progress("extract", min(seconds / duration, 1.0))

    code, _, err = run_process(cmd, on_stdout=on_stdout)
    if code != 0:
        # 有些 ffmpeg 构建没有 libmp3lame，云端模式回退 wav
        if backend == "cloud":
            log("mp3 编码失败，回退 wav", level="warn")
            audio = job_dir / "audio.wav"
            cmd = [
                ffmpeg, "-y", "-v", "error", "-progress", "pipe:1", "-nostats",
                "-i", str(Path(cfg_str(cfg, "video", "")).expanduser()),
                "-map", "0:a:0", "-vn", "-c:a", "pcm_s16le", "-ar", "16000", "-ac", "1",
                str(audio),
            ]
            code, _, err = run_process(cmd, on_stdout=on_stdout)
        if code != 0:
            fail("音轨提取失败", code="extract_failed", detail="\n".join(err[-20:]))

    if not audio.is_file() or audio.stat().st_size == 0:
        fail("音轨文件为空", code="empty_audio")
    log("音轨：%s（%.1f MB）" % (audio.name, audio.stat().st_size / 1024 ** 2))
    artifact("audio", audio, "音轨", "audio")
    return audio


def script_counts(text):
    cjk = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff")
    latin = sum(1 for ch in text if ch.isascii() and ch.isalpha())
    return cjk, latin


def run_whisper_local(cfg, audio, duration):
    job_dir = Path(cfg["_meta"]["jobDir"])
    raw_json = job_dir / "raw.json"
    raw_txt = job_dir / "raw.txt"
    if cfg_bool(cfg, "resume", False) and raw_json.is_file():
        try:
            count = len(json.loads(raw_json.read_text(encoding="utf-8")).get("transcription", []))
        except Exception:
            count = 0
        if count > 0:
            if not raw_txt.is_file():
                raw_txt.write_text("", encoding="utf-8")
            log("断点续跑：复用已有转写（%d 段）" % count)
            artifact("json", raw_json, "原始转写 JSON", "raw-json")
            artifact("text", raw_txt, "原始转写文本", "raw-txt")
            return raw_json, raw_txt

    whisper = find_binary("whisper-cli", cfg_str(cfg, "whisperCLI", ""))
    if not whisper:
        fail("未找到 whisper-cli", code="missing_whisper",
             detail="brew install whisper.cpp，或在环境修复中自动安装")
    model = Path(model_path(cfg)).expanduser()
    if not model.is_file():
        fail("Whisper 模型不存在：%s" % model, code="missing_model",
             detail="可在环境修复中自动下载模型")

    prefix = job_dir / "raw"
    # 空值也按中文处理。whisper-cli 不传 -l 时默认是 en，绝不能静默走英文。
    language = cfg_str(cfg, "language", "zh").strip() or "zh"
    prompt = build_whisper_prompt(cfg)

    def whisper_cmd(lang):
        command = [
            whisper, "-m", str(model),
            "-f", str(audio),
            "-of", str(prefix),
            "-osrt", "-otxt", "-oj",
            "-pp", "-mc", "0",
            "-l", lang,
        ]
        if prompt:
            command += ["--prompt", prompt]
        return command

    if language == "auto":
        log("转写语言：自动检测（whisper 采样开头 30 秒）")
    else:
        log("转写语言：%s" % language)
    log("首次运行 whisper 会编译 Metal 着色器，可能需要 30–60 秒，请耐心等待。")

    last_percent = -1
    detected = {"lang": "", "p": ""}

    def on_stderr(line):
        nonlocal last_percent
        match = re.search(r"progress\s*=\s*(\d+)%", line)
        if match:
            percent = int(match.group(1))
            if percent != last_percent:
                last_percent = percent
                step_progress("transcribe", percent / 100.0, "whisper %d%%" % percent)
            return
        auto = re.search(
            r"auto-detected language:\s*([A-Za-z-]+)\s*\(p\s*=\s*([0-9.]+)\)",
            line,
        )
        if auto:
            detected["lang"] = auto.group(1)
            detected["p"] = auto.group(2)
            return
        if line.strip() and "ggml_metal" not in line and "load_backend" not in line:
            log(line, level="stderr")

    def transcribe(lang):
        nonlocal last_percent
        last_percent = -1
        return run_process(whisper_cmd(lang), on_stderr=on_stderr)

    code, _, err = transcribe(language)
    if code != 0:
        fail("whisper 转写失败", code="whisper_failed", detail="\n".join(err[-30:]))

    raw_json = job_dir / "raw.json"
    raw_txt = job_dir / "raw.txt"
    if not raw_json.is_file():
        fail("whisper 未生成 raw.json", code="missing_raw_json")
    if not raw_txt.is_file():
        raw_txt.write_text("", encoding="utf-8")

    try:
        data = json.loads(raw_json.read_text(encoding="utf-8"))
        count = len(data.get("transcription", []))
    except Exception:
        count = 0
    if count == 0:
        fail("whisper 没有产出任何转写段", code="empty_transcription",
             detail="可尝试关闭 prompt、检查音轨，或改用云端后端")

    if language == "auto" and detected["lang"]:
        log("自动检测语言：%s（p=%s）" % (detected["lang"], detected["p"]))

    # 兜底：自动检测偶尔会被英文开场/术语带偏。若判成 en，但正文大量中文，
    # 保留误判产物并用 zh 重跑，避免整条字幕变成英文幻觉。
    if language == "auto" and detected["lang"] == "en":
        cjk, latin = script_counts(raw_txt.read_text(encoding="utf-8", errors="replace"))
        ratio = cjk / max(1, cjk + latin)
        if cjk >= 80 and ratio >= 0.20:
            log(
                "自动检测为英文，但转写中中文占比 %.0f%%（%d 字），疑似语种误判；"
                "保留 raw.autodetect-en.* 并改用中文重跑。" % (ratio * 100, cjk),
                level="warn",
            )
            for ext in ("json", "txt", "srt"):
                source = job_dir / ("raw." + ext)
                if source.is_file():
                    shutil.copy2(source, job_dir / ("raw.autodetect-en." + ext))
            code, _, err = transcribe("zh")
            if code != 0:
                fail("中文纠正重跑失败", code="whisper_retry_failed",
                     detail="\n".join(err[-30:]))
            try:
                data = json.loads(raw_json.read_text(encoding="utf-8"))
                count = len(data.get("transcription", []))
            except Exception:
                count = 0
            if count == 0:
                fail("中文纠正重跑没有产出转写段", code="empty_transcription")
            language = "zh"
            log("语言纠正完成：已用 zh 重新转写（%d 段）" % count)

    log("转写完成：%d 段（语言 %s）" % (count, language))
    artifact("json", raw_json, "原始转写 JSON", "raw-json")
    artifact("text", raw_txt, "原始转写文本", "raw-txt")
    return raw_json, raw_txt


# ---------------------------------------------------------------- cloud ASR

def join_api(base, suffix):
    base = base.strip().rstrip("/")
    if not base:
        fail("云端 Base URL 为空", code="bad_cloud_config")
    if base.endswith("/v1") or "/v1/" in base + "/":
        return base + suffix
    return base + "/v1" + suffix


def multipart_body(fields, file_field, file_path):
    boundary = "----MacToolbox" + uuid.uuid4().hex
    chunks = []
    for key, value in fields.items():
        chunks.append(("--%s\r\n" % boundary).encode())
        chunks.append(('Content-Disposition: form-data; name="%s"\r\n\r\n' % key).encode())
        chunks.append(str(value).encode("utf-8"))
        chunks.append(b"\r\n")
    filename = Path(file_path).name
    mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    chunks.append(("--%s\r\n" % boundary).encode())
    chunks.append(
        ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n' % (file_field, filename)).encode()
    )
    chunks.append(("Content-Type: %s\r\n\r\n" % mime).encode())
    chunks.append(Path(file_path).read_bytes())
    chunks.append(b"\r\n")
    chunks.append(("--%s--\r\n" % boundary).encode())
    return b"".join(chunks), "multipart/form-data; boundary=%s" % boundary


def synth_segments(text, duration):
    parts = [p.strip() for p in re.split(r"(?<=[。！？!?；;])", text) if p.strip()]
    if not parts:
        parts = [text.strip()] if text.strip() else []
    total = sum(max(len(p), 1) for p in parts) or 1
    cursor = 0.0
    segments = []
    for part in parts:
        share = duration * (max(len(part), 1) / total)
        start, end = cursor, min(cursor + share, duration)
        segments.append({"start": start, "end": end, "text": part})
        cursor = end
    return segments


def run_whisper_cloud(cfg, audio, duration):
    job_dir = Path(cfg["_meta"]["jobDir"])
    raw_json = job_dir / "raw.json"
    raw_txt = job_dir / "raw.txt"
    if cfg_bool(cfg, "resume", False) and raw_json.is_file():
        try:
            count = len(json.loads(raw_json.read_text(encoding="utf-8")).get("transcription", []))
        except Exception:
            count = 0
        if count > 0:
            if not raw_txt.is_file():
                raw_txt.write_text("", encoding="utf-8")
            log("断点续跑：复用已有云端转写（%d 段）" % count)
            artifact("json", raw_json, "原始转写 JSON", "raw-json")
            artifact("text", raw_txt, "原始转写文本", "raw-txt")
            return raw_json, raw_txt

    base = cfg_str(cfg, "cloudBaseURL", "").strip()
    model = cfg_str(cfg, "cloudModel", "").strip()
    key = cfg_str(cfg, "cloudAPIKey", "").strip()
    if not base or not model:
        fail("云端转写配置不完整", code="bad_cloud_config",
             detail="需要 Base URL 与模型名")

    fields = {
        "model": model,
        "response_format": "verbose_json",
        "timestamp_granularities[]": "segment",
    }
    language = cfg_str(cfg, "language", "zh").strip()
    if language and language != "auto":
        fields["language"] = language
    prompt = build_whisper_prompt(cfg)
    if prompt:
        fields["prompt"] = prompt

    body, content_type = multipart_body(fields, "file", audio)
    endpoint = join_api(base, "/audio/transcriptions")
    log("云端转写：%s（%s）" % (endpoint, model))
    if len(body) > 25 * 1024 * 1024:
        log("上传体积 %.1f MB，部分服务限制 25 MB" % (len(body) / 1024 ** 2), level="warn")

    request = urllib.request.Request(endpoint, data=body, method="POST")
    request.add_header("Content-Type", content_type)
    if key:
        request.add_header("Authorization", "Bearer " + key)

    step_progress("transcribe", 0.05, "等待云端转写")
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            payload = json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:1000]
        fail("云端转写请求失败（HTTP %s）" % exc.code, code="cloud_http_error", detail=detail)
    except Exception as exc:
        fail("云端转写失败：%s" % exc, code="cloud_failed")

    segments = payload.get("segments") or []
    text = payload.get("text") or ""
    if not segments and text:
        log("云端未返回 segment 时间戳，按标点估算时间轴", level="warn")
        segments = synth_segments(text, duration)

    transcription = []
    for segment in segments:
        seg_text = (segment.get("text") or "").strip()
        if not seg_text:
            continue
        transcription.append({
            "offsets": {
                "from": int(float(segment.get("start", 0)) * 1000),
                "to": int(float(segment.get("end", 0)) * 1000),
            },
            "text": seg_text,
        })
    if not transcription:
        fail("云端没有返回可用转写", code="empty_transcription")

    raw_json.write_text(
        json.dumps({"transcription": transcription}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    raw_txt.write_text("\n".join(item["text"] for item in transcription), encoding="utf-8")
    log("云端转写完成：%d 段" % len(transcription))
    artifact("json", raw_json, "原始转写 JSON", "raw-json")
    artifact("text", raw_txt, "原始转写文本", "raw-txt")
    return raw_json, raw_txt


# ---------------------------------------------------------------- lexicon / hotwords

DEFAULT_LLM_PROMPT = (
    "你是严谨的中文字幕校对助手。只找出四类问题：系统性同音错、"
    "专业术语/缩写错误、ASR 幻觉样板话、明显口误或重复。"
    "输出一个 JSON 对象：键是原文中的错误片段，值是修正后的写法。"
    "键要尽量长、带上下文以精确锚定；不要输出解释、不要 markdown。"
    "修正值里不要带标点。没有把握的不要改。"
)


def split_terms(raw):
    if not raw:
        return []
    return [item.strip() for item in re.split(r"[\n,，、;；]+", raw) if item.strip()]


def all_hotwords(cfg):
    seen, result = set(), []
    for term in split_terms(cfg_str(cfg, "hotwords", "")) + split_terms(cfg_str(cfg, "_lexiconHotwords", "")):
        key = term.lower()
        if key not in seen:
            seen.add(key)
            result.append(term)
    return result


def build_whisper_prompt(cfg):
    background = cfg_str(cfg, "prompt", "").strip()
    terms = all_hotwords(cfg)
    if terms:
        # 热词优先保留，背景提示放在后面；避免截断时先丢掉专有名词
        prompt = "，".join(terms[:80]) + (("。" + background) if background else "")
    else:
        prompt = background
    # whisper.cpp 的 prompt 上限约 224 token；中文按字近似，保守取 220 字符
    if len(prompt) > 220:
        prompt = prompt[:220].rstrip("，,、 ")
        log("热词提示超过 220 字符上限，已截断", level="warn")
    profile = cfg_str(cfg, "_lexiconProfileName", "").strip()
    if profile:
        log("词表 Profile：%s（热词 %d 个）" % (profile, len(terms)))
    elif terms:
        log("本次热词：%d 个" % len(terms))
    return prompt


def profile_rules(cfg):
    raw = cfg_str(cfg, "_lexiconRules", "").strip()
    if not raw:
        return {}
    try:
        items = json.loads(raw)
    except Exception:
        return {}
    rules = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        source = str(item.get("from", "")).strip()
        target = str(item.get("to", "")).strip()
        if source and target and source != target:
            rules[source] = target
    return dict(sorted(rules.items(), key=lambda pair: -len(pair[0])))


def load_fixes(path):
    if not path or not Path(path).is_file():
        return {}
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        return {str(k): str(v) for k, v in data.items() if str(k) and str(v)}
    except Exception:
        return {}


def ordered_fixes(fixes):
    return dict(sorted(fixes.items(), key=lambda pair: -len(pair[0])))


def prepare_profile_fixes(cfg, raw_txt):
    rules = profile_rules(cfg)
    job_dir = Path(cfg["_meta"]["jobDir"])
    fixes_path = job_dir / "fixes.json"
    existing = load_fixes(fixes_path)
    merged = dict(rules)
    merged.update(existing)  # 已有/用户修正优先于 Profile
    if not merged:
        return None
    fixes_path.write_text(
        json.dumps(ordered_fixes(merged), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    text = Path(raw_txt).read_text(encoding="utf-8")
    hits = sum(text.count(key) for key in rules)
    if rules:
        log("词表规则：%d 条（命中 %d 处，0 token）" % (len(rules), hits))
    artifact("json", fixes_path, "术语修正表", "fixes")
    return fixes_path


def write_substitution_audit(cfg, raw_txt, fixes_path):
    if not fixes_path or not Path(fixes_path).is_file():
        return
    text = Path(raw_txt).read_text(encoding="utf-8")
    rules = profile_rules(cfg)
    fixes = load_fixes(fixes_path)
    items = []
    for source, target in ordered_fixes(fixes).items():
        count = text.count(source)
        if count:
            items.append({
                "from": source,
                "to": target,
                "count": count,
                "source": "profile" if source in rules else "llm_or_manual",
            })
    job_dir = Path(cfg["_meta"]["jobDir"])
    audit_path = job_dir / "substitutions.json"
    audit_path.write_text(json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8")
    log("替换留痕：%d 类，共 %d 处" % (len(items), sum(item["count"] for item in items)))
    artifact("json", audit_path, "替换留痕", "substitutions")


# ---------------------------------------------------------------- LLM proofreading

def chat_completion(cfg, system, user):
    base = cfg_str(cfg, "llmBaseURL", "").strip()
    model = cfg_str(cfg, "llmModel", "").strip()
    key = cfg_str(cfg, "llmAPIKey", "").strip()
    if not base or not model:
        raise RuntimeError("LLM 配置不完整（Base URL / 模型名）")

    endpoint = join_api(base, "/chat/completions")
    payload = {
        "model": model,
        "temperature": 0.1,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        method="POST",
    )
    request.add_header("Content-Type", "application/json")
    if key:
        request.add_header("Authorization", "Bearer " + key)

    with urllib.request.urlopen(request, timeout=600) as response:
        data = json.loads(response.read().decode("utf-8", errors="replace"))
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("LLM 响应没有 choices")
    return choices[0].get("message", {}).get("content", "")


def chunk_text(text, size=6000):
    text = text.strip()
    if len(text) <= size:
        return [text] if text else []
    chunks, start = [], 0
    while start < len(text):
        end = min(start + size, len(text))
        if end < len(text):
            cut = text.rfind("\n", start, end)
            if cut <= start + size // 2:
                cut = end
            end = cut
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start = end
    return chunks


def parse_fixes_json(content):
    content = content.strip()
    content = re.sub(r"^```(?:json)?\s*", "", content)
    content = re.sub(r"\s*```$", "", content)
    start, end = content.find("{"), content.rfind("}")
    if start < 0 or end <= start:
        return {}
    try:
        data = json.loads(content[start:end + 1])
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        str(key): str(value)
        for key, value in data.items()
        if str(key).strip() and str(value).strip() and str(key) != str(value)
    }


def llm_proofread(cfg, raw_txt):
    text = Path(raw_txt).read_text(encoding="utf-8")
    rules = profile_rules(cfg)

    # 规则先行：LLM 看到的是已经替换过已知错词的文本
    cleaned = text
    for source, target in rules.items():
        cleaned = cleaned.replace(source, target)

    scope = cfg_str(cfg, "llmScope", "full")
    if scope == "hotwords":
        hot = {term.lower() for term in all_hotwords(cfg)}
        hot.update(target.lower() for target in rules.values())
        selected = []
        for line in cleaned.splitlines():
            lower = line.lower()
            if any(term and term in lower for term in hot) or re.search(r"[A-Za-z]{2,}", line):
                selected.append(line)
        if not selected:
            log("LLM 范围=热词片段，但没有命中片段，跳过 LLM 调用（0 token）")
            fixes_path = job_dir / "fixes.json"
            return fixes_path if fixes_path.is_file() else None
        cleaned = "\n".join(selected)
        log("LLM 范围=热词/缩写片段：%d 行（全文 %d 行）" % (
            len(selected), len(text.splitlines())
        ))

    chunks = chunk_text(cleaned)
    job_dir = Path(cfg["_meta"]["jobDir"])
    fixes_path = job_dir / "fixes.json"
    fixes = load_fixes(fixes_path)

    if not chunks:
        fixes_path.write_text(json.dumps(ordered_fixes(fixes), ensure_ascii=False, indent=2), encoding="utf-8")
        return fixes_path

    system = cfg_str(cfg, "llmPrompt", "").strip() or DEFAULT_LLM_PROMPT
    preset = cfg_str(cfg, "llmPromptPreset", "").strip()
    if preset:
        log("LLM 提示词预设：%s" % preset)

    for index, chunk in enumerate(chunks):
        step_progress("review", index / max(len(chunks), 1), "LLM 校对 %d/%d" % (index + 1, len(chunks)))
        user = (
            "下面是 ASR 转写文本片段。找出需要修正的地方，只返回 JSON 对象。\n\n"
            + chunk
        )
        try:
            content = chat_completion(cfg, system, user)
            found = parse_fixes_json(content)
            added = 0
            for source, target in found.items():
                if source not in fixes:
                    fixes[source] = target
                    added += 1
            log("LLM 片段 %d/%d：新增 %d 条（已有规则优先）" % (index + 1, len(chunks), added))
        except Exception as exc:
            if cfg_bool(cfg, "llmFallback", True):
                log("LLM 校对失败，已跳过：%s" % exc, level="warn")
                continue
            fail("LLM 校对失败：%s" % exc, code="llm_failed")

    fixes_path.write_text(
        json.dumps(ordered_fixes(fixes), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    log("LLM 校对完成：共 %d 条规则（含词表规则）" % len(fixes))
    artifact("json", fixes_path, "术语修正表", "fixes")
    return fixes_path

# ---------------------------------------------------------------- manual checkpoint

def wait_for_continue(cfg, raw_txt):
    job_dir = Path(cfg["_meta"]["jobDir"])
    fixes_path = job_dir / "fixes.json"
    if not fixes_path.exists():
        fixes_path.write_text("{}\n", encoding="utf-8")

    emit(
        type="checkpoint",
        checkpoint={
            "id": "review",
            "title": "人工校对",
            "message": "请通读 raw.txt，把同音错/术语/幻觉写入 fixes.json，然后继续。",
            "artifacts": [
                {"id": "raw-txt", "kind": "text", "path": str(raw_txt), "label": "原始转写"},
                {"id": "fixes", "kind": "json", "path": str(fixes_path), "label": "修正表"},
            ],
        },
    )
    step_progress("review", 0.0, "等待人工校对")
    log("等待人工校对确认；raw.txt：%s" % raw_txt)
    log("修正表：%s" % fixes_path)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except Exception:
            continue
        if message.get("type") in ("continue", "skip"):
            log("收到继续指令")
            return fixes_path
    fail("等待校对时输入通道关闭", code="checkpoint_closed")


# ---------------------------------------------------------------- subtitle engineering

def srt_to_vtt(srt_text):
    converted = re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", srt_text)
    return "WEBVTT\n\n" + converted.strip() + "\n"


def build_subtitles(cfg, raw_json, fixes_path):
    job_dir = Path(cfg["_meta"]["jobDir"])
    final_srt = job_dir / "final.srt"
    if cfg_bool(cfg, "resume", False) and final_srt.is_file():
        log("断点续跑：复用 final.srt")
        artifact("subtitle", final_srt, "成品字幕（SRT）", "final-srt")
        return final_srt

    script = Path(cfg["_meta"]["toolDir"]) / "scripts" / "make_srt.py"
    if not script.is_file():
        fail("缺少字幕工程脚本 make_srt.py", code="missing_make_srt")

    cmd = [
        sys.executable, str(script),
        "--src", str(raw_json),
        "--out", str(final_srt),
        "--max-char", str(cfg_float(cfg, "maxChar", 36)),
        "--line-char", str(cfg_float(cfg, "lineChar", 18)),
        "--max-dur", str(cfg_float(cfg, "maxDur", 7.0)),
        "--min-dur", str(cfg_float(cfg, "minDur", 1.0)),
        "--merge-gap", str(cfg_float(cfg, "mergeGap", 0.35)),
    ]
    if fixes_path and Path(fixes_path).is_file():
        cmd += ["--fix", str(fixes_path)]
    if cfg_bool(cfg, "stripPunct", True):
        cmd.append("--strip-punct")
    if cfg_bool(cfg, "dropFillers", True):
        cmd.append("--drop-fillers")

    env = os.environ.copy()
    env["SUBTITLE_JIEBA_LIB"] = jieba_lib(cfg)
    env["SUBTITLE_TMPDIR"] = str(job_dir / "tmp")
    Path(env["SUBTITLE_TMPDIR"]).mkdir(parents=True, exist_ok=True)

    code, out, err = run_process(cmd, env=env, on_stdout=lambda line: log(line) if line.strip() else None)
    if code != 0:
        fail("字幕工程失败", code="build_failed", detail="\n".join(err[-20:]))
    if not final_srt.is_file():
        fail("字幕工程没有产出 final.srt", code="missing_srt")

    lines = final_srt.read_text(encoding="utf-8").split("\n\n")
    count = len([block for block in lines if block.strip()])
    log("字幕工程完成：%d 条" % count)
    artifact("subtitle", final_srt, "成品字幕（SRT）", "final-srt")
    return final_srt


def quality_check(cfg, final_srt, duration):
    job_dir = Path(cfg["_meta"]["jobDir"])
    script = Path(cfg["_meta"]["toolDir"]) / "scripts" / "check_srt.py"
    if not script.is_file():
        fail("缺少质检脚本 check_srt.py", code="missing_check_srt")

    # 阈值必须和 make_srt.py 用同一份 config，否则会出现"生成器按 22 排、质检按 18.6 判"
    code, out, err = run_process([
        sys.executable, str(script), str(final_srt), "%.3f" % duration,
        "--line-char", str(cfg_float(cfg, "lineChar", 18)),
        "--min-dur", str(cfg_float(cfg, "minDur", 1.0)),
        "--max-dur", str(cfg_float(cfg, "maxDur", 7.0)),
        "--max-lines", "2",
    ])
    report = "\n".join(out + err)
    report_path = job_dir / "qc.txt"
    report_path.write_text(report, encoding="utf-8")
    for line in out:
        if line.strip():
            log(line)
    artifact("report", report_path, "质检报告", "qc")

    if code != 0:
        reason = next((line.strip()[len("FAIL: "):] for line in out if line.startswith("FAIL: ")), "")
        if cfg_bool(cfg, "allowQCFail", False):
            log("质检未通过（%s），但已允许继续交付" % (reason or "见 qc.txt"), level="warn")
        else:
            fail("质检未通过（硬性门禁）：%s" % (reason or "详情见 qc.txt"),
                 code="qc_failed", detail=report)
    else:
        log("质检通过（硬性门禁）")
    return report_path


def deliver(cfg, final_srt):
    fmt = cfg_str(cfg, "format", "srt").lower()
    if fmt not in ("srt", "vtt"):
        fmt = "srt"

    video = Path(cfg_str(cfg, "video", "")).expanduser()
    target_dir = output_directory(cfg)
    try:
        target_dir.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        fail("无法创建输出目录：%s" % exc, code="output_dir_failed")

    target = target_dir / (video.stem + "." + fmt)
    if target.exists() and not cfg_bool(cfg, "overwrite", True):
        fail("输出文件已存在：%s" % target, code="output_exists")

    if fmt == "vtt":
        content = srt_to_vtt(final_srt.read_text(encoding="utf-8"))
        target.write_text(content, encoding="utf-8")
    else:
        shutil.copy2(final_srt, target)

    log("已交付：%s" % target)
    artifact("subtitle", target, "成品字幕", "delivered")
    return target


# ---------------------------------------------------------------- run

def run(cfg):
    install_signals()
    job_dir = Path(cfg["_meta"]["jobDir"])
    tmp_dir = job_dir / "tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    # 让 ffmpeg / whisper 的临时文件也落在任务目录，避免吃主盘
    os.environ["TMPDIR"] = str(tmp_dir)

    video = Path(cfg_str(cfg, "video", "")).expanduser()
    if not video.is_file():
        fail("请选择有效的视频文件", code="missing_video")

    backend = cfg_str(cfg, "backend", "local")
    review_mode = cfg_str(cfg, "reviewMode", "off")

    log("输入：%s" % video)
    log("转写后端：%s，校对模式：%s" % (backend, review_mode))
    if cfg_str(cfg, "_lexiconProfileName", "").strip():
        log("词表 Profile：%s" % cfg_str(cfg, "_lexiconProfileName", "").strip())

    step_event("probe", "预检视频", "running")
    step_progress("probe", 0.1)
    info = probe_video(cfg)
    step_progress("probe", 1.0)
    step_event("probe", "预检视频", "done")

    step_event("extract", "提取音轨", "running")
    audio = extract_audio(cfg, info["duration"])
    step_progress("extract", 1.0)
    step_event("extract", "提取音轨", "done")

    step_event("transcribe", "语音转写", "running")
    if backend == "cloud":
        raw_json, raw_txt = run_whisper_cloud(cfg, audio, info["duration"])
    else:
        raw_json, raw_txt = run_whisper_local(cfg, audio, info["duration"])
    step_progress("transcribe", 1.0)
    step_event("transcribe", "语音转写", "done")

    step_event("review", "校对", "running")
    cached_fixes = Path(cfg["_meta"]["jobDir"]) / "fixes.json"
    base_fixes = prepare_profile_fixes(cfg, raw_txt)
    fixes_path = None
    if cfg_bool(cfg, "resume", False) and cached_fixes.is_file():
        log("断点续跑：复用 fixes.json")
        fixes_path = cached_fixes
    elif review_mode == "llm":
        fixes_path = llm_proofread(cfg, raw_txt)
    elif review_mode == "manual":
        fixes_path = wait_for_continue(cfg, raw_txt)
    else:
        fixes_path = base_fixes
        if base_fixes:
            log("跳过 LLM/人工校对；保留词表规则（0 token）")
    write_substitution_audit(cfg, raw_txt, fixes_path)
    step_progress("review", 1.0)
    step_event("review", "校对", "done")

    step_event("build", "字幕工程", "running")
    final_srt = build_subtitles(cfg, raw_json, fixes_path)
    step_progress("build", 1.0)
    step_event("build", "字幕工程", "done")

    step_event("qc", "质量检查", "running")
    quality_check(cfg, final_srt, info["duration"])
    step_progress("qc", 1.0)
    step_event("qc", "质量检查", "done")

    step_event("deliver", "交付", "running")
    target = deliver(cfg, final_srt)
    step_progress("deliver", 1.0)
    step_event("deliver", "交付", "done")

    emit(
        type="result",
        ok=True,
        summary="字幕已生成：%s" % target.name,
        artifacts=[
            {"id": "delivered", "kind": "subtitle", "path": str(target), "label": "成品字幕"},
            {"id": "final-srt", "kind": "subtitle", "path": str(final_srt), "label": "工作副本"},
        ],
    )
    return 0


# ---------------------------------------------------------------- cli

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run", "doctor", "setup"])
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    cfg = load_config(args.config)
    if "_meta" not in cfg:
        fail("配置缺少 _meta", code="bad_config")

    try:
        if args.command == "doctor":
            return doctor(cfg)
        if args.command == "setup":
            return setup(cfg)
        return run(cfg)
    except SystemExit:
        raise
    except Exception as exc:
        import traceback
        traceback.print_exc()
        fail("未处理的异常：%s" % exc, code="exception")


if __name__ == "__main__":
    sys.exit(main())
