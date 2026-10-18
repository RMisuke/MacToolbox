#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MacToolbox 工具模板（Tool Protocol）。

复制整个 `_template.toolbox` 为 `<your.id>.toolbox`，然后改 tool.json 和本文件。
不要删除 stdout 的 JSONL 约定；调试信息写到 stderr。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def emit(**payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


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
    payload = {"type": "artifact", "id": artifact_id, "kind": kind, "path": str(path)}
    if label:
        payload["label"] = label
    emit(**payload)


def fail(message, code="failed"):
    emit(type="error", code=code, message=str(message))
    raise SystemExit(1)


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


def cfg_int(cfg, key, default):
    try:
        return int(float(cfg.get(key, default)))
    except (TypeError, ValueError):
        return default


def run(cfg):
    job_dir = Path(cfg["_meta"]["jobDir"])
    text = cfg_str(cfg, "text", "").strip()
    if not text:
        fail("text 不能为空", code="empty_text")

    repeat = cfg_int(cfg, "repeat", 1)
    repeat = max(1, min(10, repeat))
    uppercase = cfg.get("uppercase") is True or cfg_str(cfg, "uppercase").lower() in ("1", "true", "yes", "on")
    if uppercase:
        text = text.upper()

    step("build", "生成文本", "running")
    progress(0.15, "build", "准备输出")
    log("模板工具：重复 %d 次，大写=%s" % (repeat, "是" if uppercase else "否"))

    output_dir = cfg_str(cfg, "outputDir", "").strip()
    base = Path(output_dir).expanduser() if output_dir else job_dir
    base.mkdir(parents=True, exist_ok=True)
    target = base / "result.txt"
    target.write_text("\n".join([text] * repeat) + "\n", encoding="utf-8")

    artifact("result", "text", target, "生成文本")
    progress(1.0, "build", "完成")
    step("build", "生成文本", "done")
    emit(
        type="result",
        ok=True,
        summary="已生成 %s（%d 次）" % (target.name, repeat),
        artifacts=[
            {"id": "result", "kind": "text", "path": str(target), "label": "生成文本"}
        ],
    )
    return 0


def doctor(cfg):
    checks = [
        {
            "id": "python3",
            "label": "Python 3",
            "status": "ok" if sys.version_info >= (3, 8) else "fail",
            "detail": sys.version.split()[0],
            "fixable": False,
        },
        {
            "id": "jobdir",
            "label": "任务目录可写",
            "status": "ok" if Path(cfg["_meta"]["jobDir"]).is_dir() else "fail",
            "detail": cfg["_meta"]["jobDir"],
            "fixable": False,
        },
    ]
    emit(type="env", checks=checks)
    emit(type="result", ok=all(item["status"] == "ok" for item in checks), summary="模板环境检测完成")
    return 0


def setup(cfg):
    log("模板工具没有需要安装的额外依赖。")
    emit(type="env", checks=[{"id": "template", "label": "模板自检", "status": "ok", "fixable": False}])
    emit(type="result", ok=True, summary="无需修复")
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
        fail("模板工具异常：%s" % exc, code="exception")


if __name__ == "__main__":
    raise SystemExit(main())
