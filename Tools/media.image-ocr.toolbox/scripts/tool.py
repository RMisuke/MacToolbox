#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""图片 OCR 的 Tool Protocol / CLI 实现。

GUI（nativeView=imageOCR）使用 VisionKit Live Text；
CLI/Agent 使用同仓库的 `ocr.swift`，按需编译并缓存到
`$MCT_DATA_DIR/Cache/ocr/` 或 `~/Library/Caches/MacToolboxDemo/ocr/`。

这样两条路径都只依赖 macOS Vision，不引入第三方 OCR 服务。
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SCRIPT_DIR = Path(__file__).resolve().parent
SWIFT_SOURCE = SCRIPT_DIR / "ocr.swift"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


# ---------------------------------------------------------------- protocol

def emit(**payload):
    try:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except Exception:
        pass


def log(message, level="info"):
    emit(type="log", level=level, message=str(message))


def progress(fraction, step_id=None, message=None):
    payload = {"type": "progress", "fraction": max(0.0, min(1.0, float(fraction)))}
    if step_id:
        payload["step"] = step_id
    if message:
        payload["message"] = message
    emit(**payload)


def step(step_id, title, state):
    emit(type="step", step=step_id, title=title, state=state)


def artifact(artifact_id, kind, path, label=None):
    item = {"type": "artifact", "id": artifact_id, "kind": kind, "path": str(path)}
    if label:
        item["label"] = label
    emit(**item)
    return {"id": artifact_id, "kind": kind, "path": str(path), "label": label}


def fail(message, code="failed", detail=None):
    payload = {"type": "error", "code": code, "message": str(message)}
    if detail:
        payload["detail"] = str(detail)
    emit(**payload)
    sys.exit(1)


def clean(text):
    return ANSI_RE.sub("", text or "")


# ---------------------------------------------------------------- config

