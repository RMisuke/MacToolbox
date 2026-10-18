#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Homebrew 工具的 Tool Protocol / CLI 实现。

GUI（nativeView=homebrew）仍由 SwiftUI 的 BrewManagerView 提供；
这个脚本只负责无头 CLI 与 Agent 路径，二者读取同一份 tool.json。

安全约定：
- status / outdated / list / search / info / doctor 只读；
- install / uninstall / upgrade / update / cleanup 必须 allowMutations=true；
- 所有输出都是 stdout JSONL，人类日志也包成 log 事件。
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

CURRENT = {"proc": None, "cancelled": False}
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
MUTATING_ACTIONS = {"install", "uninstall", "upgrade", "update", "cleanup"}


# ---------------------------------------------------------------- protocol

def emit(**payload):
    try:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    except Exception:
        pass


def log(message, level="info"):
    emit(type="log", level=level, message=str(message))


def step(step_id, title, state):
    emit(type="step", step=step_id, title=title, state=state)


def progress(fraction, step_id=None, message=None):
    payload = {"type": "progress", "fraction": max(0.0, min(1.0, float(fraction)))}
    if step_id:
        payload["step"] = step_id
    if message:
        payload["message"] = message
    emit(**payload)


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


# ---------------------------------------------------------------- config

def load_config(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:
        fail("读取 config 失败：%s" % exc, code="bad_config")


def cfg_str(cfg, key, default=""):
    value = cfg.get(key, default)
    if value is None:
        return default
    return str(value)


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


def clean(text):
    return ANSI_RE.sub("", text or "")


def brew_path():
    configured = os.environ.get("MCT_BREW_PATH", "").strip()
    if configured and Path(configured).is_file():
        return configured
    return shutil.which("brew") or ""


def brew_env():
    env = dict(os.environ)
    path = env.get("PATH", "")
    extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    env["PATH"] = ":".join(extra + [part for part in path.split(":") if part])
    env.setdefault("HOMEBREW_NO_AUTO_UPDATE", "1")
    env.setdefault("HOMEBREW_NO_ANALYTICS", "1")
    return env


def run_brew(args, timeout=300):
    brew = brew_path()
    if not brew:
        fail("未找到 Homebrew：请先安装 https://brew.sh", code="no_brew")
    command = [brew] + [str(item) for item in args]
    log("$ " + subprocess.list2cmdline(command))
    try:
        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            env=brew_env(),
            start_new_session=True,
        )
    except Exception as exc:
        fail("启动 brew 失败：%s" % exc, code="brew_failed")
    CURRENT["proc"] = proc
    lines = []
    deadline = time.time() + timeout if timeout else None
    stream_queue = queue.Queue()

    def pump():
        try:
            for raw in iter(proc.stdout.readline, ""):
                stream_queue.put(raw)
        finally:
            stream_queue.put(None)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    timed_out = False
    try:
        while True:
            if deadline and time.time() > deadline:
                timed_out = True
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    proc.terminate()
                break
            try:
                raw = stream_queue.get(timeout=0.2)
            except queue.Empty:
                if proc.poll() is not None and not reader.is_alive():
                    break
                continue
            if raw is None:
                break
            line = clean(raw.rstrip("\n"))
            lines.append(line)
            if line.strip():
                log(line)
        code = proc.wait()
    finally:
        CURRENT["proc"] = None
        try:
            proc.stdout.close()
        except Exception:
            pass
    if timed_out:
        fail("brew 命令超时（%ss）" % timeout, code="timeout")
    return code, lines


def write_output(cfg, name, text):
    job = job_dir(cfg)
    path = job / name
    path.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")
    output_dir = cfg_str(cfg, "outputDir", "").strip()
    copied = None
    if output_dir:
        target_dir = Path(output_dir).expanduser()
        target_dir.mkdir(parents=True, exist_ok=True)
        copied = target_dir / name
        copied.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    return path, copied


def artifact_for(cfg, artifact_id, kind, name, text, label):
    path, copied = write_output(cfg, name, text)
    item = artifact(artifact_id, kind, path, label)
    if copied:
        artifact(artifact_id + "-copy", kind, copied, label + "（副本）")
    return item


def parse_json_output(lines):
    text = "\n".join(lines)
    start = text.find("{")
    while start != -1:
        try:
            return json.loads(text[start:])
        except Exception:
            start = text.find("{", start + 1)
    return None


def require_package(cfg, action):
    package = cfg_str(cfg, "package", "").strip()
    if not package:
        fail("%s 需要 package" % action, code="missing_package")
    return package


def guard_mutation(cfg, action):
    if action in MUTATING_ACTIONS and not cfg_bool(cfg, "allowMutations", False):
        fail(
            "%s 会修改系统，请显式设置 allowMutations=true" % action,
            code="mutation_requires_confirmation",
            detail="CLI：--input allowMutations=true；GUI：在工具参数里打开「允许修改系统」。",
        )


# ---------------------------------------------------------------- actions

