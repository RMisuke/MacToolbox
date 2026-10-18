#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mct — MacToolbox 统一工具 CLI / Agent 入口。

它把「发现工具 → 读 manifest → 生成输入 → 建任务目录 → 跑 Tool Protocol →
汇总产物」收敛成一个稳定接口，GUI 与 Agent 共用同一套 `tool.json` 契约。

常用命令：
  mct list --json
  mct describe media.image-convert --json
  mct schema media.image-convert
  mct doctor media.subtitle --json
  mct run media.image-convert --input image=/tmp/a.png --input format=webp
  mct batch media.video-convert --input video=/tmp/videos --output-dir /tmp/out
  mct resume --job ~/Library/Application\\ Support/MacToolboxDemo/Jobs/<id>
  mct mcp                      # MCP stdio server（tools/list + tools/call）

退出码：
  0 成功；1 工具失败；2 参数/契约错误；3 工具不存在；
  4 超时；5 取消；6 等待人工检查点。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import queue
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agent_jobs as agent_state  # noqa: E402
import toolbox_spec as spec  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

EXIT_OK = 0
EXIT_TOOL_FAILED = 1
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_TIMEOUT = 4
EXIT_CANCELLED = 5
EXIT_WAIT_CHECKPOINT = 6

KEYCHAIN_SERVICE = "com.chensinuo.mactoolbox.demo.secrets"

_CURRENT_PROC = None
_CANCELLED = False


class MCTError(Exception):
    def __init__(self, message, exit_code=EXIT_USAGE, payload=None):
        super().__init__(message)
        self.message = message
        self.exit_code = exit_code
        self.payload = payload or {}


# ---------------------------------------------------------------- output

def eprint(*args):
    print(*args, file=sys.stderr)


def print_json(data):
    print(json.dumps(data, ensure_ascii=False, indent=2))


def redact_values(entry, values):
    result = dict(values)
    for field in entry.inputs:
        if isinstance(field, dict) and field.get("type") == "secret":
            result[field.get("key")] = "***" if values.get(field.get("key")) else ""
    return result


def fail(args, message, exit_code=EXIT_USAGE, extra=None):
    payload = {
        "ok": False,
        "error": message,
        "exitCode": exit_code,
    }
    if extra:
        payload.update(extra)
    if getattr(args, "json", False) or getattr(args, "jsonl", False):
        print_json(payload)
    else:
        eprint("error: " + message)
    return exit_code


# ---------------------------------------------------------------- catalog

def load_catalog(args):
    explicit = getattr(args, "tools_dir", None) or []
    return spec.discover(explicit=explicit, check_files=False, check_python=False)


def require_entry(args, tool_id):
    catalog = load_catalog(args)
    entry = catalog.get(tool_id)
    if entry is None:
        known = ", ".join(item.id for item in catalog.tools) or "（无）"
        raise MCTError(
            "找不到工具：%s。可用工具：%s" % (tool_id, known),
            EXIT_NOT_FOUND,
        )
    return catalog, entry


def _search_roots(args):
    roots = [spec.repo_root() / "Tools", spec.data_root() / "Tools"]
    for raw in getattr(args, "tools_dir", None) or []:
        roots.append(Path(raw).expanduser())
    return roots


# ---------------------------------------------------------------- inputs / secrets

def _parse_scalar(text):
    if text == "":
        return ""
    lowered = text.strip().lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if text[:1] in ("{", "["):
        try:
            return json.loads(text)
        except Exception:
            return text
    return text


def read_inputs_json(raw):
    if raw is None:
        return {}
    text = raw
    if raw == "-":
        text = sys.stdin.read()
    elif raw.startswith("@"):
        text = Path(raw[1:]).expanduser().read_text(encoding="utf-8")
    try:
        data = json.loads(text)
    except Exception as exc:
        raise MCTError("--inputs-json 不是合法 JSON：%s" % exc)
    if not isinstance(data, dict):
        raise MCTError("--inputs-json 必须是 object")
    return data


def parse_raw_inputs(args, require_existing=True):
    raw = {}
    if args.inputs_json:
        raw.update(read_inputs_json(args.inputs_json))
    for item in args.input or []:
        if "=" not in item:
            raise MCTError("--input 需要 key=value 形式：%r" % item)
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise MCTError("--input 的 key 不能为空")
        raw[key] = _parse_scalar(value)
    if args.preset:
        preset_field = next((field for field in args._entry.inputs
                             if isinstance(field, dict) and field.get("type") == "preset"),
                            None)
        if preset_field:
            raw[preset_field.get("key")] = args.preset
    return raw