def load_config(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        fail("读取 config 失败：%s" % exc, code="bad_config")


def cfg_str(cfg, key, default=""):
    env_value = os.environ.get("MCT_SECRET_" + key)
    if env_value:
        return env_value
    value = cfg.get(key, default)
    if value is None:
        return default
    return str(value)


def job_dir(cfg):
    path = Path(cfg["_meta"]["jobDir"]).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def cache_root():
    custom = os.environ.get("MCT_DATA_DIR", "").strip()
    if custom:
        return Path(custom).expanduser().resolve() / "Cache"
    return Path.home() / "Library" / "Caches" / "MacToolboxDemo"


def source_path(cfg):
    value = cfg_str(cfg, "image", "").strip()
    if not value:
        fail("没有选择图片", code="missing_image")
    path = Path(value).expanduser()
    if not path.is_file():
        fail("图片不存在：%s" % path, code="missing_image")
    return path


# ---------------------------------------------------------------- swift helper

def find_swiftc():
    for candidate in (
        shutil.which("swiftc"),
        "/usr/bin/swiftc",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
    ):
        if candidate and Path(candidate).is_file():
            return candidate
    xcrun = shutil.which("xcrun")
    if xcrun:
        try:
            result = subprocess.run([xcrun, "--find", "swiftc"],
                                    capture_output=True, text=True, timeout=10)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
        except Exception:
            pass
    return ""


def sdk_path():
    xcrun = shutil.which("xcrun")
    if not xcrun:
        return ""
    try:
        result = subprocess.run([xcrun, "--show-sdk-path"],
                                capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return ""


def source_digest():
    try:
        payload = SWIFT_SOURCE.read_bytes()
    except Exception as exc:
        fail("找不到 OCR 助手源码：%s" % exc, code="ocr_source_missing")
    swiftc = find_swiftc()
    version = ""
    if swiftc:
        try:
            version = subprocess.run([swiftc, "--version"], capture_output=True,
                                     text=True, timeout=10).stdout
        except Exception:
            version = ""
    digest = hashlib.sha256()
    digest.update(payload)
    digest.update(version.encode("utf-8", "replace"))
    return digest.hexdigest()[:16]


def helper_path():
    return cache_root() / "ocr" / ("ocr-%s" % source_digest())


def build_helper(force=False):
    target = helper_path()
    if not force and target.is_file() and os.access(target, os.X_OK):
        return target
    source = SWIFT_SOURCE
    if not source.is_file():
        fail("找不到 OCR 助手源码：%s" % source, code="ocr_source_missing")
    swiftc = find_swiftc()
    if not swiftc:
        fail("未找到 swiftc；请安装 Xcode Command Line Tools：xcode-select --install",
             code="no_swiftc")
    target.parent.mkdir(parents=True, exist_ok=True)
    lock_path = target.with_suffix(".lock")
    with open(lock_path, "w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
        except Exception:
            pass
        if not force and target.is_file() and os.access(target, os.X_OK):
            return target
        tmp = target.with_suffix(".tmp-%d" % os.getpid())
        module_cache = target.parent / "modulecache"
        compile_tmp = target.parent / "tmp"
        module_cache.mkdir(parents=True, exist_ok=True)
        compile_tmp.mkdir(parents=True, exist_ok=True)
        compile_env = dict(os.environ)
        # 沙箱/只读卷下默认 module cache 可能不可写；和 build_app.sh 一样显式落盘。
        compile_env["TMPDIR"] = str(compile_tmp)
        compile_env["CLANG_MODULE_CACHE_PATH"] = str(module_cache)
        compile_env["SWIFT_MODULE_CACHE_PATH"] = str(module_cache)
        command = [swiftc, "-O", "-disable-sandbox",
                   "-module-cache-path", str(module_cache)]
        sdk = sdk_path()
        if sdk:
            command.extend(["-sdk", sdk])
        machine = platform.machine()
        if machine == "arm64":
            command.extend(["-target", "arm64-apple-macos14.0"])
        elif machine in ("x86_64", "i386"):
            command.extend(["-target", "x86_64-apple-macos14.0"])
        command.extend([
            "-framework", "Vision",
            "-framework", "AppKit",
            "-framework", "ImageIO",
            "-o", str(tmp),
            str(source),
        ])
        log("编译 OCR 助手（首次使用需要几秒）…")
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=180, env=compile_env)
        if result.returncode != 0:
            try:
                tmp.unlink()
            except Exception:
                pass
            fail("编译 OCR 助手失败：swiftc 退出码 %s" % result.returncode,
                 code="ocr_helper_build_failed",
                 detail=clean(result.stderr or result.stdout)[-4000:])
        try:
            os.replace(tmp, target)
            os.chmod(target, 0o755)
        except Exception as exc:
            fail("安装 OCR 助手失败：%s" % exc, code="ocr_helper_install_failed")
    return target


def prepare_input(cfg, source):
    """PDF 用 macOS 原生 sips 栅格化第一页；其他格式交给 ImageIO。"""
    if source.suffix.lower() != ".pdf":
        return source
    sips = shutil.which("sips")
    if not sips:
        fail("处理 PDF 需要 sips（macOS 自带）", code="no_sips")
    target = job_dir(cfg) / "ocr-input.png"
    log("PDF 转 PNG（只取第一页）：%s" % source.name)
    result = subprocess.run(
        [sips, "-s", "format", "png", str(source), "--out", str(target)],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0 or not target.is_file():
        fail("PDF 转 PNG 失败", code="pdf_render_failed",
             detail=clean(result.stderr or result.stdout)[-2000:])
    return target


def recognize(cfg):
    source = source_path(cfg)
    helper = build_helper()
    prepared = prepare_input(cfg, source)
    language = cfg_str(cfg, "language", "auto").strip() or "auto"
    progress(0.35, "ocr", "运行 Vision OCR")
    command = [
        str(helper),
        "--image", str(prepared),
        "--language", language,
        "--format", "json",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        fail("OCR 超时（300s）", code="ocr_timeout")
    if result.returncode != 0:
        fail("OCR 助手执行失败", code="ocr_failed",
             detail=clean(result.stderr or result.stdout)[-3000:])
    try:
        payload = json.loads(result.stdout)
    except Exception as exc:
        fail("OCR 助手输出不是 JSON：%s" % exc, code="ocr_bad_output",
             detail=clean(result.stdout)[-2000:])
    if not payload.get("ok"):
        fail("OCR 未成功", code="ocr_failed", detail=str(payload)[:2000])
    return source, prepared, language, payload


def texts_for(payload, fmt):
    text = payload.get("text") or ""
    json_text = json.dumps(payload, ensure_ascii=False, indent=2)
    return text, json_text


def write_outputs(cfg, source, payload):
    fmt = cfg_str(cfg, "format", "txt").strip().lower()
    if fmt not in ("txt", "json", "both"):
        fmt = "txt"
    text, json_text = texts_for(payload, fmt)
    job = job_dir(cfg)
    created = []
    if fmt in ("txt", "both"):
        path = job / "ocr.txt"
        path.write_text(text + ("\n" if text and not text.endswith("\n") else ""),
                        encoding="utf-8")
        created.append(("text", "text", path, "OCR 文本"))
    if fmt in ("json", "both"):
        path = job / "ocr.json"
        path.write_text(json_text + "\n", encoding="utf-8")
        created.append(("json", "json", path, "OCR JSON（置信度/坐标）"))

    output_dir = cfg_str(cfg, "outputDir", "").strip()
    if output_dir:
        target_dir = Path(output_dir).expanduser()
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            fail("无法创建输出目录：%s" % exc, code="output_dir_failed")
        stem = source.stem
        if fmt in ("txt", "both"):
            target = target_dir / (stem + ".txt")
            target.write_text(text + ("\n" if text and not text.endswith("\n") else ""),
                              encoding="utf-8")
            created.append(("%s-text" % stem, "text", target, "OCR 文本（交付）"))
        if fmt in ("json", "both"):
            target = target_dir / (stem + ".json")
            target.write_text(json_text + "\n", encoding="utf-8")
            created.append(("%s-json" % stem, "json", target, "OCR JSON（交付）"))
    return created, fmt


def run(cfg):
    step("ocr", "识别图片文字", "running")
    progress(0.05, "ocr", "准备")
    source, prepared, language, payload = recognize(cfg)
    if payload.get("levelFallback"):
        log("当前系统 accurate 模型不可用，已回退到 fast", level="warn")
    if payload.get("languageFallback"):
        log("请求的语言不可用，已回退到系统默认语言", level="warn")
    created, fmt = write_outputs(cfg, source, payload)
    artifacts = [artifact(*item) for item in created]
    progress(1.0, "ocr", "完成")
    step("ocr", "识别图片文字", "done")
    lines = payload.get("lineCount") or len(payload.get("lines") or [])
    chars = payload.get("charCount") or len(payload.get("text") or "")
    summary = "识别 %d 行 / %d 字符（%s）" % (lines, chars, language)
    emit(type="result", ok=True, summary=summary, artifacts=artifacts)
    return 0


# ---------------------------------------------------------------- doctor / setup

def collect_checks(cfg):
    checks = []
    swiftc = find_swiftc()
    checks.append({
        "id": "swiftc",
        "label": "swiftc（OCR 助手编译）",
        "status": "ok" if swiftc else "fail",
        "detail": swiftc or "未找到；xcode-select --install",
        "fixCommand": "xcode-select --install",
        "fixable": not bool(swiftc),
    })
    sips = shutil.which("sips")
    checks.append({
        "id": "sips",
        "label": "sips（PDF / 原生解码）",
        "status": "ok" if sips else "warn",
        "detail": sips or "PDF 输入不可用",
        "fixable": False,
    })
    source = SWIFT_SOURCE
    checks.append({
        "id": "source",
        "label": "OCR 助手源码",
        "status": "ok" if source.is_file() else "fail",
        "detail": str(source),
        "fixable": False,
    })
    try:
        cache = cache_root() / "ocr"
        cache.mkdir(parents=True, exist_ok=True)
        probe = cache / ".write-test"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        checks.append({"id": "cache", "label": "OCR 缓存可写", "status": "ok",
                       "detail": str(cache), "fixable": False})
    except Exception as exc:
        checks.append({"id": "cache", "label": "OCR 缓存可写", "status": "fail",
                       "detail": str(exc), "fixable": False})
    try:
        job = job_dir(cfg)
        probe = job / ".write-test"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        checks.append({"id": "jobdir", "label": "任务目录可写", "status": "ok",
                       "detail": str(job), "fixable": False})
    except Exception as exc:
        checks.append({"id": "jobdir", "label": "任务目录可写", "status": "fail",
                       "detail": str(exc), "fixable": False})
    return checks


def doctor(cfg):
    checks = collect_checks(cfg)
    emit(type="env", checks=checks)
    missing = [item for item in checks if item["status"] == "fail"]
    emit(type="result", ok=True, summary="环境检测完成，缺失 %d 项" % len(missing))
    return 0


def setup(cfg):
    step("setup", "编译 OCR 助手", "running")
    try:
        build_helper(force=True)
        step("setup", "编译 OCR 助手", "done")
        checks = collect_checks(cfg)
        emit(type="env", checks=checks)
        emit(type="result", ok=True, summary="OCR 助手已编译并缓存")
    except SystemExit:
        raise
    except Exception as exc:
        step("setup", "编译 OCR 助手", "failed")
        fail("环境修复失败：%s" % exc, code="setup_failed")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run", "doctor", "setup"])
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = load_config(args.config)
    if "_meta" not in cfg:
        fail("config 缺少 _meta", code="bad_config")
    try:
        if args.command == "doctor":
            return doctor(cfg)
        if args.command == "setup":
            return setup(cfg)
        return run(cfg)
    except SystemExit:
        raise
    except Exception as exc:
        fail("OCR 工具异常：%s" % exc, code="internal_error")


if __name__ == "__main__":
    raise SystemExit(main())
