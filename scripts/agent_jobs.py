#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Agent/CLI 任务的跨进程状态层。

GUI 与 CLI 通过同一份 `$MCT_DATA_DIR/AgentJobs/<jobID>/job.json` 观察任务：

```text
AgentJobs/<jobID>/
├── job.json          # 状态快照（原子写，GUI 每秒轮询）
├── events.jsonl      # Tool Protocol 事件流（控制台回放）
└── cancel.request    # GUI / mct jobs cancel 写入，执行进程轮询后停止
```

设计约束：
- 只写状态与协议事件，不写 secret、不写 config 明文；
- job.json 采用「临时文件 + os.replace」避免 GUI 读到半个 JSON；
- 真正的任务工作目录仍在 `Jobs/<jobID>`，这里只是可观察索引；
- 进程崩溃后 GUI 会看到最后 heartbeat；超过阈值可标 interrupted（由 GUI 做）。
"""
from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

ACTIVE_STATUSES = {"queued", "running", "waiting"}
TERMINAL_STATUSES = {"succeeded", "failed", "cancelled", "timeout", "interrupted", "skipped"}

STATUS_LABELS = {
    "queued": "排队中",
    "running": "运行中",
    "waiting": "等待确认",
    "succeeded": "已完成",
    "failed": "失败",
    "cancelled": "已取消",
    "timeout": "已超时",
    "interrupted": "已中断",
    "skipped": "已跳过",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def data_root() -> Path:
    custom = os.environ.get("MCT_DATA_DIR", "").strip()
    if custom:
        return Path(custom).expanduser().resolve()
    return Path.home() / "Library" / "Application Support" / "MacToolboxDemo"


def jobs_state_root() -> Path:
    return data_root() / "AgentJobs"


def _atomic_write(path: Path, payload: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(".%s.tmp-%d" % (path.name, os.getpid()))
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                   encoding="utf-8")
    os.replace(tmp, path)


class AgentJobReporter:
    """一个执行进程对应一个 reporter；线程内使用即可。"""

    def __init__(
        self,
        tool_id: str,
        tool_name: str,
        job_dir,
        source: str = "cli",
        resources=None,
        item_label=None,
        title=None,
        batch_id=None,
        batch_index=None,
        batch_total=None,
    ):
        self.job_id = Path(job_dir).name
        self.root = jobs_state_root() / self.job_id
        self.root.mkdir(parents=True, exist_ok=True)
        self.state_path = self.root / "job.json"
        self.events_path = self.root / "events.jsonl"
        self.cancel_path = self.root / "cancel.request"
        self._last_write = 0.0
        self._last_progress_write = -1.0
        self._closed = False
        self.state = {
            "version": 1,
            "id": self.job_id,
            "toolID": tool_id,
            "toolName": tool_name,
            "title": title or tool_name,
            "itemLabel": item_label,
            "source": source,
            "status": "queued",
            "progress": 0.0,
            "summary": None,
            "error": None,
            "jobDir": str(job_dir),
            "logPath": str(self.events_path),
            "pid": None,
            "resources": list(resources or []),
            "createdAt": now_iso(),
            "startedAt": None,
            "updatedAt": now_iso(),
            "finishedAt": None,
            "steps": [],
            "artifacts": [],
            "checkpoint": None,
            "batchID": batch_id,
            "batchIndex": batch_index,
            "batchTotal": batch_total,
        }
        self.write(force=True)

    # ---------------------------------------------------------------- state

    @property
    def status(self):
        return self.state.get("status")

    @property
    def is_active(self):
        return self.status in ACTIVE_STATUSES

    def set_status(self, status, message=None, **fields):
        self.state["status"] = status
        self.state["updatedAt"] = now_iso()
        if status == "running" and not self.state.get("startedAt"):
            self.state["startedAt"] = self.state["updatedAt"]
        if status in TERMINAL_STATUSES:
            self.state["finishedAt"] = self.state["updatedAt"]
        if message is not None:
            self.state["summary"] = message
        for key, value in fields.items():
            if value is not None:
                self.state[key] = value
        self.write(force=True)

    def set_pid(self, pid):
        self.state["pid"] = int(pid) if pid else None
        self.write(force=True)

    def set_resources(self, resources):
        self.state["resources"] = list(resources or [])
        self.write(force=True)

    def tick(self):
        if self._closed or not self.is_active:
            return
        if time.time() - self._last_write >= 1.5:
            self.state["updatedAt"] = now_iso()
            self.write(force=True)

    def write(self, force=False):
        now = time.time()
        if not force and now - self._last_write < 0.4:
            return
        self.state["updatedAt"] = now_iso()
        try:
            _atomic_write(self.state_path, self.state)
            self._last_write = now
        except Exception:
            pass

    # ---------------------------------------------------------------- events

    def append_event(self, event):
        try:
            with open(self.events_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(event, ensure_ascii=False) + "\n")
                handle.flush()
        except Exception:
            pass

    def append_stderr(self, line):
        self.append_event({"type": "stderr", "line": str(line)})

    def event(self, event):
        self.append_event(event)
        etype = event.get("type")
        if etype == "progress":
            fraction = event.get("fraction")
            if isinstance(fraction, (int, float)):
                value = max(0.0, min(1.0, float(fraction)))
                self.state["progress"] = value
                if value >= self._last_progress_write + 0.02 or value >= 1.0:
                    self._last_progress_write = value
                    self.write(force=True)
                else:
                    self.write()
        elif etype == "step":
            step_id = event.get("step") or event.get("title")
            if step_id:
                steps = self.state.setdefault("steps", [])
                state = event.get("state") or "running"
                found = False
                for item in steps:
                    if item.get("id") == step_id:
                        item["state"] = state
                        if event.get("title"):
                            item["title"] = event.get("title")
                        found = True
                        break
                if not found:
                    steps.append({
                        "id": step_id,
                        "title": event.get("title") or step_id,
                        "state": state,
                    })
                self.write(force=True)
        elif etype == "artifact":
            path = event.get("path")
            if path:
                artifacts = self.state.setdefault("artifacts", [])
                if not any(item.get("path") == path for item in artifacts):
                    artifacts.append({
                        "id": event.get("id") or event.get("kind") or path,
                        "kind": event.get("kind") or "file",
                        "path": path,
                        "label": event.get("label") or event.get("title"),
                    })
                    self.write(force=True)
        elif etype == "checkpoint":
            self.state["checkpoint"] = event.get("checkpoint")
            self.state["status"] = "waiting"
            self.state["updatedAt"] = now_iso()
            self.write(force=True)
        elif etype == "result":
            ok = event.get("ok", True) is not False
            self.state["status"] = "succeeded" if ok else "failed"
            self.state["progress"] = 1.0 if ok else self.state.get("progress", 0.0)
            self.state["summary"] = event.get("summary")
            if not ok:
                self.state["error"] = event.get("summary") or "工具报告失败"
            self.state["finishedAt"] = now_iso()
            for item in event.get("artifacts") or []:
                if not isinstance(item, dict) or not item.get("path"):
                    continue
                artifacts = self.state.setdefault("artifacts", [])
                if not any(existing.get("path") == item.get("path") for existing in artifacts):
                    artifacts.append(item)
            self.write(force=True)
        elif etype == "error":
            message = event.get("message") or event.get("detail")
            if message:
                self.state["error"] = message
            self.write(force=True)
        elif etype == "log":
            # 日志只进 events.jsonl，避免每行都刷新 job.json。
            self.write()
        else:
            self.write()

    def finish(self, result):
        status = result.get("status") or "failed"
        if status == "waiting":
            self.state["status"] = "waiting"
        elif status in ("succeeded", "failed", "cancelled", "timeout"):
            self.state["status"] = status
        else:
            self.state["status"] = "failed"
        if self.state["status"] == "succeeded":
            self.state["progress"] = 1.0
        self.state["summary"] = result.get("summary")
        self.state["error"] = result.get("error")
        self.state["artifacts"] = result.get("artifacts") or self.state.get("artifacts") or []
        self.state["checkpoint"] = result.get("checkpoint")
        self.state["pid"] = None
        self.state["finishedAt"] = now_iso()
        self._closed = True
        self.write(force=True)

    # ---------------------------------------------------------------- control

    def cancel_requested(self):
        return self.cancel_path.exists()

    def cancel_reason(self):
        try:
            return self.cancel_path.read_text(encoding="utf-8").strip()
        except Exception:
            return ""

    def close(self):
        if not self._closed:
            self._closed = True
            self.write(force=True)


# ---------------------------------------------------------------- read helpers

def read_job(job_id):
    path = jobs_state_root() / str(job_id) / "job.json"
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    data["cancelRequested"] = (path.parent / "cancel.request").exists()
    data["eventsPath"] = str(path.parent / "events.jsonl")
    return data


def read_jobs(limit=100, include_terminal=True):
    root = jobs_state_root()
    if not root.is_dir():
        return []
    jobs = []
    for child in root.iterdir():
        if not child.is_dir():
            continue
        data = read_job(child.name)
        if not data:
            continue
        if not include_terminal and data.get("status") in TERMINAL_STATUSES:
            continue
        jobs.append(data)
    jobs.sort(key=lambda item: str(item.get("updatedAt") or ""), reverse=True)
    return jobs[:limit]


def cancel_job(job_id, reason="cancelled by user"):
    directory = jobs_state_root() / str(job_id)
    if not directory.is_dir():
        return False
    (directory / "cancel.request").write_text(
        "%s %s\n" % (now_iso(), reason), encoding="utf-8")
    # 不直接杀 pid：执行进程会在轮询到 cancel.request 后优雅终止自己的子进程组。
    return True


def read_log(job_id, limit=200):
    path = jobs_state_root() / str(job_id) / "events.jsonl"
    if not path.is_file():
        return []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return []
    return lines[-limit:]


def clear_finished(keep_active=True):
    root = jobs_state_root()
    if not root.is_dir():
        return 0
    removed = 0
    for child in root.iterdir():
        if not child.is_dir():
            continue
        data = read_job(child.name)
        if not data:
            continue
        if keep_active and data.get("status") in ACTIVE_STATUSES:
            continue
        try:
            for path in sorted(child.rglob("*"), key=lambda item: len(item.parts), reverse=True):
                if path.is_file():
                    path.unlink()
                elif path.is_dir():
                    path.rmdir()
            child.rmdir()
            removed += 1
        except Exception:
            continue
    return removed


def mark_interrupted(older_than_seconds=90):
    """进程崩溃后没有 finishedAt 的活动任务，标为 interrupted，供 GUI 展示。"""
    count = 0
    now = time.time()
    for job in read_jobs(limit=10000):
        if job.get("status") not in ACTIVE_STATUSES:
            continue
        updated = job.get("updatedAt") or ""
        try:
            stamp = datetime.strptime(updated, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc).timestamp()
        except Exception:
            continue
        if now - stamp <= older_than_seconds:
            continue
        data = read_job(job["id"])
        if not data:
            continue
        payload = {key: value for key, value in data.items()
                   if key not in ("cancelRequested", "eventsPath")}
        payload["status"] = "interrupted"
        payload["error"] = payload.get("error") or "执行进程已退出（heartbeat 超时）"
        payload["finishedAt"] = updated
        try:
            _atomic_write(jobs_state_root() / job["id"] / "job.json", payload)
            count += 1
        except Exception:
            continue
    return count
