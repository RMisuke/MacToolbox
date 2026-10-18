#!/usr/bin/env python3
"""Tool Protocol implementation for external.file-stats.

Subcommands:
    run     --config <config.json>
    doctor  --config <config.json>
    setup   --config <config.json>

Only the Python 3 standard library is used. stdout carries one JSON object per
line; human-readable messages and tracebacks go to stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import stat as stat_module
import sys
import tempfile
import time
import traceback
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Sequence, Tuple

TOOL_ID = "external.file-stats"
TOOL_VERSION = "0.1.0"
PROTOCOL_VERSION = "0.2"
MIN_PYTHON = (3, 8)
CHUNK_SIZE = 1024 * 1024
TEMP_PATHS = set()  # type: set[str]


class StatsToolError(Exception):
    """An expected tool failure that is reported through the protocol."""

    def __init__(
        self,
        message: str,
        code: str = "internal_error",
        exit_code: int = 1,
        detail: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.exit_code = exit_code
        self.detail = detail


class Terminated(Exception):
    """Raised by the SIGTERM handler."""


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="backslashreplace")
        except (AttributeError, ValueError):
            pass


def human_log(message: str) -> None:
    try:
        print("[{}] {}".format(TOOL_ID, message), file=sys.stderr, flush=True)
    except OSError:
        pass


def emit(event: Dict[str, Any]) -> None:
    """Write exactly one JSON object to stdout."""
    line = json.dumps(
        event,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    )
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def emit_log(message: str, level: str = "info") -> None:
    human_log(message)
    emit({"type": "log", "level": level, "message": message})


def emit_progress(
    fraction: float, step_id: Optional[str] = None, message: Optional[str] = None
) -> None:
    value = max(0.0, min(1.0, float(fraction)))
    event = {"type": "progress", "fraction": round(value, 4)}  # type: Dict[str, Any]
    if step_id:
        event["step"] = step_id
    if message:
        event["message"] = message
    emit(event)


def emit_step(
    step_id: str, title: str, state: str, message: Optional[str] = None
) -> None:
    event = {"type": "step", "step": step_id, "title": title, "state": state}
    if message:
        event["message"] = message
    emit(event)


def emit_artifact(
    artifact_id: str, kind: str, path: str, label: Optional[str] = None
) -> Dict[str, str]:
    item = {"id": artifact_id, "kind": kind, "path": path}
    if label:
        item["label"] = label
    event = dict(item)  # type: Dict[str, Any]
    event["type"] = "artifact"
    emit(event)
    return item


def emit_result(
    ok: bool, summary: str, artifacts: Optional[List[Dict[str, str]]] = None
) -> None:
    event = {"type": "result", "ok": bool(ok), "summary": summary}  # type: Dict[str, Any]
    if artifacts:
        event["artifacts"] = artifacts
    emit(event)


def emit_failure(error: StatsToolError) -> None:
    event = {"type": "error", "code": error.code, "message": error.message}
    if error.detail:
        event["detail"] = error.detail
    emit(event)
    emit_result(False, error.message)
    human_log("错误：{}".format(error.message))


def cleanup_temp_paths() -> None:
    for path in list(TEMP_PATHS):
        try:
            os.unlink(path)
        except OSError:
            pass
        TEMP_PATHS.discard(path)


def handle_sigterm(signum: int, frame: Any) -> None:
    raise Terminated()


def load_config(config_path: Optional[str]) -> Dict[str, Any]:
    if not config_path:
        raise StatsToolError(
            "run 需要 --config 参数指向 config.json。",
            code="config_error",
            exit_code=2,
        )
    try:
        with open(config_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        raise StatsToolError(
            "找不到配置文件：{}".format(config_path),
            code="config_error",
            exit_code=2,
        )
    except OSError as exc:
        raise StatsToolError(
            "无法读取配置文件：{}".format(exc),
            code="config_error",
            exit_code=2,
        )
    except json.JSONDecodeError as exc:
        raise StatsToolError(
            "config.json 不是合法 JSON：{}".format(exc),
            code="config_error",
            exit_code=2,
        )
    if not isinstance(payload, dict):
        raise StatsToolError(
            "config.json 顶层必须是 JSON 对象。",
            code="config_error",
            exit_code=2,
        )
    return payload


def load_optional_config(config_path: Optional[str]) -> Dict[str, Any]:
    if not config_path:
        return {}
    return load_config(config_path)


def get_meta(cfg: Dict[str, Any]) -> Dict[str, Any]:
    meta = cfg.get("_meta")
    if isinstance(meta, dict):
        return meta
    return {}


def get_job_dir(cfg: Dict[str, Any]) -> Optional[str]:
    raw = get_meta(cfg).get("jobDir")
    if isinstance(raw, str) and raw.strip():
        return os.path.abspath(os.path.expanduser(raw))
    return None


def config_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        text = value.strip().lower()
        if not text:
            return default
        return text in ("1", "true", "yes", "on", "y")
    return bool(value)


def local_timestamp(moment: float) -> Tuple[str, str]:
    utc = datetime.fromtimestamp(moment, tz=timezone.utc)
    local = datetime.fromtimestamp(moment).astimezone()
    utc_text = utc.isoformat(timespec="seconds").replace("+00:00", "Z")
    local_text = local.isoformat(timespec="seconds")
    return utc_text, local_text


def human_size(byte_count: int) -> str:
    if byte_count < 1024:
        return "{} B".format(byte_count)
    value = float(byte_count)
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
    index = 0
    while value >= 1024.0 and index < len(units) - 1:
        value /= 1024.0
        index += 1
    return "{:.2f} {}".format(value, units[index])


def resolve_output_dir(cfg: Dict[str, Any]) -> Tuple[str, str]:
    requested = cfg.get("outputDir")
    if isinstance(requested, str) and requested.strip():
        directory = os.path.abspath(os.path.expanduser(requested))
        source = "outputDir"
    else:
        job_dir = get_job_dir(cfg)
        if not job_dir:
            raise StatsToolError(
                "未指定 outputDir，且 config 缺少 _meta.jobDir，无法确定可写输出目录。",
                code="config_error",
                exit_code=2,
            )
        directory = job_dir
        source = "jobDir"

    try:
        os.makedirs(directory, exist_ok=True)
    except OSError as exc:
        raise StatsToolError(
            "无法创建输出目录：{}".format(exc),
            code="output_error",
            detail=directory,
        )
    if not os.path.isdir(directory):
        raise StatsToolError(
            "输出路径不是目录。",
            code="output_error",
            detail=directory,
        )
    assert_writable_dir(directory)
    return directory, source


def assert_writable_dir(directory: str) -> None:
    probe_fd = None
    probe_path = None
    try:
        probe_fd, probe_path = tempfile.mkstemp(
            prefix=".file-stats-write-test-", dir=directory
        )
    except OSError as exc:
        raise StatsToolError(
            "输出目录不可写：{}".format(exc),
            code="output_error",
            detail=directory,
        )
    finally:
        if probe_fd is not None:
            try:
                os.close(probe_fd)
            except OSError:
                pass
        if probe_path:
            try:
                os.unlink(probe_path)
            except OSError:
                pass


def inspect_input(path: str) -> os.stat_result:
    try:
        info = os.stat(path)
    except FileNotFoundError:
        raise StatsToolError(
            "目标文件不存在。",
            code="input_error",
            detail=path,
        )
    except OSError as exc:
        raise StatsToolError(
            "无法读取目标文件信息：{}".format(exc),
            code="input_error",
            detail=path,
        )
    if not stat_module.S_ISREG(info.st_mode):
        raise StatsToolError(
            "目标路径不是普通文件。",
            code="input_error",
            detail=path,
        )
    if not os.access(path, os.R_OK):
        raise StatsToolError(
            "目标文件不可读。",
            code="input_error",
            detail=path,
        )
    return info


def count_lines(path: str, expected_size: int) -> Tuple[int, int]:
    """Count logical lines by LF bytes; a final unterminated line counts."""
    newline_count = 0
    bytes_read = 0
    last_chunk_tail = b""
    last_fraction = -1.0

    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(CHUNK_SIZE)
            if not chunk:
                break
            bytes_read += len(chunk)
            newline_count += chunk.count(b"\n")
            last_chunk_tail = chunk[-1:]
            if expected_size > 0:
                fraction = 0.08 + 0.68 * min(bytes_read / float(expected_size), 1.0)
                if last_fraction < 0 or fraction - last_fraction >= 0.02:
                    emit_progress(
                        fraction,
                        "scan",
                        "已读取 {} 字节".format(bytes_read),
                    )
                    last_fraction = fraction

    if bytes_read > 0 and last_chunk_tail != b"\n":
        newline_count += 1
    return newline_count, bytes_read


def atomic_write_text(path: str, content: str) -> None:
    directory = os.path.dirname(path) or "."
    descriptor = None
    temp_path = None
    try:
        descriptor, temp_path = tempfile.mkstemp(
            prefix=".{}.".format(os.path.basename(path)),
            suffix=".tmp",
            dir=directory,
        )
        TEMP_PATHS.add(temp_path)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            descriptor = None
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        TEMP_PATHS.discard(temp_path)
    except OSError as exc:
        raise StatsToolError(
            "无法写入输出文件：{}".format(exc),
            code="output_error",
            detail=path,
        )
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temp_path:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
            TEMP_PATHS.discard(temp_path)


def build_text_report(stats: Dict[str, Any]) -> str:
    file_info = stats["file"]
    if file_info["lineCount"] is None:
        line_text = "未统计（includeLines=false）"
    else:
        line_text = str(file_info["lineCount"])
    lines = [
        "文件统计报告",
        "========================================",
        "文件: {}".format(file_info["path"]),
        "文件名: {}".format(file_info["name"]),
        "目录: {}".format(file_info["directory"]),
        "字节数: {} ({})".format(
            file_info["sizeBytes"], file_info["sizeHuman"]
        ),
        "行数: {}".format(line_text),
        "修改时间: {}".format(file_info["modifiedAtLocal"]),
        "修改时间 (UTC): {}".format(file_info["modifiedAt"]),
        "",
        "生成时间: {}".format(stats["generatedAtLocal"]),
        "生成工具: {} {}".format(stats["tool"]["id"], stats["tool"]["version"]),
    ]
    return "\n".join(lines) + "\n"


def cmd_run(config_path: Optional[str]) -> int:
    cfg = load_config(config_path)

    raw_file = cfg.get("file")
    if not isinstance(raw_file, str) or not raw_file.strip():
        raise StatsToolError(
            "缺少必填输入 file。",
            code="invalid_input",
            exit_code=2,
        )
    file_path = os.path.abspath(os.path.expanduser(raw_file))
    include_lines = config_bool(cfg.get("includeLines"), True)

    emit_step("prepare", "准备", "running")
    emit_progress(0.02, "prepare", "检查输入")
    emit_log("开始统计：{}".format(file_path))
    source_info = inspect_input(file_path)
    output_dir, output_source = resolve_output_dir(cfg)
    emit_log("输出目录：{}（来源：{}）".format(output_dir, output_source))

    json_path = os.path.join(output_dir, "stats.json")
    text_path = os.path.join(output_dir, "stats.txt")
    input_real = os.path.realpath(file_path)
    for target in (json_path, text_path):
        if os.path.realpath(target) == input_real:
            raise StatsToolError(
                "输出文件会覆盖输入文件，已拒绝执行。",
                code="output_error",
                detail=target,
            )

    emit_progress(0.05, "prepare", "输入检查完成")
    emit_step("prepare", "准备", "done")

    emit_step("scan", "读取文件", "running")
    if include_lines:
        emit_log("行数统计：开启（按 LF 换行符计数）")
        line_count, bytes_read = count_lines(file_path, source_info.st_size)
        emit_progress(0.78, "scan", "行数统计完成")
        human_log("已读取 {} 字节，统计到 {} 行".format(bytes_read, line_count))
        try:
            after_info = os.stat(file_path)
            if (
                after_info.st_size != source_info.st_size
                or after_info.st_mtime_ns != source_info.st_mtime_ns
            ):
                emit_log(
                    "警告：读取期间目标文件发生变化，统计结果可能不一致。",
                    level="warn",
                )
        except OSError:
            pass
    else:
        line_count = None
        emit_log("行数统计：关闭，仅读取文件元信息")
        emit_progress(0.78, "scan", "跳过行数统计")
    emit_step("scan", "读取文件", "done")

    now = time.time()
    generated_utc, generated_local = local_timestamp(now)
    modified_utc, modified_local = local_timestamp(source_info.st_mtime)
    size_bytes = int(source_info.st_size)

    stats = {
        "tool": {
            "id": TOOL_ID,
            "version": TOOL_VERSION,
            "protocolVersion": PROTOCOL_VERSION,
        },
        "generatedAt": generated_utc,
        "generatedAtLocal": generated_local,
        "file": {
            "path": file_path,
            "name": os.path.basename(file_path),
            "directory": os.path.dirname(file_path),
            "sizeBytes": size_bytes,
            "sizeHuman": human_size(size_bytes),
            "lineCount": line_count,
            "includeLines": include_lines,
            "modifiedAt": modified_utc,
            "modifiedAtLocal": modified_local,
            "modifiedUnix": round(source_info.st_mtime, 6),
        },
    }

    emit_step("write", "写入产物", "running")
    emit_progress(0.82, "write", "生成 stats.json")
    json_text = json.dumps(
        stats,
        ensure_ascii=False,
        indent=2,
        allow_nan=False,
    ) + "\n"
    atomic_write_text(json_path, json_text)

    emit_progress(0.90, "write", "生成 stats.txt")
    atomic_write_text(text_path, build_text_report(stats))

    emit_log("已写入：{}".format(json_path))
    emit_log("已写入：{}".format(text_path))
    emit_step("write", "写入产物", "done")

    artifacts = [
        emit_artifact("statsJson", "json", json_path, "统计 JSON"),
        emit_artifact("statsText", "text", text_path, "统计报告"),
    ]

    if line_count is None:
        summary = "已统计 {}：{} 字节（未统计行数）。".format(
            stats["file"]["name"], size_bytes
        )
    else:
        summary = "已统计 {}：{} 字节，{} 行。".format(
            stats["file"]["name"], size_bytes, line_count
        )

    emit_progress(1.0, "write", "完成")
    emit_result(True, summary, artifacts)
    human_log("完成：{}".format(summary))
    return 0


def check_python() -> Dict[str, Any]:
    version = "{}.{}.{}".format(*sys.version_info[:3])
    ok = sys.version_info[:2] >= MIN_PYTHON
    check = {
        "id": "python",
        "label": "Python 3",
        "status": "ok" if ok else "fail",
        "detail": "{} ({})".format(version, sys.executable),
    }  # type: Dict[str, Any]
    if not ok:
        check["detail"] = "{}；需要 Python {}.{}+".format(
            check["detail"], MIN_PYTHON[0], MIN_PYTHON[1]
        )
        check["fixable"] = False
    return check


def check_manifest(cfg: Dict[str, Any]) -> Dict[str, Any]:
    tool_dir = get_meta(cfg).get("toolDir")
    if not isinstance(tool_dir, str) or not tool_dir.strip():
        tool_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    manifest_path = os.path.join(os.path.abspath(tool_dir), "tool.json")
    if not os.path.isfile(manifest_path):
        return {
            "id": "manifest",
            "label": "工具清单",
            "status": "fail",
            "detail": "找不到 {}".format(manifest_path),
            "fixable": False,
        }
    try:
        with open(manifest_path, "r", encoding="utf-8") as handle:
            json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        return {
            "id": "manifest",
            "label": "工具清单",
            "status": "fail",
            "detail": "tool.json 不可用：{}".format(exc),
            "fixable": False,
        }
    return {
        "id": "manifest",
        "label": "工具清单",
        "status": "ok",
        "detail": manifest_path,
    }


def check_input_file(cfg: Dict[str, Any]) -> Dict[str, Any]:
    raw = cfg.get("file")
    if not isinstance(raw, str) or not raw.strip():
        return {
            "id": "inputFile",
            "label": "目标文件",
            "status": "warn",
            "detail": "未提供 file（run 时为必填）",
        }
    path = os.path.abspath(os.path.expanduser(raw))
    try:
        info = os.stat(path)
    except FileNotFoundError:
        return {
            "id": "inputFile",
            "label": "目标文件",
            "status": "fail",
            "detail": "文件不存在：{}".format(path),
        }
    except OSError as exc:
        return {
            "id": "inputFile",
            "label": "目标文件",
            "status": "fail",
            "detail": "无法访问：{}".format(exc),
        }
    if not stat_module.S_ISREG(info.st_mode):
        return {
            "id": "inputFile",
            "label": "目标文件",
            "status": "fail",
            "detail": "不是普通文件：{}".format(path),
        }
    if not os.access(path, os.R_OK):
        return {
            "id": "inputFile",
            "label": "目标文件",
            "status": "fail",
            "detail": "文件不可读：{}".format(path),
        }
    return {
        "id": "inputFile",
        "label": "目标文件",
        "status": "ok",
        "detail": "{}（{} 字节，可读）".format(path, info.st_size),
    }


def check_output_location(cfg: Dict[str, Any]) -> Dict[str, Any]:
    requested = cfg.get("outputDir")
    if isinstance(requested, str) and requested.strip():
        directory = os.path.abspath(os.path.expanduser(requested))
        if not os.path.exists(directory):
            return {
                "id": "output",
                "label": "输出目录",
                "status": "warn",
                "detail": "目录不存在，run 时会尝试创建：{}".format(directory),
            }
        if not os.path.isdir(directory):
            return {
                "id": "output",
                "label": "输出目录",
                "status": "fail",
                "detail": "路径不是目录：{}".format(directory),
            }
        if not os.access(directory, os.W_OK):
            return {
                "id": "output",
                "label": "输出目录",
                "status": "fail",
                "detail": "目录不可写：{}".format(directory),
            }
        return {
            "id": "output",
            "label": "输出目录",
            "status": "ok",
            "detail": "可写：{}".format(directory),
        }

    job_dir = get_job_dir(cfg)
    if not job_dir:
        return {
            "id": "output",
            "label": "输出目录",
            "status": "warn",
            "detail": "未指定 outputDir，且 config 缺少 _meta.jobDir",
        }
    if not os.path.exists(job_dir):
        return {
            "id": "output",
            "label": "输出目录",
            "status": "warn",
            "detail": "任务目录不存在，run 时会尝试创建：{}".format(job_dir),
        }
    if not os.path.isdir(job_dir) or not os.access(job_dir, os.W_OK):
        return {
            "id": "output",
            "label": "输出目录",
            "status": "fail",
            "detail": "任务目录不可写：{}".format(job_dir),
        }
    return {
        "id": "output",
        "label": "输出目录",
        "status": "ok",
        "detail": "未指定 outputDir，将写入任务目录：{}".format(job_dir),
    }


def cmd_doctor(config_path: Optional[str]) -> int:
    cfg = load_optional_config(config_path)
    if not config_path:
        emit_log("未提供 --config，仅检查基础环境。", level="warn")

    checks = [
        check_python(),
        check_manifest(cfg),
        check_input_file(cfg),
        check_output_location(cfg),
    ]
    emit({"type": "env", "checks": checks})

    failures = [item for item in checks if item["status"] == "fail"]
    warnings = [item for item in checks if item["status"] == "warn"]
    emit_log(
        "环境检测：{} 项通过，{} 项警告，{} 项失败".format(
            len(checks) - len(failures) - len(warnings),
            len(warnings),
            len(failures),
        )
    )

    if failures:
        summary = "环境检测完成：{} 项需要处理。".format(len(failures))
    elif warnings:
        summary = "环境检测完成：{} 项警告。".format(len(warnings))
    else:
        summary = "环境检测完成：全部通过。"
    emit_result(True, summary)
    return 0


def cmd_setup(config_path: Optional[str]) -> int:
    cfg = load_optional_config(config_path)
    emit_log("setup：本工具仅使用 Python 标准库，无需安装外部依赖。")
    checks = [check_python(), check_manifest(cfg)]
    emit({"type": "env", "checks": checks})
    failures = [item for item in checks if item["status"] == "fail"]
    if failures:
        emit_result(
            False,
            "环境不满足要求：{} 项失败；setup 无法自动修复。".format(len(failures)),
        )
        human_log("setup 失败：环境不满足要求。")
        return 1
    emit_result(True, "无需安装：Python 标准库与工具清单均可用。")
    human_log("setup 完成：无需安装。")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tool.py",
        description="external.file-stats Tool Protocol implementation",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (
        ("run", "统计文件并写出 stats.json / stats.txt"),
        ("doctor", "检测 Python、工具清单、输入文件与输出目录"),
        ("setup", "确认标准库环境（无需安装）"),
    ):
        subparser = subparsers.add_parser(name, help=help_text)
        subparser.add_argument(
            "--config",
            default=None,
            help="由 mct / App 生成的 config.json 路径",
        )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    configure_stdio()
    signal.signal(signal.SIGTERM, handle_sigterm)
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "run":
            return cmd_run(args.config)
        if args.command == "doctor":
            return cmd_doctor(args.config)
        if args.command == "setup":
            return cmd_setup(args.config)
        parser.error("未知子命令：{}".format(args.command))
        return 2
    except StatsToolError as exc:
        emit_failure(exc)
        return exc.exit_code
    except Terminated:
        cleanup_temp_paths()
        human_log("收到 SIGTERM，已停止。")
        return 143
    except KeyboardInterrupt:
        cleanup_temp_paths()
        human_log("收到中断，已停止。")
        return 130
    except Exception as exc:  # noqa: BLE001 - last-resort protocol error
        cleanup_temp_paths()
        detail = "{}: {}".format(type(exc).__name__, exc)
        emit_failure(
            StatsToolError(
                "未预期的内部错误。",
                code="internal_error",
                detail=detail,
            )
        )
        human_log(traceback.format_exc())
        return 1


if __name__ == "__main__":
    sys.exit(main())