def action_status(cfg):
    code, version = run_brew(["--version"], timeout=30)
    if code != 0:
        fail("brew --version 失败", code="brew_failed", detail="\n".join(version))
    code, config = run_brew(["config"], timeout=60)
    lines = version + [""] + config
    payload = {"version": version[:3], "config": config}
    code2, outdated_lines = run_brew(["outdated", "--json=v2"], timeout=120)
    outdated = parse_json_output(outdated_lines) if code2 == 0 else None
    if outdated:
        formulas = outdated.get("formulae") or []
        casks = outdated.get("casks") or []
        payload["outdated"] = {"formulae": len(formulas), "casks": len(casks)}
        log("可更新：%d formula / %d cask" % (len(formulas), len(casks)))
    else:
        payload["outdated"] = {"formulae": 0, "casks": 0}
    item = artifact_for(cfg, "status", "json", "homebrew-status.json",
                           json.dumps(payload, ensure_ascii=False, indent=2), "Homebrew 状态")
    return "Homebrew %s；可更新 %d formula / %d cask" % (
        (version[0] if version else "unknown"),
        payload["outdated"]["formulae"], payload["outdated"]["casks"]), [item]


def action_outdated(cfg):
    code, lines = run_brew(["outdated", "--json=v2"], timeout=180)
    if code != 0:
        fail("brew outdated 失败", code="brew_failed", detail="\n".join(lines[-20:]))
    data = parse_json_output(lines) or {"formulae": [], "casks": []}
    formulas = data.get("formulae") or []
    casks = data.get("casks") or []
    text_lines = []
    for item in formulas:
        name = item.get("name") or item.get("full_name") or "?"
        current = item.get("installed_versions") or []
        latest = item.get("current_version") or item.get("version") or "?"
        text_lines.append("formula  %-40s %s -> %s" % (name, ",".join(current), latest))
    for item in casks:
        name = item.get("name") or item.get("token") or "?"
        current = item.get("installed_versions") or []
        latest = item.get("current_version") or item.get("version") or "?"
        text_lines.append("cask     %-40s %s -> %s" % (name, ",".join(current), latest))
    if not text_lines:
        text_lines = ["没有可更新的软件包。"]
    item = artifact_for(cfg, "outdated-json", "json", "homebrew-outdated.json",
                           json.dumps(data, ensure_ascii=False, indent=2), "可更新 JSON")
    item2 = artifact_for(cfg, "outdated", "text", "homebrew-outdated.txt",
                            "\n".join(text_lines), "可更新列表")
    return "可更新 %d formula / %d cask" % (len(formulas), len(casks)), [item, item2]


def action_list(cfg):
    code, formulas = run_brew(["list", "--versions"], timeout=180)
    code2, casks = run_brew(["list", "--cask", "--versions"], timeout=180)
    if code != 0 and code2 != 0:
        fail("brew list 失败", code="brew_failed")
    text = "== Formulae ==\n" + "\n".join(formulas)
    text += "\n\n== Casks ==\n" + "\n".join(casks)
    item = artifact_for(cfg, "installed", "text", "homebrew-installed.txt", text, "已安装列表")
    return "已安装 %d formula / %d cask" % (
        len([line for line in formulas if line.strip()]),
        len([line for line in casks if line.strip()])), [item]


def action_search(cfg):
    package = require_package(cfg, "search")
    code, lines = run_brew(["search", package], timeout=60)
    if code != 0:
        fail("brew search 失败", code="brew_failed", detail="\n".join(lines[-20:]))
    text = "\n".join(lines)
    item = artifact_for(cfg, "search", "text", "homebrew-search.txt",
                           text or "没有匹配结果。", "搜索结果")
    return "搜索「%s」完成" % package, [item]


def action_info(cfg):
    package = require_package(cfg, "info")
    args = ["info", "--json=v2"]
    if cfg_bool(cfg, "cask", False):
        args.append("--cask")
    args.append(package)
    code, lines = run_brew(args, timeout=60)
    if code != 0:
        fail("brew info 失败", code="brew_failed", detail="\n".join(lines[-20:]))
    data = parse_json_output(lines) or {}
    item = artifact_for(cfg, "info", "json", "homebrew-info.json",
                           json.dumps(data, ensure_ascii=False, indent=2), "软件包信息")
    return "已获取 %s 信息" % package, [item]


def action_install(cfg):
    guard_mutation(cfg, "install")
    package = require_package(cfg, "install")
    args = ["install"]
    if cfg_bool(cfg, "cask", False):
        args.append("--cask")
    args.append(package)
    code, lines = run_brew(args, timeout=1800)
    if code != 0:
        fail("brew install 失败", code="install_failed", detail="\n".join(lines[-30:]))
    item = artifact_for(cfg, "install-log", "text", "homebrew-install.log",
                           "\n".join(lines), "安装日志")
    return "已安装 %s" % package, [item]