def resolve_secrets(entry, explicit, use_keychain=True):
    values = dict(explicit or {})
    for field in entry.inputs:
        if not isinstance(field, dict) or field.get("type") != "secret":
            continue
        key = field.get("key")
        if values.get(key):
            continue
        env_value = os.environ.get("MCT_SECRET_" + str(key), "")
        if env_value:
            values[key] = env_value
            continue
        if use_keychain:
            account = "%s.%s" % (entry.id, key)
            try:
                result = subprocess.run(
                    ["/usr/bin/security", "find-generic-password",
                     "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
                    capture_output=True, text=True, timeout=5,
                )
                if result.returncode == 0 and result.stdout.strip():
                    values[key] = result.stdout.strip()
            except Exception:
                pass
    return {key: value for key, value in values.items() if value}


def normalize_or_fail(args, entry, raw, require=True, check_files=True):
    values, secrets, errors = spec.normalize_values(
        entry, raw, preset_id=args.preset,
        require=require, check_files=check_files,
    )
    if errors:
        raise MCTError("输入校验失败：\n- " + "\n- ".join(errors), EXIT_USAGE,
                       {"validationErrors": errors})
    explicit = dict(secrets)
    for item in getattr(args, "secret", None) or []:
        if "=" not in item:
            raise MCTError("--secret 需要 key=value 形式：%r" % item)
        key, value = item.split("=", 1)
        explicit[key.strip()] = value
    secrets = resolve_secrets(
        entry, explicit, use_keychain=not getattr(args, "no_keychain", False))
    return values, secrets


# ---------------------------------------------------------------- execution

def augment_path():
    home = str(Path.home())
    candidates = [
        home + "/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/Library/Frameworks/Python.framework/Versions/Current/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    existing = os.environ.get("PATH", "")
    merged = candidates + existing.split(":") if existing else candidates
    seen, result = set(), []
    for item in merged:
        if item and item not in seen:
            seen.add(item)
            result.append(item)
    return ":".join(result)


def build_environment(entry, job_dir, config_path, secrets, values):
    env = dict(os.environ)
    env["PATH"] = augment_path()
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    env["TOOLBOX_TOOL_DIR"] = str(entry.directory)
    env["TOOLBOX_JOB_DIR"] = str(job_dir)
    env["TOOLBOX_CONFIG"] = str(config_path)
    env["TOOLBOX_TMPDIR"] = str(Path(job_dir) / "tmp")
    env["MCT_JOB_DIR"] = str(job_dir)
    Path(env["TOOLBOX_TMPDIR"]).mkdir(parents=True, exist_ok=True)
    for key, value in secrets.items():
        env["MCT_SECRET_" + str(key)] = value
    jieba = values.get("jiebaLib")
    if isinstance(jieba, str) and jieba:
        env["SUBTITLE_JIEBA_LIB"] = jieba
    return env


def _kill_process_tree(proc, force=False):
    if proc is None or proc.poll() is not None:
        return
    sig = signal.SIGKILL if force else signal.SIGTERM
    try:
        os.killpg(os.getpgid(proc.pid), sig)
    except Exception:
        try:
            proc.kill() if force else proc.terminate()
        except Exception:
            pass


def _signal_handler(signum, frame):
    global _CANCELLED
    _CANCELLED = True
    _kill_process_tree(_CURRENT_PROC, force=False)


def install_signal_handlers():
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)


def _iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def make_reporter(entry, job_dir, values, source="cli", batch_id=None,
                  batch_index=None, batch_total=None, title=None):
    label = None
    for field in entry.inputs:
        if not isinstance(field, dict) or field.get("type") not in ("file", "directory"):
            continue
        value = values.get(field.get("key"))
        if isinstance(value, str) and value:
            label = Path(value).name
            break
    return agent_state.AgentJobReporter(
        entry.id,
        entry.name,
        job_dir,
        source=source,
        resources=entry.manifest.get("resources") or [],
        item_label=label,
        title=title or (entry.name + (" · " + label if label else "")),
        batch_id=batch_id,
        batch_index=batch_index,
        batch_total=batch_total,
    )


def acquire_resource_locks(entry, args, reporter, on_wait=None, cancel_event=None):
    resources = [str(item).lower() for item in entry.manifest.get("resources") or []]
    if not resources or getattr(args, "no_locks", False):
        reporter.set_status("running")
        return None
    timeout = getattr(args, "lock_timeout", None) or 3600
    reporter.set_status("queued", "等待资源：%s" % ", ".join(sorted(set(resources))))
    locks = spec.ResourceLocks(resources, timeout=timeout)
    last_notice = [0.0]

    def notify_wait(resource, elapsed):
        now = time.time()
        if now - last_notice[0] >= 2:
            last_notice[0] = now
            message = "等待 %s 资源（已 %ds）" % (resource, int(elapsed))
            reporter.set_status("queued", message)
            if on_wait is not None:
                try:
                    on_wait(message)
                except Exception:
                    pass

    try:
        locks.acquire(on_wait=notify_wait, cancel_event=cancel_event)
    except spec.ResourceCancelled:
        reporter.set_status("cancelled", "等待资源时已取消")
        raise MCTError("Request cancelled", EXIT_CANCELLED)
    except spec.ResourceTimeout as exc:
        reporter.set_status("failed", str(exc), error=str(exc))
        raise MCTError(str(exc), EXIT_TOOL_FAILED,
                       {"jobDir": str(getattr(reporter, "root", ""))})
    reporter.set_status("running")
    return locks


def execute(entry, values, secrets, job_dir, config_path, args,
            kind="run", timeout=3600, checkpoint_policy=None,
            quiet=False, jsonl=False, reporter=None, cancel_event=None,
            on_progress=None, on_log=None):
    """启动工具进程，消费 JSONL 事件并汇总。返回结果 dict。"""
    global _CURRENT_PROC, _CANCELLED
    manifest = entry.manifest
    spec_obj = entry.run if kind == "run" else manifest.get(kind)
    if not isinstance(spec_obj, dict):
        raise MCTError("工具没有 %s 命令" % kind, EXIT_USAGE)

    command = spec.display_command(
        spec_obj, entry.directory, entry.id, job_dir=job_dir, config_file=config_path)
    if not command:
        raise MCTError("%s.command 为空" % kind, EXIT_USAGE)

    env = build_environment(entry, job_dir, config_path, secrets, values)
    policy = checkpoint_policy or "manual"
    started = time.time()
    state = {
        "status": "running",
        "exitCode": None,
        "summary": None,
        "error": None,
        "artifacts": [],
        "checks": [],
        "events": [],
        "stderrTail": [],
        "checkpoint": None,
        "sawResult": False,
        "resultOK": None,
        "timedOut": False,
    }
    _CANCELLED = False
    _CURRENT_PROC = None

    if not quiet and not jsonl:
        eprint("任务目录：%s" % job_dir)
        eprint("启动：%s" % " ".join(shlex.quote(part) for part in command))

    try:
        proc = subprocess.Popen(
            command,
            cwd=str(job_dir),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            start_new_session=True,
        )
    except Exception as exc:
        state["status"] = "failed"
        state["error"] = "启动失败：%s" % exc
        return _finish_state(state, command, job_dir, started, config_path, args,
                             reporter=reporter)

    _CURRENT_PROC = proc
    if reporter is not None:
        try:
            reporter.set_pid(proc.pid)
        except Exception:
            pass
    line_queue = queue.Queue()

    def pump(stream, channel):
        try:
            for raw in iter(stream.readline, ""):
                line_queue.put((channel, raw.rstrip("\n")))
        finally:
            line_queue.put((channel, None))

    threads = [
        threading.Thread(target=pump, args=(proc.stdout, "stdout"), daemon=True),
        threading.Thread(target=pump, args=(proc.stderr, "stderr"), daemon=True),
    ]
    for thread in threads:
        thread.start()

    eof = {"stdout": False, "stderr": False}
    last_progress = -1.0
    deferring = False

    def emit_event(event):
        state["events"].append(event)
        if reporter is not None:
            try:
                reporter.event(event)
            except Exception:
                pass
        if jsonl:
            print(json.dumps(event, ensure_ascii=False))
            sys.stdout.flush()

    def send_continue(checkpoint_id):
        if proc.poll() is not None or proc.stdin is None:
            return
        try:
            message = json.dumps({"type": "continue", "checkpoint": checkpoint_id},
                                 ensure_ascii=False)
            proc.stdin.write(message + "\n")
            proc.stdin.flush()
        except Exception:
            pass

    def normalize_artifact_path(path):
        text = str(path)
        candidate = Path(text).expanduser()
        if not candidate.is_absolute():
            candidate = Path(job_dir) / candidate
        return str(candidate)

    def handle_stdout(line):
        nonlocal last_progress
        try:
            event = json.loads(line)
        except Exception:
            if jsonl:
                emit_event({"type": "raw", "line": line})
            elif not quiet:
                eprint("[stdout] " + line)
            return
        if not isinstance(event, dict):
            return
        emit_event(event)
        etype = event.get("type")
        if etype == "log":
            if on_log is not None:
                try:
                    on_log(event.get("level") or "info", event.get("message") or "")
                except Exception:
                    pass
            if not quiet and not jsonl:
                eprint("[%s] %s" % (event.get("level") or "info", event.get("message") or ""))
        elif etype == "progress":
            fraction = event.get("fraction")
            if isinstance(fraction, (int, float)):
                value = max(0.0, min(1.0, float(fraction)))
                if on_progress is not None:
                    try:
                        on_progress(value, event.get("message") or event.get("step") or "")
                    except Exception:
                        pass
                if not quiet and not jsonl and (value >= last_progress + 0.05 or value >= 1.0):
                    last_progress = value
                    suffix = event.get("message") or event.get("step") or ""
                    eprint("[%3d%%] %s" % (int(value * 100), suffix))
        elif etype == "step":
            if not quiet and not jsonl:
                state_name = event.get("state") or "running"
                mark = {"running": "▶", "done": "✓", "failed": "✗"}.get(state_name, "•")
                eprint("%s %s" % (mark, event.get("title") or event.get("step") or ""))
        elif etype == "artifact":
            path = event.get("path")
            if path:
                resolved = normalize_artifact_path(path)
                item = {
                    "id": event.get("id") or event.get("kind") or resolved,
                    "kind": event.get("kind") or "file",
                    "path": resolved,
                    "label": event.get("label") or event.get("title"),
                }
                if not any(existing.get("path") == resolved for existing in state["artifacts"]):
                    state["artifacts"].append(item)
                if not quiet and not jsonl:
                    eprint("artifact: %s%s" % (
                        (item.get("label") + " → ") if item.get("label") else "", resolved))
        elif etype == "checkpoint":
            checkpoint = event.get("checkpoint") or {}
            state["checkpoint"] = checkpoint
            if not quiet and not jsonl:
                eprint("")
                eprint("检查点：%s" % (checkpoint.get("title") or checkpoint.get("id") or ""))
                if checkpoint.get("message"):
                    eprint("  " + str(checkpoint.get("message")))
                for item in checkpoint.get("artifacts") or []:
                    eprint("  - %s" % item.get("path"))
            if policy == "auto":
                send_continue(checkpoint.get("id") or "")
                if not quiet and not jsonl:
                    eprint("已自动继续（--checkpoint auto）")
            elif policy == "manual" and sys.stdin.isatty() and not quiet:
                try:
                    answer = input("按回车继续，输入 q 放弃：")
                except EOFError:
                    answer = "q"
                if answer.strip().lower() == "q":
                    state["status"] = "waiting"
                    _kill_process_tree(proc)
                    return
                send_continue(checkpoint.get("id") or "")
            else:
                state["status"] = "waiting"
                deferring = True
                eprint("任务在检查点暂停；jobDir 已保留。"
                       " 人工修改产物后运行：mct resume --job %s" % job_dir)
                _kill_process_tree(proc)
        elif etype == "result":
            state["sawResult"] = True
            state["resultOK"] = event.get("ok", True) is not False
            state["summary"] = event.get("summary")
            for item in event.get("artifacts") or []:
                if not isinstance(item, dict) or not item.get("path"):
                    continue
                resolved = normalize_artifact_path(item.get("path"))
                normalized = dict(item)
                normalized["path"] = resolved
                if not any(existing.get("path") == resolved
                           for existing in state["artifacts"]):
                    state["artifacts"].append(normalized)
        elif etype == "error":
            state["error"] = event.get("message") or event.get("detail") or "未知错误"
            if not quiet and not jsonl:
                eprint("error: " + state["error"])
        elif etype == "env":
            for check in event.get("checks") or []:
                if isinstance(check, dict):
                    state["checks"] = [
                        item for item in state["checks"] if item.get("id") != check.get("id")
                    ] + [check]
        else:
            if not quiet and not jsonl and event.get("message"):
                eprint(str(event.get("message")))

    def handle_stderr(line):
        state["stderrTail"].append(line)
        if reporter is not None:
            try:
                reporter.append_stderr(line)
            except Exception:
                pass
        if len(state["stderrTail"]) > 200:
            del state["stderrTail"][:-200]
        if jsonl:
            print(json.dumps({"type": "stderr", "line": line}, ensure_ascii=False))
            sys.stdout.flush()
        elif not quiet:
            eprint(line)

    while True:
        if _CANCELLED and proc.poll() is None:
            state["status"] = "cancelled"
            _kill_process_tree(proc)

        if cancel_event is not None and cancel_event.is_set() and proc.poll() is None:
            state["status"] = "cancelled"
            if reporter is not None:
                try:
                    reporter.set_status("cancelled", "取消请求已送达")
                except Exception:
                    pass
            _kill_process_tree(proc)

        if reporter is not None and proc.poll() is None:
            try:
                if reporter.cancel_requested():
                    state["status"] = "cancelled"
                    reporter.set_status("cancelled", "取消请求来自 GUI / mct jobs")
                    _kill_process_tree(proc)
                else:
                    reporter.tick()
            except Exception:
                pass

        if timeout and timeout > 0 and time.time() - started > timeout and proc.poll() is None:
            state["timedOut"] = True
            state["status"] = "timeout"
            _kill_process_tree(proc, force=False)
            time.sleep(0.2)
            _kill_process_tree(proc, force=True)

        try:
            channel, line = line_queue.get(timeout=0.1)
        except queue.Empty:
            if proc.poll() is not None and eof["stdout"] and eof["stderr"]:
                break
            continue

        if line is None:
            eof[channel] = True
            if eof["stdout"] and eof["stderr"]:
                break
            continue
        if channel == "stdout":
            handle_stdout(line)
        else:
            handle_stderr(line)

        if deferring and proc.poll() is not None:
            # 等待两个流派发完 EOF，避免子进程的取消事件覆盖 waiting。
            pass

    try:
        proc.wait(timeout=5)
    except Exception:
        _kill_process_tree(proc, force=True)
        try:
            proc.wait(timeout=2)
        except Exception:
            pass

    state["exitCode"] = proc.returncode
    if state["status"] == "running":
        if state["timedOut"]:
            state["status"] = "timeout"
        elif _CANCELLED:
            state["status"] = "cancelled"
        elif state["sawResult"] and state["resultOK"] and proc.returncode == 0:
            state["status"] = "succeeded"
        elif proc.returncode == 0 and not state["sawResult"]:
            state["status"] = "succeeded"
        else:
            state["status"] = "failed"
    if state["status"] == "cancelled" and not state["error"]:
        state["error"] = "任务已取消"
    if state["status"] == "timeout" and not state["error"]:
        state["error"] = "任务超时"
    if state["status"] == "failed" and not state["error"]:
        if state["sawResult"] and not state["resultOK"]:
            state["error"] = state["summary"] or "工具报告失败"
        elif proc.returncode is not None:
            state["error"] = "进程退出码 %s" % proc.returncode

    _CURRENT_PROC = None
    return _finish_state(state, command, job_dir, started, config_path, args,
                         reporter=reporter)


def _finish_state(state, command, job_dir, started, config_path, args, reporter=None):
    duration_ms = int((time.time() - started) * 1000)
    result = {
        "ok": state["status"] == "succeeded",
        "status": state["status"],
        "tool": getattr(args, "_tool_id", None),
        "jobID": Path(job_dir).name,
        "jobDir": str(job_dir),
        "configPath": str(config_path) if config_path else None,
        "exitCode": state["exitCode"],
        "summary": state["summary"],
        "error": state["error"],
        "artifacts": state["artifacts"],
        "checks": state["checks"],
        "checkpoint": state["checkpoint"],
        "durationMs": duration_ms,
        "command": command,
        "finishedAt": _iso_now(),
        "statePath": str(agent_state.jobs_state_root() / Path(job_dir).name / "job.json"),
    }
    if state["stderrTail"] and state["status"] != "succeeded":
        result["stderrTail"] = state["stderrTail"][-40:]
    if state.get("events") and result["status"] == "failed":
        error_events = [event for event in state["events"]
                        if isinstance(event, dict) and event.get("type") == "error"]
        if error_events:
            result["errorDetail"] = error_events[-1].get("detail")
    try:
        Path(job_dir, "mct-result.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except Exception:
        pass
    if reporter is not None:
        try:
            reporter.finish(result)
        except Exception:
            pass
    return result


def result_exit_code(result):
    status = result.get("status")
    if status == "succeeded":
        return EXIT_OK
    if status == "waiting":
        return EXIT_WAIT_CHECKPOINT
    if status == "timeout":
        return EXIT_TIMEOUT
    if status == "cancelled":
        return EXIT_CANCELLED
    return EXIT_TOOL_FAILED


def emit_result(args, result, extra=None):
    if getattr(args, "jsonl", False):
        return
    data = dict(result)
    if extra:
        data.update(extra)
    print_json(data)


# ---------------------------------------------------------------- commands

def cmd_list(args):
    catalog = load_catalog(args)
    tools = catalog.tools
    if args.category:
        tools = [item for item in tools if item.manifest.get("category") == args.category]
    if args.runnable:
        tools = [item for item in tools if item.run is not None]
    if args.agent_only:
        tools = [item for item in tools
                 if spec.effective_agent(item.manifest).get("enabled", True)]
    if args.json:
        print_json({
            "specVersion": spec.SPEC_VERSION,
            "count": len(tools),
            "tools": [{
                "id": item.id,
                "name": item.name,
                "version": item.version,
                "category": item.manifest.get("category"),
                "summary": item.manifest.get("summary"),
                "capability": spec.effective_agent(item.manifest)["capability"],
                "stability": spec.effective_agent(item.manifest)["stability"],
                "hasRun": item.run is not None,
                "nativeView": item.native_view,
                "mcpName": spec.effective_agent(item.manifest)["mcpName"],
            } for item in tools],
            "issues": [issue.as_dict() for issue in catalog.issues],
        })
    else:
        for item in tools:
            agent = spec.effective_agent(item.manifest)
            print("%-30s %-8s %-8s %s" % (
                item.id, item.version,
                "native" if item.native_view else "protocol",
                agent["capability"]))
        eprint("共 %d 个工具；issues：%d error / %d warning"
               % (len(tools), catalog.error_count, catalog.warning_count))
    for issue in catalog.issues:
        if issue.is_error:
            eprint(str(issue))
    return EXIT_OK


def _markdown_descriptor(desc):
    lines = ["# %s" % desc["name"], "", desc.get("summary") or "", "",
             "- id: `%s`" % desc["id"],
             "- version: `%s`" % desc["version"],
             "- capability: `%s`" % desc["capability"],
             "- stability: `%s`" % desc["stability"],
             "- timeout: %ss" % desc["timeoutSec"],
             "- checkpoint: `%s`" % desc["checkpoint"],
             "- mcp name: `%s`" % desc["cli"]["mcpName"],
             "", "## 输入", ""]
    if desc["inputs"]:
        lines.append("| key | type | required | default | help |")
        lines.append("|---|---|---|---|---|")
        for item in desc["inputs"]:
            lines.append("| `%s` | %s | %s | %s | %s |" % (
                item["key"], item["type"], "yes" if item["required"] else "no",
                json.dumps(item.get("default"), ensure_ascii=False),
                (item.get("help") or "").replace("|", "\\|")))
    else:
        lines.append("（无输入）")
    if desc["examples"]:
        lines.extend(["", "## 示例", ""])
        for example in desc["examples"]:
            lines.append("- %s：`%s`" % (example["title"], example["command"]))
    lines.extend(["", "## CLI", "",
                  "```bash",
                  "mct describe %s --json" % desc["id"],
                  "mct doctor %s --json" % desc["id"],
                  "mct run %s --input key=value" % desc["id"],
                  "```"])
    return "\n".join(lines)


def cmd_describe(args):
    catalog, entry = require_entry(args, args.tool_id)
    desc = spec.descriptor(entry)
    if args.markdown:
        print(_markdown_descriptor(desc))
    else:
        print_json(desc)
    return EXIT_OK


def cmd_schema(args):
    catalog = load_catalog(args)
    entries = catalog.tools if args.all else []
    if not args.all:
        entry = catalog.get(args.tool_id or "")
        if entry is None:
            raise MCTError("找不到工具：%s" % (args.tool_id or ""), EXIT_NOT_FOUND)
        entries = [entry]
    if args.format == "openai":
        print_json(spec.openai_tools(entries))
    elif args.format == "mcp":
        print_json(spec.mcp_tools(entries))
    elif args.format == "descriptor":
        print_json([spec.descriptor(item) for item in entries])
    else:
        if args.all:
            print_json({item.id: spec.input_schema(item.manifest) for item in entries})
        else:
            print_json(spec.input_schema(entries[0].manifest))
    return EXIT_OK


def cmd_validate(args):
    issues = []
    paths = list(args.paths)
    if args.all or not paths:
        for root in _search_roots(args):
            if root.is_dir():
                paths.append(str(root))
    tool_dirs = spec.collect_tool_dirs(paths, issues)
    seen = {}
    for directory in tool_dirs:
        manifest = spec.load_manifest(directory, issues)
        if manifest is None:
            continue
        issues.extend(spec.validate_manifest(
            manifest, directory, strict=args.strict,
            check_files=True, check_python=True))
        tool_id = manifest.get("id")
        if tool_id in seen:
            issues.append(spec.Issue(
                "warning", directory,
                "工具 id 重复：%s；后扫描到的会覆盖 %s" % (tool_id, seen[tool_id]),
                tool_id))
        seen[tool_id] = directory
    errors = [item for item in issues if item.is_error]
    warnings = [item for item in issues if not item.is_error]
    if args.json:
        print_json({
            "tools": [str(path) for path in tool_dirs],
            "errors": len(errors),
            "warnings": len(warnings),
            "issues": [item.as_dict() for item in issues],
        })
    else:
        for item in issues:
            print(item)
        print("checked %d tool(s): %d error(s), %d warning(s)"
              % (len(tool_dirs), len(errors), len(warnings)))
    return EXIT_TOOL_FAILED if errors else EXIT_OK


def cmd_paths(args):
    print_json({
        "specVersion": spec.SPEC_VERSION,
        "repoRoot": str(spec.repo_root()),
        "dataRoot": str(spec.data_root()),
        "jobs": str(spec.jobs_root()),
        "temp": str(spec.temp_root()),
        "cache": str(spec.cache_root()),
        "searchDirectories": [str(item) for item in spec.search_directories(
            getattr(args, "tools_dir", None))],
    })
    return EXIT_OK


def _temp_job(entry):
    root = spec.temp_root()
    try:
        root.mkdir(parents=True, exist_ok=True)
        directory = root / ("doctor-%s-%s" % (
            entry.id.replace(".", "-"), hashlib_suffix()))
        directory.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise MCTError(
            "无法创建临时任务目录：%s（可用 MCT_DATA_DIR 指向可写目录）" % exc,
            EXIT_USAGE)
    return directory


def hashlib_suffix():
    import hashlib
    return hashlib.sha1(("%s-%s" % (time.time(), os.getpid())).encode()).hexdigest()[:6]


def cmd_doctor(args):
    catalog, entry = require_entry(args, args.tool_id)
    if not isinstance(entry.manifest.get("doctor"), dict):
        raise MCTError("工具 %s 没有声明 doctor" % entry.id, EXIT_USAGE)
    args._entry = entry
    raw = parse_raw_inputs(args)
    values, secrets = normalize_or_fail(args, entry, raw, require=False, check_files=False)
    job_dir = _temp_job(entry)
    config_path = spec.write_config(entry, values, job_dir, resume=False)
    args._tool_id = entry.id
    result = execute(
        entry, values, secrets, job_dir, config_path, args,
        kind="doctor", timeout=args.timeout or 120,
        checkpoint_policy="auto", quiet=args.quiet, jsonl=args.jsonl)
    checks = result.get("checks") or []
    healthy = all(check.get("status") != "fail" for check in checks)
    if not args.quiet and not args.json and not args.jsonl:
        for check in checks:
            print("[%s] %s %s" % (check.get("status", "?").upper(),
                                  check.get("label", check.get("id", "")),
                                  check.get("detail") or ""))
        print("healthy: %s" % ("yes" if healthy else "no"))
    if not args.jsonl:
        emit_result(args, result, {"healthy": healthy})
    if result.get("status") != "succeeded":
        return result_exit_code(result)
    if args.strict and not healthy:
        return EXIT_TOOL_FAILED
    return EXIT_OK


def cmd_setup(args):
    catalog, entry = require_entry(args, args.tool_id)
    if not isinstance(entry.manifest.get("setup"), dict):
        raise MCTError("工具 %s 没有声明 setup" % entry.id, EXIT_USAGE)
    args._entry = entry
    raw = parse_raw_inputs(args)
    values, secrets = normalize_or_fail(args, entry, raw, require=False, check_files=False)
    job_dir = _temp_job(entry)
    config_path = spec.write_config(entry, values, job_dir, resume=False)
    args._tool_id = entry.id
    result = execute(
        entry, values, secrets, job_dir, config_path, args,
        kind="setup", timeout=args.timeout or 900,
        checkpoint_policy="auto", quiet=args.quiet, jsonl=args.jsonl)
    emit_result(args, result)
    return result_exit_code(result)


def cmd_run(args):
    catalog, entry = require_entry(args, args.tool_id)
    if entry.run is None:
        raise MCTError("工具 %s 没有 run，无法通过 CLI 执行" % entry.id, EXIT_USAGE)
    args._entry = entry
    raw = parse_raw_inputs(args)
    values, secrets = normalize_or_fail(args, entry, raw, require=True, check_files=True)
    args._tool_id = entry.id

    existing = Path(args.job_dir).expanduser() if args.job_dir else None
    if args.resume and existing is None:
        raise MCTError("--resume 需要配合 --job-dir 使用", EXIT_USAGE)
    if existing is not None:
        job_dir = existing
        job_dir.mkdir(parents=True, exist_ok=True)
    else:
        job_dir = spec.new_job_dir(entry.id)

    fingerprint = spec.fingerprint(entry, values)
    resume = bool(args.resume)
    if resume:
        previous = spec.load_config(job_dir)
        if previous is None:
            raise MCTError("--resume 指定的目录没有 config.json：%s" % job_dir, EXIT_USAGE)
        old_fp = ((previous.get("_meta") or {}).get("fingerprint"))
        if old_fp and old_fp != fingerprint:
            eprint("warning: 输入/参数/工具版本已变化，本次从头执行（不复用旧产物）")
            resume = False
    config_path = spec.write_config(entry, values, job_dir, resume=resume, fp=fingerprint)

    if args.dry_run:
        command = spec.display_command(entry.run, entry.directory, entry.id,
                                       job_dir=job_dir, config_file=config_path)
        result = {
            "ok": True,
            "status": "dry-run",
            "tool": entry.id,
            "jobID": job_dir.name,
            "jobDir": str(job_dir),
            "configPath": str(config_path),
            "command": command,
            "values": redact_values(entry, values),
            "secretKeys": sorted(secrets.keys()),
            "inputSchema": spec.input_schema(entry.manifest),
        }
        print_json(result)
        return EXIT_OK

    agent = spec.effective_agent(entry.manifest)
    policy = args.checkpoint or agent.get("checkpoint") or "manual"
    if policy not in spec.AGENT_CHECKPOINTS:
        raise MCTError("--checkpoint 必须是 never/manual/auto", EXIT_USAGE)
    # "never" 只是元数据：工具若仍发 checkpoint，就自动继续。
    effective_policy = "auto" if policy == "never" else policy
    timeout = args.timeout if args.timeout is not None else agent.get("timeoutSec", 3600)
    reporter = make_reporter(entry, job_dir, values, source="cli")
    locks = None
    try:
        locks = acquire_resource_locks(entry, args, reporter)
        result = execute(
            entry, values, secrets, job_dir, config_path, args,
            kind="run", timeout=timeout, checkpoint_policy=effective_policy,
            quiet=args.quiet, jsonl=args.jsonl, reporter=reporter)
    finally:
        if locks is not None:
            locks.release()
    emit_result(args, result)
    return result_exit_code(result)


def cmd_resume(args):
    job_dir = Path(args.job).expanduser().resolve()
    config = spec.load_config(job_dir)
    if config is None:
        raise MCTError("找不到或无法解析 config.json：%s" % job_dir, EXIT_USAGE)
    meta = config.get("_meta") or {}
    tool_id = meta.get("toolID")
    if not tool_id:
        raise MCTError("config.json 缺少 _meta.toolID", EXIT_USAGE)
    catalog, entry = require_entry(args, tool_id)
    if entry.run is None:
        raise MCTError("工具 %s 没有 run" % tool_id, EXIT_USAGE)
    args._entry = entry
    args._tool_id = entry.id
    values = {key: value for key, value in config.items()
              if key not in ("_meta", "resume")}
    secrets = resolve_secrets(entry, {}, use_keychain=not args.no_keychain)
    config["resume"] = True
    config.setdefault("_meta", {})["resumedAt"] = _iso_now()
    config_path = job_dir / "config.json"
    config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    agent = spec.effective_agent(entry.manifest)
    policy = args.checkpoint or "auto"
    if policy not in spec.AGENT_CHECKPOINTS:
        raise MCTError("--checkpoint 必须是 never/manual/auto", EXIT_USAGE)
    timeout = args.timeout if args.timeout is not None else agent.get("timeoutSec", 3600)
    reporter = make_reporter(entry, job_dir, values, source="resume")
    locks = None
    try:
        locks = acquire_resource_locks(entry, args, reporter)
        result = execute(
            entry, values, secrets, job_dir, config_path, args,
            kind="run", timeout=timeout,
            checkpoint_policy="auto" if policy == "never" else policy,
            quiet=args.quiet, jsonl=args.jsonl, reporter=reporter)
    finally:
        if locks is not None:
            locks.release()
    result["resumed"] = True
    emit_result(args, result)
    return result_exit_code(result)


def cmd_batch(args):
    catalog, entry = require_entry(args, args.tool_id)
    batch = entry.manifest.get("batch")
    if not isinstance(batch, dict):
        raise MCTError("工具 %s 没有声明 batch" % entry.id, EXIT_USAGE)
    if entry.run is None:
        raise MCTError("工具 %s 没有 run" % entry.id, EXIT_USAGE)
    args._entry = entry
    raw = parse_raw_inputs(args)
    # batch.input 可以是目录；文件/目录存在性交给 spec.batch_files 判断。
    values, secrets = normalize_or_fail(args, entry, raw, require=True, check_files=False)
    if args.output_dir:
        values["outputDir"] = os.path.abspath(os.path.expanduser(args.output_dir))
    files, file_errors = spec.batch_files(
        values, batch, recursive=args.recursive, max_files=args.limit)
    for message in file_errors:
        eprint("warning: " + message)
    if not files:
        raise MCTError("没有匹配到可批量处理的文件", EXIT_USAGE)
    skip_existing = args.skip_existing
    if skip_existing is None:
        skip_existing = bool(batch.get("skipExisting", True))
    jobs = max(1, args.jobs)
    if "gpu" in [str(item).lower() for item in entry.manifest.get("resources") or []]:
        if jobs > 1:
            eprint("提示：工具声明 gpu 资源，批量强制串行")
        jobs = 1

    agent = spec.effective_agent(entry.manifest)
    checkpoint = args.checkpoint or agent.get("checkpoint") or "never"
    timeout = args.timeout if args.timeout is not None else agent.get("timeoutSec", 3600)
    args._tool_id = entry.id

    if args.dry_run:
        plan = []
        for file_path in files:
            target = spec.skip_target(file_path, values, batch) if skip_existing else None
            plan.append({
                "input": str(file_path),
                "target": str(target) if target else None,
                "skip": bool(target and target.exists()),
            })
        print_json({
            "ok": True, "status": "dry-run", "tool": entry.id,
            "count": len(plan), "files": plan,
        })
        return EXIT_OK

    results = []
    counts = {"succeeded": 0, "failed": 0, "skipped": 0, "waiting": 0}
    batch_id = "batch-%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), hashlib_suffix())

    def run_one(index, file_path):
        child_values = dict(values)
        child_values[batch.get("input")] = str(file_path)
        target = spec.skip_target(file_path, child_values, batch) if skip_existing else None
        if target and target.exists():
            return {
                "ok": True, "status": "skipped", "tool": entry.id,
                "batchID": batch_id, "input": str(file_path), "target": str(target),
                "summary": "已存在输出，跳过", "artifacts": [],
                "durationMs": 0, "exitCode": 0,
            }
        job_dir = spec.new_job_dir(entry.id)
        fp = spec.fingerprint(entry, child_values)
        config_path = spec.write_config(entry, child_values, job_dir, resume=False, fp=fp)
        reporter = make_reporter(
            entry, job_dir, child_values, source="batch",
            batch_id=batch_id, batch_index=index + 1, batch_total=len(files))
        if not args.quiet:
            eprint("[%d/%d] %s" % (index + 1, len(files), file_path.name))
        locks = None
        try:
            locks = acquire_resource_locks(entry, args, reporter)
            result = execute(
                entry, child_values, secrets, job_dir, config_path, args,
                kind="run", timeout=timeout,
                checkpoint_policy="auto" if checkpoint == "never" else checkpoint,
                quiet=True, jsonl=False, reporter=reporter)
        except MCTError as exc:
            result = {
                "ok": False, "status": "failed", "tool": entry.id,
                "batchID": batch_id, "jobDir": str(job_dir),
                "input": str(file_path), "error": exc.message,
                "artifacts": [], "durationMs": 0, "exitCode": exc.exit_code,
            }
            reporter.finish(result)
        finally:
            if locks is not None:
                locks.release()
        result["batchID"] = batch_id
        result["batchIndex"] = index + 1
        result["batchTotal"] = len(files)
        result["input"] = str(file_path)
        if target:
            result["target"] = str(target)
        if not args.quiet:
            eprint("  → %s（%s）" % (result["status"], result.get("summary") or ""))
        return result

    if jobs == 1:
        for index, file_path in enumerate(files):
            result = run_one(index, file_path)
            results.append(result)
            counts[result["status"]] = counts.get(result["status"], 0) + 1
            if args.stop_on_error and result["status"] == "failed":
                break
    else:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = [pool.submit(run_one, index, file_path)
                       for index, file_path in enumerate(files)]
            for future in futures:
                try:
                    result = future.result()
                except Exception as exc:
                    result = {"ok": False, "status": "failed", "tool": entry.id,
                              "error": str(exc), "artifacts": [], "durationMs": 0}
                results.append(result)
                counts[result["status"]] = counts.get(result["status"], 0) + 1

    failed = sum(count for status, count in counts.items()
                 if status not in ("succeeded", "skipped", "waiting"))
    ok = failed == 0 and counts.get("waiting", 0) == 0
    summary_result = {
        "ok": ok,
        "status": "succeeded" if ok else "failed",
        "tool": entry.id,
        "toolName": entry.name,
        "batchID": batch_id,
        "total": len(files),
        "succeeded": counts.get("succeeded", 0),
        "failed": failed,
        "skipped": counts.get("skipped", 0),
        "waiting": counts.get("waiting", 0),
        "results": results,
        "durationMs": sum(item.get("durationMs", 0) for item in results),
    }
    print_json(summary_result)
    if failed:
        return EXIT_TOOL_FAILED
    if counts.get("waiting", 0):
        return EXIT_WAIT_CHECKPOINT
    return EXIT_OK


# ---------------------------------------------------------------- agent jobs

def cmd_jobs(args):
    action = getattr(args, "jobs_action", None) or "list"
    if action == "list":
        jobs = agent_state.read_jobs(
            limit=args.limit, include_terminal=not getattr(args, "active", False))
        if args.json:
            print_json({
                "ok": True,
                "active": sum(1 for job in jobs if job.get("status") in agent_state.ACTIVE_STATUSES),
                "count": len(jobs),
                "jobs": jobs,
            })
        else:
            for job in jobs:
                print("%-34s %-10s %3d%%  %s" % (
                    job.get("id", "?"),
                    job.get("status", "?"),
                    int(float(job.get("progress") or 0) * 100),
                    job.get("summary") or job.get("itemLabel") or job.get("toolName") or ""))
            print("%d job(s)" % len(jobs))
        return EXIT_OK
    if action == "show":
        job = agent_state.read_job(args.job_id)
        if job is None:
            raise MCTError("找不到 Agent 任务：%s" % args.job_id, EXIT_NOT_FOUND)
        log_lines = agent_state.read_log(args.job_id, limit=args.log) if args.log else []
        if args.json:
            payload = dict(job)
            if args.log:
                payload["log"] = log_lines
            print_json(payload)
        else:
            print("id:       %s" % job.get("id"))
            print("tool:     %s (%s)" % (job.get("toolName"), job.get("toolID")))
            print("status:   %s" % job.get("status"))
            print("progress: %d%%" % int(float(job.get("progress") or 0) * 100))
            print("jobDir:   %s" % job.get("jobDir"))
            print("source:   %s" % job.get("source"))
            if job.get("summary"):
                print("summary:  %s" % job.get("summary"))
            if job.get("error"):
                print("error:    %s" % job.get("error"))
            for artifact in job.get("artifacts") or []:
                print("artifact: %s" % artifact.get("path"))
            if log_lines:
                print("--- log ---")
                for line in log_lines:
                    print(line)
        return EXIT_OK
    if action == "cancel":
        if not agent_state.cancel_job(args.job_id):
            raise MCTError("找不到 Agent 任务：%s" % args.job_id, EXIT_NOT_FOUND)
        if args.json:
            print_json({"ok": True, "id": args.job_id, "cancelled": True})
        else:
            print("cancelled: %s" % args.job_id)
        return EXIT_OK
    if action == "clear":
        count = agent_state.clear_finished()
        if args.json:
            print_json({"ok": True, "removed": count})
        else:
            print("removed %d finished job(s)" % count)
        return EXIT_OK
    if action == "mark-interrupted":
        count = agent_state.mark_interrupted(older_than_seconds=args.older_than)
        if args.json:
            print_json({"ok": True, "marked": count})
        else:
            print("marked %d interrupted job(s)" % count)
        return EXIT_OK
    if action == "paths":
        print_json({
            "root": str(agent_state.jobs_state_root()),
            "active": len(agent_state.read_jobs(limit=1000, include_terminal=False)),
            "total": len(agent_state.read_jobs(limit=1000)),
        })
        return EXIT_OK
    raise MCTError("未知 jobs 子命令：%s" % action, EXIT_USAGE)


# ---------------------------------------------------------------- MCP

_MCP_WRITE_LOCK = threading.Lock()


def _mcp_write(payload):
    with _MCP_WRITE_LOCK:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def _mcp_response(request_id, result=None, error=None):
    payload = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result
    _mcp_write(payload)


def _mcp_notify(method, params):
    _mcp_write({"jsonrpc": "2.0", "method": method, "params": params})


def _mcp_content(uri, payload):
    return {
        "contents": [{
            "uri": uri,
            "mimeType": "application/json",
            "text": json.dumps(payload, ensure_ascii=False, indent=2),
        }]
    }


def _mcp_tool_uri(tool_id):
    return "mct://tools/%s" % tool_id


def _mcp_job_uri(job_id):
    return "mct://jobs/%s" % job_id


def _mcp_prompt_list():
    return {
        "prompts": [
            {
                "name": "run_tool",
                "title": "运行 MacToolbox 工具",
                "description": "让 Agent 用 tools/call 调用一个 MacToolbox 工具，并汇报产物。",
                "arguments": [
                    {"name": "tool", "description": "工具 id，例如 media.image-convert", "required": True},
                    {"name": "inputs", "description": "JSON 对象形式的工具输入", "required": False},
                ],
            },
            {
                "name": "review_job",
                "title": "审查 Agent 任务",
                "description": "读取 AgentJobs 状态、产物与检查点，决定继续/取消/重跑。",
                "arguments": [
                    {"name": "job", "description": "AgentJobs 的 job id", "required": True},
                ],
            },
            {
                "name": "debug_tool",
                "title": "诊断工具环境",
                "description": "输出工具描述、Schema、doctor 结论和 CLI 修复命令。",
                "arguments": [
                    {"name": "tool", "description": "工具 id", "required": True},
                ],
            },
        ]
    }


def _mcp_prompt_get(name, arguments, catalog):
    arguments = arguments if isinstance(arguments, dict) else {}
    if name == "run_tool":
        tool_id = arguments.get("tool") or ""
        entry = catalog.get(tool_id)
        if entry is None:
            raise MCTError("Unknown tool: %s" % tool_id, EXIT_NOT_FOUND)
        desc = spec.descriptor(entry)
        mcp_name = desc["cli"]["mcpName"]
        inputs = arguments.get("inputs")
        if isinstance(inputs, str):
            try:
                inputs = json.loads(inputs)
            except Exception:
                inputs = {}
        example = desc["examples"][0]["command"] if desc["examples"] else "mct run %s --input key=value" % tool_id
        text = (
            "调用 MacToolbox 工具 `%s`（capability `%s`）。\n"
            "MCP 工具名：`%s`。\n"
            "输入 Schema：\n```json\n%s\n```\n"
            "建议输入：%s\n"
            "请用 tools/call 调用，并把 artifacts 的绝对路径和 status 汇报给用户。\n"
            "CLI 等价命令：`%s`。"
        ) % (
            tool_id, desc["capability"], mcp_name,
            json.dumps(desc["inputSchema"], ensure_ascii=False, indent=2),
            json.dumps(inputs or {}, ensure_ascii=False),
            example,
        )
        return {
            "description": "运行 %s" % tool_id,
            "messages": [{"role": "user", "content": {"type": "text", "text": text}}],
        }
    if name == "review_job":
        job_id = arguments.get("job") or ""
        job = agent_state.read_job(job_id)
        if job is None:
            raise MCTError("Unknown job: %s" % job_id, EXIT_NOT_FOUND)
        log_lines = agent_state.read_log(job_id, limit=40)
        text = (
            "审查 Agent 任务 `%s`：\n```json\n%s\n```\n"
            "最近事件：\n```jsonl\n%s\n```\n"
            "若 status=waiting，先让用户修改 jobDir 里的产物，再运行 "
            "`mct resume --job %s --checkpoint auto`；若失败，读取 error/artifacts 后决定重跑。"
        ) % (
            job_id,
            json.dumps(job, ensure_ascii=False, indent=2),
            "\n".join(log_lines),
            job.get("jobDir") or "",
        )
        return {
            "description": "审查任务 %s" % job_id,
            "messages": [{"role": "user", "content": {"type": "text", "text": text}}],
        }
    if name == "debug_tool":
        tool_id = arguments.get("tool") or ""
        entry = catalog.get(tool_id)
        if entry is None:
            raise MCTError("Unknown tool: %s" % tool_id, EXIT_NOT_FOUND)
        desc = spec.descriptor(entry)
        text = (
            "诊断 MacToolbox 工具 `%s`。\n"
            "描述：\n```json\n%s\n```\n"
            "请先运行 `mct doctor %s --json`；若 healthy=false，按 checks 里的 "
            "fixCommand/installHint 处理；再运行 `mct run %s --dry-run` 检查解析后的命令。"
        ) % (
            tool_id,
            json.dumps(desc["execution"], ensure_ascii=False, indent=2),
            tool_id, tool_id,
        )
        return {
            "description": "诊断 %s" % tool_id,
            "messages": [{"role": "user", "content": {"type": "text", "text": text}}],
        }
    raise MCTError("Unknown prompt: %s" % name, EXIT_NOT_FOUND)


def cmd_mcp(args):
    """MCP stdio server：tools/resources/prompts + progress/cancel。"""
    catalog = load_catalog(args)
    eprint("mct mcp: %d tools, resources, prompts on stdio" % len(catalog.tools))
    workers = {}
    workers_lock = threading.Lock()
    shutdown = threading.Event()
    subscriptions = set()
    subscriptions_lock = threading.Lock()
    last_signatures = {}
    watcher_stop = threading.Event()

    def log_level(level):
        return {
            "warn": "warning",
            "warning": "warning",
            "error": "error",
            "debug": "debug",
        }.get(str(level).lower(), "info")

    def send_log(tool_id, level, message):
        if not message:
            return
        _mcp_notify("notifications/message", {
            "level": log_level(level),
            "logger": "mct",
            "data": {"tool": tool_id, "message": str(message)},
        })

    def resource_signature(uri):
        try:
            if uri == "mct://jobs":
                jobs = agent_state.read_jobs(limit=100)
                payload = [[job.get("id"), job.get("status"), job.get("progress"),
                            job.get("updatedAt")] for job in jobs]
                return hashlib.sha1(json.dumps(payload, sort_keys=True).encode()).hexdigest()
            if uri.startswith("mct://jobs/"):
                job_id = uri[len("mct://jobs/"):]
                job = agent_state.read_job(job_id)
                if job is None:
                    return "missing"
                events = agent_state.jobs_state_root() / job_id / "events.jsonl"
                try:
                    size = events.stat().st_size
                except OSError:
                    size = 0
                payload = [job.get("status"), job.get("progress"), job.get("updatedAt"), size]
                return hashlib.sha1(json.dumps(payload, sort_keys=True).encode()).hexdigest()
            if uri == "mct://paths":
                return "static"
            if uri.startswith("mct://tools"):
                return "static"
        except Exception:
            return None
        return None

    def watch_resources():
        while not watcher_stop.wait(2.0):
            with subscriptions_lock:
                uris = list(subscriptions)
            for uri in uris:
                signature = resource_signature(uri)
                if signature is None:
                    continue
                previous = last_signatures.get(uri)
                last_signatures[uri] = signature
                if previous is not None and previous != signature:
                    _mcp_notify("notifications/resources/updated", {"uri": uri})

    watcher = threading.Thread(target=watch_resources, name="mcp-resource-watch", daemon=True)
    watcher.start()

    def send_progress(token, fraction, message=None):
        if token is None:
            return
        params = {
            "progressToken": token,
            "progress": max(0.0, min(1.0, float(fraction))),
            "total": 1.0,
        }
        if message:
            params["message"] = str(message)
        _mcp_notify("notifications/progress", params)

    def call_tool(request_id, params):
        token = (params.get("_meta") or {}).get("progressToken")
        name = params.get("name")
        arguments = params.get("arguments") or {}
        entry = spec.tool_for_mcp_name(catalog.tools, name)
        cancel_event = threading.Event()
        with workers_lock:
            workers[request_id] = {"cancel": cancel_event}
        try:
            if entry is None:
                raise MCTError("Unknown tool: %s" % name, EXIT_NOT_FOUND)
            if not isinstance(arguments, dict):
                raise MCTError("arguments must be an object", EXIT_USAGE)
            if entry.run is None:
                raise MCTError("Tool has no run command: %s" % entry.id, EXIT_USAGE)
            values, secrets, errors = spec.normalize_values(
                entry, arguments, require=True, check_files=True)
            if errors:
                raise MCTError("输入校验失败：\n- " + "\n- ".join(errors),
                               EXIT_USAGE, {"validationErrors": errors})
            secrets = resolve_secrets(entry, dict(secrets), use_keychain=True)
            job_dir = spec.new_job_dir(entry.id)
            fp = spec.fingerprint(entry, values)
            config_path = spec.write_config(entry, values, job_dir, resume=False, fp=fp)
            reporter = make_reporter(entry, job_dir, values, source="mcp")
            fake_args = argparse.Namespace(
                json=False, jsonl=False, quiet=True, _tool_id=entry.id,
                no_locks=getattr(args, "no_locks", False),
                lock_timeout=getattr(args, "lock_timeout", None))
            locks = None
            try:
                locks = acquire_resource_locks(
                    entry, fake_args, reporter,
                    on_wait=lambda message: send_progress(token, 0.0, message),
                    cancel_event=cancel_event)
                if cancel_event.is_set():
                    reporter.set_status("cancelled", "MCP 客户端已取消")
                    _mcp_response(request_id, error={
                        "code": -32800, "message": "Request cancelled"})
                    return
                agent = spec.effective_agent(entry.manifest)
                result = execute(
                    entry, values, secrets, job_dir, config_path, fake_args,
                    kind="run", timeout=agent.get("timeoutSec", 3600),
                    checkpoint_policy="auto", quiet=True, jsonl=False,
                    reporter=reporter, cancel_event=cancel_event,
                    on_progress=lambda fraction, message: send_progress(
                        token, fraction, message),
                    on_log=lambda level, message: send_log(entry.id, level, message))
            finally:
                if locks is not None:
                    locks.release()
            if cancel_event.is_set():
                _mcp_response(request_id, error={
                    "code": -32800, "message": "Request cancelled"})
                return
            text = json.dumps(result, ensure_ascii=False, indent=2)
            _mcp_response(request_id, {
                "content": [{"type": "text", "text": text}],
                "structuredContent": result,
                "isError": not result.get("ok", False),
            })
        except MCTError as exc:
            if exc.exit_code == EXIT_CANCELLED:
                _mcp_response(request_id, error={
                    "code": -32800, "message": "Request cancelled"})
            else:
                _mcp_response(request_id, error={
                    "code": -32602, "message": exc.message})
        except Exception as exc:
            _mcp_response(request_id, error={
                "code": -32603, "message": "Internal error: %s" % exc})
        finally:
            with workers_lock:
                workers.pop(request_id, None)

    for raw_line in sys.stdin:
        if shutdown.is_set():
            break
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except Exception as exc:
            _mcp_response(None, error={"code": -32700, "message": "Parse error: %s" % exc})
            continue
        if not isinstance(request, dict):
            _mcp_response(None, error={"code": -32600, "message": "Invalid Request"})
            continue
        method = request.get("method")
        request_id = request.get("id")
        params = request.get("params") or {}
        if not isinstance(params, dict):
            params = {}
        is_notification = "id" not in request

        if method == "initialize":
            _mcp_response(request_id, {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {"listChanged": False},
                    "resources": {"subscribe": True, "listChanged": False},
                    "prompts": {"listChanged": False},
                    "logging": {},
                },
                "serverInfo": {"name": "mct", "version": spec.SPEC_VERSION},
            })
        elif method == "notifications/initialized":
            continue
        elif method == "notifications/cancelled":
            target = params.get("requestId")
            with workers_lock:
                worker = workers.get(target)
            if worker:
                worker["cancel"].set()
            continue
        elif method == "ping":
            _mcp_response(request_id, {})
        elif method == "logging/setLevel":
            _mcp_response(request_id, {})
        elif method == "tools/list":
            _mcp_response(request_id, {"tools": spec.mcp_tools(catalog.tools)})
        elif method == "tools/call":
            if is_notification:
                continue
            threading.Thread(
                target=call_tool,
                args=(request_id, params),
                name="mcp-tool-%s" % request_id,
                daemon=True,
            ).start()
        elif method in ("resources/subscribe", "resources/unsubscribe"):
            uri = params.get("uri") or ""
            if not isinstance(uri, str) or not uri.startswith("mct://"):
                _mcp_response(request_id, error={
                    "code": -32602, "message": "uri must start with mct://"})
                continue
            with subscriptions_lock:
                if method == "resources/subscribe":
                    subscriptions.add(uri)
                    last_signatures[uri] = resource_signature(uri)
                else:
                    subscriptions.discard(uri)
                    last_signatures.pop(uri, None)
            _mcp_response(request_id, {})
        elif method == "resources/list":
            _mcp_response(request_id, {
                "resources": [
                    {"uri": "mct://tools", "name": "MacToolbox tools",
                     "description": "所有工具的描述与 inputSchema",
                     "mimeType": "application/json"},
                    {"uri": "mct://jobs", "name": "Agent jobs",
                     "description": "最近 CLI/MCP/批量任务状态",
                     "mimeType": "application/json"},
                    {"uri": "mct://paths", "name": "MacToolbox paths",
                     "description": "数据目录、Jobs、AgentJobs、Locks",
                     "mimeType": "application/json"},
                ]
            })
        elif method == "resources/templates/list":
            _mcp_response(request_id, {
                "resourceTemplates": [
                    {"uriTemplate": "mct://tools/{toolId}", "name": "Tool descriptor",
                     "description": "单个工具的完整 Agent 描述",
                     "mimeType": "application/json"},
                    {"uriTemplate": "mct://jobs/{jobId}", "name": "Agent job",
                     "description": "单个 Agent 任务状态与事件",
                     "mimeType": "application/json"},
                ]
            })
        elif method == "resources/read":
            uri = params.get("uri") or ""
            try:
                if uri == "mct://tools":
                    _mcp_response(request_id, _mcp_content(
                        uri, [spec.descriptor(entry) for entry in catalog.tools]))
                elif uri.startswith("mct://tools/"):
                    tool_id = uri[len("mct://tools/"):]
                    entry = catalog.get(tool_id)
                    if entry is None:
                        raise MCTError("Unknown tool: %s" % tool_id, EXIT_NOT_FOUND)
                    _mcp_response(request_id, _mcp_content(uri, spec.descriptor(entry)))
                elif uri == "mct://jobs":
                    _mcp_response(request_id, _mcp_content(
                        uri, agent_state.read_jobs(limit=50)))
                elif uri.startswith("mct://jobs/"):
                    job_id = uri[len("mct://jobs/"):]
                    job = agent_state.read_job(job_id)
                    if job is None:
                        raise MCTError("Unknown job: %s" % job_id, EXIT_NOT_FOUND)
                    job["log"] = agent_state.read_log(job_id, limit=80)
                    _mcp_response(request_id, _mcp_content(uri, job))
                elif uri == "mct://paths":
                    _mcp_response(request_id, _mcp_content(uri, {
                        "repoRoot": str(spec.repo_root()),
                        "dataRoot": str(spec.data_root()),
                        "jobs": str(spec.jobs_root()),
                        "agentJobs": str(agent_state.jobs_state_root()),
                        "locks": str(spec.locks_root()),
                        "cache": str(spec.cache_root()),
                    }))
                else:
                    raise MCTError("Unknown resource URI: %s" % uri, EXIT_NOT_FOUND)
            except MCTError as exc:
                _mcp_response(request_id, error={"code": -32602, "message": exc.message})
        elif method == "prompts/list":
            _mcp_response(request_id, _mcp_prompt_list())
        elif method == "prompts/get":
            try:
                _mcp_response(request_id, _mcp_prompt_get(
                    params.get("name"), params.get("arguments"), catalog))
            except MCTError as exc:
                _mcp_response(request_id, error={"code": -32602, "message": exc.message})
        elif method == "shutdown":
            shutdown.set()
            watcher_stop.set()
            with workers_lock:
                for worker in workers.values():
                    worker["cancel"].set()
            _mcp_response(request_id, {})
            return EXIT_OK
        else:
            if not is_notification:
                _mcp_response(request_id, error={
                    "code": -32601, "message": "Method not found: %s" % method})

    shutdown.set()
    watcher_stop.set()
    with workers_lock:
        for worker in workers.values():
            worker["cancel"].set()
    return EXIT_OK


# ---------------------------------------------------------------- parser

def add_common_tool_dirs(parser):
    # 子命令上也接受 --tools-dir；SUPPRESS 让根命令的同名参数继续生效。
    parser.add_argument("--tools-dir", action="append", default=argparse.SUPPRESS,
                        help="额外工具目录（可重复；优先级高于内置/用户目录）")


def build_parser():
    parser = argparse.ArgumentParser(
        prog="mct",
        description="MacToolbox 统一工具 CLI / Agent 入口",
    )
    parser.add_argument("--version", action="version",
                        version="mct %s" % spec.SPEC_VERSION)
    parser.add_argument("--tools-dir", action="append", default=[],
                        help="额外工具目录（可重复）")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("list", help="列出工具")
    p.add_argument("--json", action="store_true")
    p.add_argument("--category")
    p.add_argument("--runnable", action="store_true", help="仅显示有 run 的工具")
    p.add_argument("--agent-only", action="store_true", help="仅显示 Agent 暴露的工具")
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("describe", help="输出工具的 Agent 描述（含 JSON Schema）")
    p.add_argument("tool_id")
    p.add_argument("--markdown", action="store_true")
    p.add_argument("--json", action="store_true", help="输出 JSON（默认）")
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_describe)

    p = sub.add_parser("schema", help="输出 JSON Schema / OpenAI / MCP 工具定义")
    p.add_argument("tool_id", nargs="?")
    p.add_argument("--all", action="store_true")
    p.add_argument("--format", choices=["json-schema", "openai", "mcp", "descriptor"],
                   default="json-schema")
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_schema)

    p = sub.add_parser("validate", help="校验工具包")
    p.add_argument("paths", nargs="*")
    p.add_argument("--all", action="store_true")
    p.add_argument("--strict", action="store_true", help="把 Agent 标准缺失当作 error")
    p.add_argument("--json", action="store_true")
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("paths", help="输出数据目录与工具搜索路径")
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_paths)

    for name, func, help_text in (
        ("doctor", cmd_doctor, "运行环境检测"),
        ("run", cmd_run, "运行工具"),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("tool_id")
        p.add_argument("--input", action="append", default=[], metavar="KEY=VALUE")
        p.add_argument("--inputs-json", metavar="JSON|@FILE|-")
        p.add_argument("--preset")
        p.add_argument("--secret", action="append", default=[], metavar="KEY=VALUE")
        p.add_argument("--no-keychain", action="store_true")
        p.add_argument("--timeout", type=float, default=None,
                       help="秒；0 表示不限制")
        p.add_argument("--checkpoint", choices=sorted(spec.AGENT_CHECKPOINTS),
                       help="never/auto 自动继续；manual 在检查点暂停")
        p.add_argument("--json", action="store_true", help="输出最终 JSON（默认）")
        p.add_argument("--jsonl", action="store_true", help="把 Tool Protocol 事件原样输出")
        p.add_argument("--quiet", action="store_true")
        p.add_argument("--no-locks", action="store_true",
                       help="不等待跨进程资源锁（仅调试）")
        p.add_argument("--lock-timeout", type=float, default=None,
                       help="资源锁等待秒数；默认 3600")
        add_common_tool_dirs(p)
        if name == "run":
            p.add_argument("--job-dir")
            p.add_argument("--resume", action="store_true")
            p.add_argument("--dry-run", action="store_true")
        else:
            p.add_argument("--strict", action="store_true",
                           help="有 fail 检查项时返回非 0")
        p.set_defaults(func=func)

    p = sub.add_parser("setup", help="运行环境修复")
    p.add_argument("tool_id")
    p.add_argument("--input", action="append", default=[], metavar="KEY=VALUE")
    p.add_argument("--inputs-json", metavar="JSON|@FILE|-")
    p.add_argument("--preset")
    p.add_argument("--secret", action="append", default=[], metavar="KEY=VALUE")
    p.add_argument("--no-keychain", action="store_true")
    p.add_argument("--timeout", type=float, default=None)
    p.add_argument("--json", action="store_true")
    p.add_argument("--jsonl", action="store_true")
    p.add_argument("--quiet", action="store_true")
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_setup)

    p = sub.add_parser("resume", help="从已有 jobDir 断点续跑")
    p.add_argument("--job", required=True)
    p.add_argument("--checkpoint", choices=sorted(spec.AGENT_CHECKPOINTS), default="auto")
    p.add_argument("--timeout", type=float, default=None)
    p.add_argument("--no-keychain", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--jsonl", action="store_true")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--no-locks", action="store_true")
    p.add_argument("--lock-timeout", type=float, default=None)
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_resume)

    p = sub.add_parser("batch", help="按 batch 声明批量运行")
    p.add_argument("tool_id")
    p.add_argument("--input", action="append", default=[], metavar="KEY=VALUE")
    p.add_argument("--inputs-json", metavar="JSON|@FILE|-")
    p.add_argument("--preset")
    p.add_argument("--secret", action="append", default=[], metavar="KEY=VALUE")
    p.add_argument("--no-keychain", action="store_true")
    p.add_argument("--output-dir")
    p.add_argument("--recursive", action="store_true")
    p.add_argument("--skip-existing", dest="skip_existing", action="store_true", default=None)
    p.add_argument("--no-skip-existing", dest="skip_existing", action="store_false")
    p.set_defaults(skip_existing=None)
    p.add_argument("--stop-on-error", action="store_true")
    p.add_argument("--jobs", type=int, default=1)
    p.add_argument("--limit", type=int, default=1000)
    p.add_argument("--timeout", type=float, default=None)
    p.add_argument("--checkpoint", choices=sorted(spec.AGENT_CHECKPOINTS))
    p.add_argument("--json", action="store_true")
    p.add_argument("--jsonl", action="store_true")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-locks", action="store_true")
    p.add_argument("--lock-timeout", type=float, default=None)
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_batch)

    p = sub.add_parser("jobs", help="查看/取消 Agent 任务（与 GUI 同一份状态）")
    jobs_sub = p.add_subparsers(dest="jobs_action")
    jp = jobs_sub.add_parser("list", help="列出 Agent 任务")
    jp.add_argument("--json", action="store_true")
    jp.add_argument("--active", action="store_true")
    jp.add_argument("--limit", type=int, default=50)
    jp.set_defaults(func=cmd_jobs)
    jp = jobs_sub.add_parser("show", help="查看一个 Agent 任务")
    jp.add_argument("job_id")
    jp.add_argument("--json", action="store_true")
    jp.add_argument("--log", type=int, default=80)
    jp.set_defaults(func=cmd_jobs)
    jp = jobs_sub.add_parser("cancel", help="请求取消一个 Agent 任务")
    jp.add_argument("job_id")
    jp.add_argument("--json", action="store_true")
    jp.set_defaults(func=cmd_jobs)
    jp = jobs_sub.add_parser("clear", help="清理已结束的 Agent 任务状态")
    jp.add_argument("--json", action="store_true")
    jp.set_defaults(func=cmd_jobs)
    jp = jobs_sub.add_parser("mark-interrupted", help="把 heartbeat 超时的任务标为中断")
    jp.add_argument("--older-than", type=int, default=90)
    jp.add_argument("--json", action="store_true")
    jp.set_defaults(func=cmd_jobs)
    jp = jobs_sub.add_parser("paths", help="输出 AgentJobs 目录")
    jp.set_defaults(func=cmd_jobs)

    p = sub.add_parser("mcp", help="MCP stdio server（供 Agent 直接调用）")
    p.add_argument("--no-locks", action="store_true")
    p.add_argument("--lock-timeout", type=float, default=None)
    add_common_tool_dirs(p)
    p.set_defaults(func=cmd_mcp)

    return parser


def main(argv=None):
    install_signal_handlers()
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return EXIT_USAGE
    try:
        return args.func(args)
    except MCTError as exc:
        payload = {"ok": False, "error": exc.message, "exitCode": exc.exit_code}
        payload.update(exc.payload)
        if getattr(args, "json", False) or getattr(args, "jsonl", False) \
                or getattr(args, "command", "") in ("run", "batch", "doctor", "setup"):
            print_json(payload)
        else:
            eprint("error: " + exc.message)
        return exc.exit_code
    except KeyboardInterrupt:
        eprint("cancelled")
        return EXIT_CANCELLED
    except OSError as exc:
        message = "文件系统错误：%s（可用 MCT_DATA_DIR 指向可写目录）" % exc
        if getattr(args, "json", False) or getattr(args, "jsonl", False) \
                or getattr(args, "command", "") in ("run", "batch", "doctor", "setup"):
            print_json({"ok": False, "error": message, "exitCode": EXIT_USAGE})
        else:
            eprint("error: " + message)
        return EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
