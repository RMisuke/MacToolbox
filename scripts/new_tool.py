#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 _template.toolbox 生成一个新的用户工具包。

用法：
  python3 scripts/new_tool.py --id demo.echo --name "回显" --category "示例"
  python3 scripts/new_tool.py --id demo.echo --name "回显" --tools-dir /tmp/Tools
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def default_tools_dir() -> Path:
    custom = os.environ.get("MCT_DATA_DIR", "").strip()
    if custom:
        return Path(custom).expanduser() / "Tools"
    return Path.home() / "Library" / "Application Support" / "MacToolboxDemo" / "Tools"


def fail(message: str) -> "None":
    print("ERROR: " + message, file=sys.stderr)
    raise SystemExit(1)


def find_template(explicit: str) -> Path:
    if explicit:
        path = Path(explicit).expanduser()
        if path.is_dir():
            return path
        fail("模板目录不存在：%s" % path)
    for candidate in (
        ROOT / "Tools" / "_template.toolbox",
        Path.cwd() / "Tools" / "_template.toolbox",
    ):
        if candidate.is_dir():
            return candidate
    fail("找不到 Tools/_template.toolbox；请用 --template 指定")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True, help="反向域名风格，例如 demo.echo")
    parser.add_argument("--name", required=True, help="显示名")
    parser.add_argument("--category", default="示例", help="分类")
    parser.add_argument("--summary", default="", help="一句话说明")
    parser.add_argument("--tools-dir", default="", help="工具根目录（默认用户工具目录）")
    parser.add_argument("--template", default="", help="模板目录")
    args = parser.parse_args()

    tool_id = args.id.strip()
    name = args.name.strip()
    category = args.category.strip() or "示例"
    summary = args.summary.strip() or (name + "（由模板创建）")

    if not ID_RE.match(tool_id):
        fail("id 只能使用小写字母、数字、点、下划线和短横线，且不能以符号开头：%s" % tool_id)
    if not name:
        fail("name 不能为空")

    template = find_template(args.template)
    tools_dir = Path(args.tools_dir).expanduser() if args.tools_dir else default_tools_dir()
    tools_dir.mkdir(parents=True, exist_ok=True)
    destination = tools_dir / (tool_id + ".toolbox")
    if destination.exists():
        fail("目标已存在：%s" % destination)

    tmp = tools_dir / (".new-" + tool_id + "-" + str(int(time.time())))
    if tmp.exists():
        shutil.rmtree(tmp)
    shutil.copytree(template, tmp)

    replacements = {
        "__TOOL_ID__": tool_id,
        "__TOOL_NAME__": name,
        "__TOOL_CATEGORY__": category,
        "__TOOL_SUMMARY__": summary,
    }
    for path in tmp.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix == ".json":
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except Exception as exc:
                shutil.rmtree(tmp, ignore_errors=True)
                fail("模板 JSON 无效：%s" % exc)
            if path.name == "tool.json":
                payload["id"] = tool_id
                payload["name"] = name
                payload["category"] = category
                payload["summary"] = summary
                agent = payload.get("agent")
                if isinstance(agent, dict):
                    if agent.get("capability") in (None, "", "__TOOL_ID__"):
                        agent["capability"] = tool_id
                    description = agent.get("description")
                    if isinstance(description, str):
                        agent["description"] = (description
                                                .replace("__TOOL_ID__", tool_id)
                                                .replace("__TOOL_SUMMARY__", summary))
            write_text(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        elif path.suffix in (".py", ".md", ".txt", ".sh"):
            text = path.read_text(encoding="utf-8")
            for key, value in replacements.items():
                text = text.replace(key, value)
            write_text(path, text)
            if path.suffix == ".py":
                path.chmod(0o755)

    tmp.rename(destination)
    print(destination)
    print("next: python3 scripts/tool_lint.py %s" % destination)
    print("then: 在 App「工具管理」点「重新扫描」，或重启 App")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