def action_uninstall(cfg):
    guard_mutation(cfg, "uninstall")
    package = require_package(cfg, "uninstall")
    args = ["uninstall"]
    if cfg_bool(cfg, "cask", False):
        args.append("--cask")
    args.append(package)
    code, lines = run_brew(args, timeout=600)
    if code != 0:
        fail("brew uninstall 失败", code="uninstall_failed", detail="\n".join(lines[-30:]))
    item = artifact_for(cfg, "uninstall-log", "text", "homebrew-uninstall.log",
                           "\n".join(lines), "卸载日志")
    return "已卸载 %s" % package, [item]


def action_upgrade(cfg):
    guard_mutation(cfg, "upgrade")
    package = cfg_str(cfg, "package", "").strip()
    args = ["upgrade"]
    if cfg_bool(cfg, "cask", False):
        args.append("--cask")
    if package:
        args.append(package)
    code, lines = run_brew(args, timeout=3600)
    if code != 0:
        fail("brew upgrade 失败", code="upgrade_failed", detail="\n".join(lines[-30:]))
    item = artifact_for(cfg, "upgrade-log", "text", "homebrew-upgrade.log",
                           "\n".join(lines), "升级日志")
    return "升级完成%s" % (("：" + package) if package else "（全部）"), [item]


def action_doctor(cfg):
    code, lines = run_brew(["doctor"], timeout=300)
    item = artifact_for(cfg, "doctor-log", "text", "homebrew-doctor.txt",
                           "\n".join(lines), "brew doctor")
    if code != 0:
        log("brew doctor 返回非 0；请查看报告", level="warn")
    return "brew doctor 完成%s" % ("" if code == 0 else "（有警告）"), [item]


def action_update(cfg):
    guard_mutation(cfg, "update")
    code, lines = run_brew(["update"], timeout=900)
    if code != 0:
        fail("brew update 失败", code="update_failed", detail="\n".join(lines[-30:]))
    item = artifact_for(cfg, "update-log", "text", "homebrew-update.log",
                           "\n".join(lines), "brew update 日志")
    return "brew update 完成", [item]


def action_cleanup(cfg):
    guard_mutation(cfg, "cleanup")
    code, lines = run_brew(["cleanup"], timeout=900)
    if code != 0:
        fail("brew cleanup 失败", code="cleanup_failed", detail="\n".join(lines[-30:]))
    item = artifact_for(cfg, "cleanup-log", "text", "homebrew-cleanup.log",
                           "\n".join(lines), "brew cleanup 日志")
    return "brew cleanup 完成", [item]


ACTIONS = {
    "status": action_status,
    "outdated": action_outdated,
    "list": action_list,
    "search": action_search,
    "info": action_info,
    "install": action_install,
    "uninstall": action_uninstall,
    "upgrade": action_upgrade,
    "doctor": action_doctor,
    "update": action_update,
    "cleanup": action_cleanup,
}


# ---------------------------------------------------------------- entrypoints

def run(cfg):
    install_signals()
    action = cfg_str(cfg, "action", "status").strip().lower()
    handler = ACTIONS.get(action)
    if handler is None:
        fail("不支持的 action：%s（可选：%s）" % (action, ", ".join(sorted(ACTIONS))),
             code="unknown_action")
    step("homebrew", "Homebrew · %s" % action, "running")
    progress(0.05, "homebrew")
    summary, artifacts = handler(cfg)
    progress(1.0, "homebrew", "完成")
    step("homebrew", "Homebrew · %s" % action, "done")
    safe_artifacts = [
        item if isinstance(item, dict) else
        {"id": "artifact-%d" % index, "kind": "file", "path": str(item)}
        for index, item in enumerate(artifacts or [])
    ]
    emit(type="result", ok=True, summary=summary, artifacts=safe_artifacts)
    return 0


def collect_checks(cfg):
    checks = []
    brew = brew_path()
    checks.append({
        "id": "brew",
        "label": "Homebrew",
        "status": "ok" if brew else "fail",
        "detail": brew or "未找到 brew",
        "fixCommand": "https://brew.sh",
        "fixable": not bool(brew),
    })
    if brew:
        code, lines = run_brew(["--version"], timeout=30)
        checks.append({
            "id": "brew-version",
            "label": "brew --version",
            "status": "ok" if code == 0 else "fail",
            "detail": (lines[0] if lines else ""),
            "fixable": False,
        })
        code, lines = run_brew(["config"], timeout=60)
        prefix = next((line.split(":", 1)[1].strip() for line in lines
                       if line.upper().startswith("HOMEBREW_PREFIX")), "")
        checks.append({
            "id": "brew-prefix",
            "label": "Homebrew 前缀",
            "status": "ok" if prefix else "warn",
            "detail": prefix or "无法从 brew config 读取",
            "fixable": False,
        })
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
    checks = collect_checks(cfg)
    emit(type="env", checks=checks)
    brew = brew_path()
    if not brew:
        emit(type="result", ok=False,
             summary="未找到 Homebrew；请先安装 https://brew.sh，本工具不自动安装 brew")
        return 0
    emit(type="result", ok=True, summary="Homebrew 已就绪；不需要额外安装")
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
        fail("Homebrew 工具异常：%s" % exc, code="internal_error")


if __name__ == "__main__":
    raise SystemExit(main())
