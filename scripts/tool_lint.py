#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 MacToolbox 工具包（tool.json + 脚本）。

用法：
  python3 scripts/tool_lint.py Tools/demo.echo.toolbox
  python3 scripts/tool_lint.py --all
  python3 scripts/tool_lint.py --all --json
  python3 scripts/tool_lint.py --all --strict   # Agent 标准缺失也算 error

退出码：0 无错误；1 存在 error；warning 不阻断。
校验规则集中在 scripts/toolbox_spec.py，与 mct validate 共用。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import toolbox_spec as spec  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", help="工具目录；省略时等同 --all")
    parser.add_argument("--all", action="store_true", help="扫描 Tools/ 和用户工具目录")
    parser.add_argument("--tools-dir", action="append", default=[],
                        help="额外的用户工具目录（可重复）")
    parser.add_argument("--strict", action="store_true",
                        help="把缺失 agent 元数据等 Agent 标准问题当作 error")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    issues = []
    paths = list(args.paths)
    if args.all or not paths:
        paths.append(str(spec.repo_root() / "Tools"))
        paths.extend(args.tools_dir)
        user_dir = spec.data_root() / "Tools"
        if user_dir.is_dir():
            paths.append(str(user_dir))
    elif args.tools_dir:
        paths.extend(args.tools_dir)

    tool_dirs = spec.collect_tool_dirs(paths, issues)
    seen_dirs = set()
    unique_dirs = []
    for directory in tool_dirs:
        key = str(directory.resolve())
        if key not in seen_dirs:
            seen_dirs.add(key)
            unique_dirs.append(directory)

    seen_ids = {}
    for tool_dir in unique_dirs:
        manifest = spec.load_manifest(tool_dir, issues)
        if manifest is None:
            continue
        issues.extend(spec.validate_manifest(
            manifest, tool_dir, strict=args.strict,
            check_files=True, check_python=True))
        tool_id = manifest.get("id")
        if tool_id in seen_ids:
            issues.append(spec.Issue(
                "warning", tool_dir,
                "工具 id 重复：%s；后扫描到的会覆盖 %s" % (tool_id, seen_ids[tool_id]),
                tool_id))
        seen_ids[tool_id] = tool_dir

    errors = [item for item in issues if item.is_error]
    warnings = [item for item in issues if not item.is_error]
    if args.json:
        print(json.dumps({
            "tools": [str(path) for path in unique_dirs],
            "errors": len(errors),
            "warnings": len(warnings),
            "issues": [item.as_dict() for item in issues],
        }, ensure_ascii=False, indent=2))
    else:
        for item in issues:
            print(item)
        print("checked %d tool(s): %d error(s), %d warning(s)"
              % (len(unique_dirs), len(errors), len(warnings)))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
