#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MacToolbox 工具契约的 Python 侧实现（Agent / CLI 共用）。

这个模块是 `tool.json` 的机器可读视图，供三处复用：

- `scripts/mct.py`：统一 CLI（发现、describe、schema、validate、doctor、run、batch、mcp）
- `scripts/tool_lint.py`：静态校验
- 工具作者自测：`from toolbox_spec import ...`

设计约束：
- 只依赖 Python 标准库，兼容 macOS 自带 Python 3.9；
- 不执行工具代码，只读 manifest / 文件元信息；
- 字段与 `Sources/ToolboxCore/Manifest.swift`、
  `Sources/ToolboxCore/ToolValidation.swift` 保持同步；
- 新旧工具都能工作：没有 `agent` 块时自动推导一份默认 Agent 描述。
"""
from __future__ import annotations

import errno
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import time
from pathlib import Path

SPEC_VERSION = "0.2.0"

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
INPUT_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+){1,3}$")
INPUT_TYPES = {
    "file", "directory", "text", "textarea", "number", "toggle",
    "select", "secret", "model", "preset", "lexicon",
}
RESOURCE_NAMES = {"gpu", "network", "cpu"}
NATIVE_VIEWS = {"homebrew", "imageOCR"}
AGENT_STABILITY = {"experimental", "stable", "deprecated"}
AGENT_CHECKPOINTS = {"never", "manual", "auto"}
REQUIREMENT_KINDS = {"cli", "python-module", "asset"}
TEXT_TYPES = {"text", "textarea", "file", "directory", "secret", "model", "preset", "lexicon"}


# ---------------------------------------------------------------- issues

class Issue:
    def __init__(self, severity: str, path, message: str, tool_id=None):
        self.severity = severity
        self.path = str(path)
        self.message = message
        self.tool_id = tool_id

    @property
    def is_error(self) -> bool:
        return self.severity == "error"

    def as_dict(self):
        data = {"severity": self.severity, "path": self.path, "message": self.message}
        if self.tool_id:
            data["toolID"] = self.tool_id
        return data

    def __str__(self):
        prefix = ("[%s] " % self.tool_id) if self.tool_id else ""
        return "%s %s%s: %s" % (self.severity.upper(), prefix, self.path, self.message)


def _issue(bucket, severity, path, message, tool_id=None):
    bucket.append(Issue(severity, path, message, tool_id))


# ---------------------------------------------------------------- paths

def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def data_root(env=None) -> Path:
    env = os.environ if env is None else env
    custom = str(env.get("MCT_DATA_DIR", "")).strip()
    if custom:
        return Path(custom).expanduser().resolve()
    return Path.home() / "Library" / "Application Support" / "MacToolboxDemo"


def jobs_root(env=None) -> Path:
    return data_root(env) / "Jobs"


def temp_root(env=None) -> Path:
    return data_root(env) / "Temp"


def cache_root(env=None) -> Path:
    env = os.environ if env is None else env
    custom = str(env.get("MCT_DATA_DIR", "")).strip()
    if custom:
        return Path(custom).expanduser().resolve() / "Cache"
    return Path.home() / "Library" / "Caches" / "MacToolboxDemo"


def search_directories(explicit=None, env=None) -> list:
    """与 Swift `ToolRegistry.searchDirectories()` 对齐，后者覆盖前者。"""
    env = os.environ if env is None else env
    directories = []

    def add(path):
        if not path:
            return
        try:
            resolved = Path(path).expanduser().resolve()
        except Exception:
            return
        if resolved not in directories:
            directories.append(resolved)

    root = repo_root()
    # 扫描顺序即覆盖顺序：后扫描到的同 id 工具覆盖先扫描到的。
    # 仓库布局：<root>/scripts/toolbox_spec.py + <root>/Tools
    # App 布局：<App>.app/Contents/Resources/Scripts/toolbox_spec.py + Resources/Tools
    add(root / "Tools")
    add(Path.cwd() / "Tools")
    add(data_root(env) / "Tools")

    env_dirs = str(env.get("TOOLBOX_TOOLS_DIR", "")).strip()
    if env_dirs:
        # Swift 把整个值当一个路径；CLI 额外支持用 ':' 分隔多个目录。
        pieces = env_dirs.split(os.pathsep) if os.pathsep in env_dirs else [env_dirs]
        for piece in pieces:
            add(piece)

    # --tools-dir 是调用者显式指定的最高优先级来源。
    for raw in explicit or []:
        add(raw)
    return directories


RESOURCE_CAPACITIES = {
    "gpu": 1,
    "network": 2,
    "cpu": max(1, (os.cpu_count() or 2) - 1),
}


def resource_capacity(name: str) -> int:
    return RESOURCE_CAPACITIES.get(str(name).lower(), 1)


def locks_root(env=None) -> Path:
    return data_root(env) / "Locks"


class ResourceTimeout(Exception):
    pass


class ResourceCancelled(Exception):
    pass


class ResourceLocks:
    """跨进程资源锁，与 Swift `CrossProcessResourceLocks` 使用同一批文件。

    文件名：`Locks/<resource>-<slot>.lock`，通过 `fcntl.lockf(LOCK_EX|LOCK_NB)`
    （POSIX 记录锁）占用；Swift 侧用同样的 `fcntl(F_SETLK)`，两端可互斥。
    进程崩溃时内核自动释放，不会留下永久死锁。
    """

    def __init__(self, resources, timeout=3600, poll=0.25, env=None):
        self.resources = sorted({str(item).lower() for item in (resources or [])
                                 if str(item).strip()})
        self.timeout = timeout
        self.poll = poll
        self.env = env
        self.held = []

    def acquire(self, on_wait=None, cancel_event=None):
        if not self.resources:
            return self
        root = locks_root(self.env)
        root.mkdir(parents=True, exist_ok=True)
        deadline = time.time() + self.timeout if self.timeout and self.timeout > 0 else None
        started = time.time()
        for resource in self.resources:
            capacity = resource_capacity(resource)
            acquired = False
            while not acquired:
                if cancel_event is not None and cancel_event.is_set():
                    self.release()
                    raise ResourceCancelled("等待资源时已取消")
                for slot in range(capacity):
                    path = root / ("%s-%d.lock" % (resource, slot))
                    try:
                        fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o644)
                    except OSError:
                        continue
                    try:
                        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except OSError as exc:
                        os.close(fd)
                        if exc.errno not in (errno.EAGAIN, errno.EACCES):
                            continue
                        continue
                    try:
                        os.ftruncate(fd, 0)
                        os.write(fd, ("%d %d\n" % (os.getpid(), int(time.time()))).encode())
                    except OSError:
                        pass
                    self.held.append((resource, slot, fd))
                    acquired = True
                    break
                if acquired:
                    break
                if deadline and time.time() > deadline:
                    self.release()
                    raise ResourceTimeout(
                        "等待资源锁超时：%s（%ss）" % (", ".join(self.resources), self.timeout))
                if on_wait:
                    try:
                        on_wait(resource, time.time() - started)
                    except Exception:
                        pass
                time.sleep(self.poll)
        return self

    def release(self):
        for resource, slot, fd in reversed(self.held):
            try:
                fcntl.lockf(fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(fd)
            except OSError:
                pass
        self.held = []

    def __enter__(self):
        return self.acquire()

    def __exit__(self, exc_type, exc, tb):
        self.release()
        return False


def new_job_dir(tool_id: str, env=None) -> Path:
    root = jobs_root(env)
    root.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    suffix = hashlib.sha1(("%s%.6f" % (tool_id, time.time())).encode("utf-8")).hexdigest()[:6]
    safe_id = tool_id.replace("/", "-")
    directory = root / ("%s-%s-%s" % (stamp, safe_id, suffix))
    directory.mkdir(parents=True, exist_ok=True)
    return directory


# ---------------------------------------------------------------- discovery

class ToolEntry:
    def __init__(self, manifest: dict, directory: Path, source: str = ""):
        self.manifest = manifest
        self.directory = Path(directory)
        self.source = source

    @property
    def id(self) -> str:
        return str(self.manifest.get("id", ""))

    @property
    def name(self) -> str:
        return str(self.manifest.get("name", self.id))

    @property
    def version(self) -> str:
        return str(self.manifest.get("version", "0.0.0"))

    @property
    def run(self):
        spec = self.manifest.get("run")
        return spec if isinstance(spec, dict) else None

    @property
    def native_view(self):
        value = self.manifest.get("nativeView")
        return value if isinstance(value, str) and value else None

    @property
    def inputs(self) -> list:
        value = self.manifest.get("inputs")
        return value if isinstance(value, list) else []

    def field(self, key):
        for item in self.inputs:
            if isinstance(item, dict) and item.get("key") == key:
                return item
        return None

    def __repr__(self):
        return "<ToolEntry %s @ %s>" % (self.id, self.directory)


class ToolCatalog:
    def __init__(self, tools, issues):
        self.tools = tools
        self.issues = issues
        self._by_id = {tool.id: tool for tool in tools}

    def get(self, tool_id: str):
        return self._by_id.get(tool_id)

    @property
    def error_count(self) -> int:
        return sum(1 for issue in self.issues if issue.is_error)

    @property
    def warning_count(self) -> int:
        return len(self.issues) - self.error_count


def load_manifest(tool_dir: Path, issues):
    path = Path(tool_dir) / "tool.json"
    if not path.is_file():
        _issue(issues, "error", tool_dir, "缺少 tool.json")
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        _issue(issues, "error", path, "JSON 解析失败：%s" % exc)
        return None
    if not isinstance(data, dict):
        _issue(issues, "error", path, "根节点必须是 object")
        return None
    return data


def collect_tool_dirs(paths, issues):
    """把文件/目录/工具根目录统一展开成工具目录列表。"""
    result = []
    for raw in paths:
        path = Path(raw).expanduser().resolve()
        if not path.exists():
            _issue(issues, "error", path, "路径不存在")
            continue
        if path.is_file():
            if path.name == "tool.json":
                result.append(path.parent)
            else:
                _issue(issues, "error", path, "不是 tool.json 或工具目录")
            continue
        if (path / "tool.json").is_file():
            result.append(path)
            continue
        for child in sorted(path.iterdir()):
            if not child.is_dir() or child.name.startswith("_") or child.name.startswith("."):
                continue
            if (child / "tool.json").is_file():
                result.append(child)
    return result


def discover(explicit=None, env=None, check_files=True, check_python=True) -> ToolCatalog:
    issues = []
    loaded = {}
    seen_dirs = set()

    for directory in search_directories(explicit, env):
        key = str(directory)
        if key in seen_dirs:
            continue
        seen_dirs.add(key)
        if not directory.is_dir():
            continue
        for child in sorted(directory.iterdir()):
            if not child.is_dir() or child.name.startswith("_") or child.name.startswith("."):
                continue
            manifest_path = child / "tool.json"
            if not manifest_path.is_file():
                _issue(issues, "warning", child, "工具目录缺少 tool.json，已跳过")
                continue
            manifest = load_manifest(child, issues)
            if manifest is None:
                continue
            validation = validate_manifest(
                manifest, child,
                strict=False,
                check_files=check_files,
                check_python=check_python,
            )
            issues.extend(validation)
            if any(item.is_error for item in validation):
                continue
            if manifest.get("id") in loaded:
                _issue(
                    issues, "warning", child,
                    "工具 id 重复：%s；当前目录会覆盖 %s"
                    % (manifest.get("id"), loaded[manifest.get("id")].directory),
                    manifest.get("id"),
                )
            loaded[manifest.get("id")] = ToolEntry(manifest, child, source=key)

    tools = sorted(
        loaded.values(),
        key=lambda item: (str(item.manifest.get("category") or ""), item.name),
    )
    return ToolCatalog(tools, issues)


# ---------------------------------------------------------------- validation

def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_string(value) -> bool:
    return isinstance(value, str)


def validate_manifest(manifest: dict, tool_dir, strict=False, check_files=True, check_python=True):
    """返回 Issue 列表。strict=True 时把 Agent 标准缺失也当作 error。"""
    issues = []
    tool_dir = Path(tool_dir)
    path = tool_dir / "tool.json"
    tool_id = manifest.get("id") if isinstance(manifest.get("id"), str) else None

    def error(message):
        _issue(issues, "error", path, message, tool_id)

    def warning(message):
        _issue(issues, "warning", path, message, tool_id)

    if manifest.get("schemaVersion") != 1:
        error("schemaVersion 必须是 1，当前为 %r" % manifest.get("schemaVersion"))
    if not isinstance(tool_id, str) or not ID_RE.match(tool_id or ""):
        error("id 只能使用小写字母、数字、点、下划线和短横线，且不能以符号开头：%r"
              % manifest.get("id"))
    if not isinstance(manifest.get("name"), str) or not manifest.get("name", "").strip():
        error("name 不能为空")
    version = manifest.get("version")
    if not isinstance(version, str) or not version.strip():
        error("version 不能为空")
    elif not VERSION_RE.match(version):
        warning("version 建议使用 1.0.0 形式，当前为 %r" % version)
    summary = manifest.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        warning("缺少 summary；工具卡片和 Agent 描述都会变弱")

    native_view = manifest.get("nativeView")
    is_native = isinstance(native_view, str) and bool(native_view.strip())
    if is_native and native_view not in NATIVE_VIEWS:
        error("nativeView 不支持：%r；当前支持 %s"
              % (native_view, " / ".join(sorted(NATIVE_VIEWS))))

    run = manifest.get("run")
    if run is not None:
        if not isinstance(run, dict):
            error("run 必须是 object")
        else:
            if not isinstance(run.get("command"), str) or not run.get("command", "").strip():
                error("run.command 不能为空")
            if not isinstance(run.get("args"), list):
                error("run.args 必须是数组")
            else:
                for arg in run.get("args", []):
                    if not isinstance(arg, str):
                        error("run.args 只能包含字符串")
                        continue
                    if check_files and arg.startswith("{{toolDir}}/"):
                        target = tool_dir / arg[len("{{toolDir}}/"):]
                        if not target.exists():
                            error("run.args 引用的文件不存在：%s" % target)
    elif is_native:
        warning("原生工具缺少 run：GUI 可用，但没有 CLI/Agent 入口；新工具应同时声明 run")
        if strict:
            error("Agent 标准要求所有工具（包括 nativeView）声明 run")
    else:
        error("非原生工具必须声明 run")

    for key in ("doctor", "setup"):
        spec = manifest.get(key)
        if spec is None:
            continue
        if not isinstance(spec, dict) or not isinstance(spec.get("command"), str) \
                or not spec.get("command", "").strip():
            error("%s.command 不能为空" % key)
        elif not isinstance(spec.get("args"), list):
            error("%s.args 必须是数组" % key)

    inputs = manifest.get("inputs")
    if not isinstance(inputs, list):
        error("inputs 必须是数组")
        inputs = []
    if not inputs:
        if run is None and not is_native:
            error("inputs 不能为空")
        elif run is not None:
            warning("零输入工具：确认 run 不需要任何参数（Agent 仍可通过 mcp/run 调用）")

    keys = set()
    for index, field in enumerate(inputs):
        if not isinstance(field, dict):
            error("inputs[%d] 必须是 object" % index)
            continue
        key = field.get("key", "")
        if not isinstance(key, str) or not key:
            error("inputs[%d] 缺少 key" % index)
            continue
        if not INPUT_KEY_RE.match(key):
            error("input key 只能使用字母、数字、下划线，且不能以数字开头：%r" % key)
        if key in keys:
            error("input key 重复：%s" % key)
        keys.add(key)
        typ = field.get("type", "")
        if typ not in INPUT_TYPES:
            error("input %s 的 type 不支持：%r（支持：%s）"
                  % (key, typ, ", ".join(sorted(INPUT_TYPES))))
        if not isinstance(field.get("label"), str) or not field.get("label", "").strip():
            warning("input %s 缺少 label" % key)
        if not isinstance(field.get("help"), str) or not field.get("help", "").strip():
            warning("input %s 缺少 help；表单和 Agent 工具描述都会缺上下文" % key)
        default = field.get("default")
        if default is not None:
            if typ == "toggle" and not isinstance(default, bool):
                error("toggle %s 的 default 必须是 true/false" % key)
            elif typ == "number" and not _is_number(default):
                error("number %s 的 default 必须是数字" % key)
            elif typ in TEXT_TYPES and not isinstance(default, str):
                error("%s %s 的 default 必须是字符串" % (typ, key))
        if typ == "select":
            options = field.get("options") or []
            if not isinstance(options, list) or not options:
                error("select %s 至少需要一个 option" % key)
            values = set()
            for option in options if isinstance(options, list) else []:
                if not isinstance(option, dict):
                    error("select %s 的 option 必须是 object" % key)
                    continue
                value = option.get("value")
                if not isinstance(value, str):
                    error("select %s 的 option.value 必须是字符串" % key)
                    continue
                if value in values:
                    error("select %s 的 option value 重复：%r" % (key, value))
                values.add(value)
                if not isinstance(option.get("label"), str) or not option.get("label", "").strip():
                    warning("select %s 的 option %r 缺少 label" % (key, value))
            if isinstance(default, str) and default and values and default not in values:
                error("select %s 的 default 不在 options 中：%r" % (key, default))
        if typ == "preset":
            options = field.get("options")
            if options is not None:
                if not isinstance(options, list):
                    error("preset %s 的 options 必须是数组" % key)
                elif not options:
                    warning("preset %s 的 options 为空；Agent 只能传 presets[].id" % key)
        if typ == "number":
            minimum, maximum = field.get("min"), field.get("max")
            if minimum is not None and not _is_number(minimum):
                error("number %s 的 min 必须是数字" % key)
            if maximum is not None and not _is_number(maximum):
                error("number %s 的 max 必须是数字" % key)
            if _is_number(minimum) and _is_number(maximum) and minimum > maximum:
                error("number %s 的 min > max" % key)
        if typ == "model":
            source = field.get("modelSource")
            if not isinstance(source, dict) or not isinstance(source.get("baseURLField"), str) \
                    or not source.get("baseURLField"):
                error("model %s 需要 modelSource.baseURLField" % key)
        if typ == "file":
            accept = field.get("accept")
            if accept is not None and not isinstance(accept, list):
                error("file %s 的 accept 必须是数组" % key)
            for ext in accept or []:
                if isinstance(ext, str) and ext.startswith("."):
                    warning("input %s 的 accept 建议不带点：%s" % (key, ext))

    # 引用检查要在所有 key 收集完之后。
    for field in inputs:
        if not isinstance(field, dict):
            continue
        key = field.get("key", "?")
        condition = field.get("visibleWhen")
        if isinstance(condition, dict) and condition.get("field") not in keys:
            error("input %s 的 visibleWhen.field 不存在：%r" % (key, condition.get("field")))
        if field.get("type") == "model":
            source = field.get("modelSource") or {}
            base = source.get("baseURLField")
            if base and base not in keys:
                error("model %s 的 baseURLField 不存在：%s" % (key, base))
            api = source.get("apiKeyField")
            if api and api not in keys:
                error("model %s 的 apiKeyField 不存在：%s" % (key, api))

    quick = manifest.get("quick")
    if isinstance(quick, dict):
        for key in quick.get("inputs") or []:
            if key not in keys:
                error("quick.inputs 引用了不存在的 input：%s" % key)
        for key in (quick.get("defaults") or {}).keys():
            if key not in keys:
                error("quick.defaults 引用了不存在的 input：%s" % key)
        if not quick.get("inputs"):
            warning("quick.inputs 为空；快速运行会退化为前几个必填字段")

    batch = manifest.get("batch")
    if isinstance(batch, dict):
        batch_input = batch.get("input")
        if batch_input not in keys:
            error("batch.input 引用了不存在的 input：%r" % batch_input)
        else:
            field = next(item for item in inputs
                         if isinstance(item, dict) and item.get("key") == batch_input)
            if field.get("type") not in ("file", "directory"):
                error("batch.input 必须是 file 或 directory：%s 当前是 %s"
                      % (batch_input, field.get("type")))
        accept = batch.get("accept")
        if accept is not None and not isinstance(accept, list):
            error("batch.accept 必须是数组")
        for ext in accept or []:
            if isinstance(ext, str) and ext.startswith("."):
                warning("batch.accept 建议不带点：%s" % ext)
        if not accept:
            warning("batch.accept 为空；批量扫描时只能使用默认扩展名")
        if batch.get("outputExtension") is not None \
                and not isinstance(batch.get("outputExtension"), str):
            error("batch.outputExtension 必须是字符串")

    preset_ids = set()
    for preset in manifest.get("presets") or []:
        if not isinstance(preset, dict):
            error("presets 的每一项必须是 object")
            continue
        preset_id = preset.get("id")
        if preset_id in preset_ids:
            error("preset id 重复：%r" % preset_id)
        preset_ids.add(preset_id)
        if not isinstance(preset_id, str) or not preset_id:
            error("preset 缺少 id")
        if not isinstance(preset.get("name"), str) or not preset.get("name", "").strip():
            warning("preset %r 缺少 name" % preset_id)
        values = preset.get("values")
        if not isinstance(values, dict):
            error("preset %r 的 values 必须是 object" % preset_id)
            values = {}
        for key in values.keys():
            if key not in keys:
                error("preset %r 覆盖了不存在的 input：%s" % (preset_id, key))

    prompt_ids = set()
    for preset in manifest.get("promptPresets") or []:
        if not isinstance(preset, dict):
            error("promptPresets 的每一项必须是 object")
            continue
        prompt_id = preset.get("id")
        if prompt_id in prompt_ids:
            error("promptPreset id 重复：%r" % prompt_id)
        prompt_ids.add(prompt_id)
        if not isinstance(prompt_id, str) or not prompt_id:
            error("promptPreset 缺少 id")
        if (not isinstance(preset.get("prompt"), str) or not preset.get("prompt", "").strip()) \
                and prompt_id != "custom":
            error("promptPreset %r 的 prompt 为空" % prompt_id)

    seen_resources = set()
    for resource in manifest.get("resources") or []:
        if not isinstance(resource, str):
            error("resources 只能包含字符串")
            continue
        normalized = resource.lower()
        if normalized in seen_resources:
            warning("resources 重复：%s" % resource)
        seen_resources.add(normalized)
        if normalized not in RESOURCE_NAMES:
            warning("未知 resource：%s；调度器会按容量 1 处理" % resource)

    for requirement in manifest.get("requirements") or []:
        if not isinstance(requirement, dict):
            error("requirements 的每一项必须是 object")
            continue
        if not requirement.get("name"):
            error("requirement 缺少 name")
        if requirement.get("kind") not in REQUIREMENT_KINDS:
            warning("未知 requirement.kind：%r" % requirement.get("kind"))

    _validate_agent(manifest, keys, error, warning, strict)

    if check_python:
        for script in tool_dir.rglob("*.py"):
            if "__pycache__" in script.parts:
                continue
            try:
                compile(script.read_text(encoding="utf-8"), str(script), "exec")
            except Exception as exc:
                error("Python 语法错误 %s：%s" % (script.relative_to(tool_dir), exc))

    return issues


def _validate_agent(manifest, keys, error, warning, strict):
    agent = manifest.get("agent")
    if agent is None:
        warning("缺少 agent 元数据；CLI 仍可用，但 Agent 工具目录不完整（新工具应声明 agent）")
        if strict:
            error("Agent 标准要求声明 agent（至少 capability + checkpoint + timeoutSec）")
        return
    if not isinstance(agent, dict):
        error("agent 必须是 object")
        return
    if "enabled" in agent and not isinstance(agent["enabled"], bool):
        error("agent.enabled 必须是布尔值")
    capability = agent.get("capability")
    if capability is not None:
        if not isinstance(capability, str) or not ID_RE.match(capability):
            error("agent.capability 只能使用小写字母、数字、点、下划线和短横线：%r"
                  % capability)
    if "description" in agent and not isinstance(agent["description"], str):
        error("agent.description 必须是字符串")
    stability = agent.get("stability")
    if stability is not None and stability not in AGENT_STABILITY:
        error("agent.stability 必须是 %s 之一：%r"
              % (" / ".join(sorted(AGENT_STABILITY)), stability))
    for key in ("readOnly", "idempotent"):
        if key in agent and not isinstance(agent[key], bool):
            error("agent.%s 必须是布尔值" % key)
    timeout = agent.get("timeoutSec")
    if timeout is not None and (not _is_number(timeout) or timeout <= 0):
        error("agent.timeoutSec 必须是正数")
    checkpoint = agent.get("checkpoint")
    if checkpoint is not None and checkpoint not in AGENT_CHECKPOINTS:
        error("agent.checkpoint 必须是 %s 之一：%r"
              % (" / ".join(sorted(AGENT_CHECKPOINTS)), checkpoint))
    tags = agent.get("tags")
    if tags is not None and (not isinstance(tags, list)
                             or any(not isinstance(tag, str) or not tag for tag in tags)):
        error("agent.tags 必须是非空字符串数组")
    outputs = agent.get("outputs")
    if outputs is not None and (not isinstance(outputs, list)
                                or any(not isinstance(item, str) or not item for item in outputs)):
        error("agent.outputs 必须是非空字符串数组（artifact kind）")
    examples = agent.get("examples")
    if examples is not None:
        if not isinstance(examples, list):
            error("agent.examples 必须是数组")
        else:
            for index, example in enumerate(examples):
                if not isinstance(example, dict):
                    error("agent.examples[%d] 必须是 object" % index)
                    continue
                if "title" in example and not isinstance(example["title"], str):
                    error("agent.examples[%d].title 必须是字符串" % index)
                inputs = example.get("inputs")
                if inputs is not None:
                    if not isinstance(inputs, dict):
                        error("agent.examples[%d].inputs 必须是 object" % index)
                    else:
                        for key in inputs.keys():
                            if key not in keys:
                                error("agent.examples[%d] 引用了不存在的 input：%s"
                                      % (index, key))


# ---------------------------------------------------------------- agent contract

def effective_agent(manifest: dict) -> dict:
    """没有 agent 块时给出可用的默认描述，保证所有工具都能进入 Agent 工具目录。"""
    raw = manifest.get("agent")
    raw = raw if isinstance(raw, dict) else {}
    tool_id = str(manifest.get("id", ""))
    agent = {
        "enabled": True,
        "capability": tool_id,
        "description": str(manifest.get("summary") or manifest.get("name") or ""),
        "stability": "experimental",
        "readOnly": False,
        "idempotent": False,
        "timeoutSec": 3600,
        "checkpoint": "never",
        "tags": [],
        "outputs": [],
        "examples": [],
    }
    for key in agent.keys():
        if key in raw:
            agent[key] = raw[key]
    agent["mcpName"] = mcp_name(tool_id)
    if not agent.get("capability"):
        agent["capability"] = tool_id
    return agent


def mcp_name(tool_id: str) -> str:
    """MCP / OpenAI 工具名只保留安全字符，避免点号被客户端拒绝。"""
    name = re.sub(r"[^A-Za-z0-9_-]+", "_", tool_id or "tool").strip("_").lower()
    return (name or "tool")[:64]


def input_schema(manifest: dict) -> dict:
    properties = {}
    required = []
    for field in manifest.get("inputs") or []:
        if not isinstance(field, dict):
            continue
        key = field.get("key")
        if not key:
            continue
        typ = field.get("type", "text")
        label = field.get("label") or key
        help_text = field.get("help") or ""
        description = label if not help_text else "%s：%s" % (label, help_text)
        prop = {"title": label, "description": description,
                "x-mactoolbox-type": typ}
        if typ == "number":
            prop["type"] = "number"
            if _is_number(field.get("min")):
                prop["minimum"] = field["min"]
            if _is_number(field.get("max")):
                prop["maximum"] = field["max"]
        elif typ == "toggle":
            prop["type"] = "boolean"
        elif typ in ("select", "preset"):
            prop["type"] = "string"
            options = field.get("options")
            values = []
            if isinstance(options, list):
                for option in options:
                    if isinstance(option, dict) and isinstance(option.get("value"), str):
                        values.append(option["value"])
            if not values and typ == "preset":
                values = [item.get("id") for item in manifest.get("presets") or []
                          if isinstance(item, dict) and isinstance(item.get("id"), str)]
            if values:
                prop["enum"] = values
        else:
            prop["type"] = "string"
            if typ == "secret":
                prop["writeOnly"] = True
        if field.get("default") is not None:
            prop["default"] = field["default"]
        if field.get("group"):
            prop["x-ui-group"] = field["group"]
        if field.get("advanced"):
            prop["x-advanced"] = True
        if field.get("placeholder"):
            prop["x-placeholder"] = field["placeholder"]
        if field.get("accept") and typ == "file":
            prop["x-accept"] = field["accept"]
        if field.get("visibleWhen"):
            prop["x-visible-when"] = field["visibleWhen"]
        properties[key] = prop
        if field.get("required") is True:
            required.append(key)
    schema = {
        "type": "object",
        "title": manifest.get("name") or manifest.get("id"),
        "description": manifest.get("summary") or "",
        "properties": properties,
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


def display_command(spec, tool_dir, tool_id="", job_dir="<jobDir>", config_file="<configFile>"):
    if not isinstance(spec, dict):
        return []
    context = {
        "{{toolDir}}": str(tool_dir),
        "{{toolID}}": str(tool_id),
        "{{jobDir}}": str(job_dir),
        "{{configFile}}": str(config_file),
    }

    def expand(value):
        text = str(value)
        for token, replacement in context.items():
            text = text.replace(token, replacement)
        return text

    command = expand(spec.get("command", ""))
    args = [expand(item) for item in spec.get("args") or []]
    return [command] + args if command else []


def example_command(tool_id: str, example: dict) -> str:
    parts = ["mct", "run", tool_id]
    inputs = example.get("inputs") if isinstance(example, dict) else None
    if isinstance(inputs, dict):
        for key, value in inputs.items():
            if isinstance(value, bool):
                text = "true" if value else "false"
            elif isinstance(value, (int, float)):
                text = str(value)
            else:
                text = str(value)
            if any(ch.isspace() for ch in text) or text == "":
                text = json.dumps(text, ensure_ascii=False)
            parts.extend(["--input", "%s=%s" % (key, text)])
    return " ".join(parts)


def descriptor(entry: ToolEntry) -> dict:
    manifest = entry.manifest
    agent = effective_agent(manifest)
    inputs = []
    for field in manifest.get("inputs") or []:
        if not isinstance(field, dict):
            continue
        item = {
            "key": field.get("key"),
            "type": field.get("type"),
            "label": field.get("label"),
            "required": field.get("required") is True,
            "default": field.get("default"),
            "group": field.get("group"),
            "advanced": field.get("advanced") is True,
            "help": field.get("help"),
        }
        for key in ("options", "accept", "min", "max", "placeholder",
                    "visibleWhen", "modelSource"):
            if key in field:
                item[key] = field[key]
        inputs.append(item)

    examples = []
    for example in agent.get("examples") or []:
        if not isinstance(example, dict):
            continue
        examples.append({
            "title": example.get("title") or "示例",
            "inputs": example.get("inputs") or {},
            "command": example_command(entry.id, example),
        })

    return {
        "specVersion": SPEC_VERSION,
        "id": entry.id,
        "name": entry.name,
        "version": entry.version,
        "category": manifest.get("category"),
        "icon": manifest.get("icon"),
        "summary": manifest.get("summary"),
        "capability": agent["capability"],
        "stability": agent["stability"],
        "readOnly": agent["readOnly"],
        "idempotent": agent["idempotent"],
        "timeoutSec": agent["timeoutSec"],
        "checkpoint": agent["checkpoint"],
        "tags": agent["tags"],
        "outputs": agent["outputs"],
        "enabled": agent["enabled"],
        "inputSchema": input_schema(manifest),
        "inputs": inputs,
        "presets": manifest.get("presets") or [],
        "promptPresets": manifest.get("promptPresets") or [],
        "quick": manifest.get("quick"),
        "batch": manifest.get("batch"),
        "resources": manifest.get("resources") or [],
        "requirements": manifest.get("requirements") or [],
        "examples": examples,
        "execution": {
            "mode": "native" if entry.native_view else "protocol",
            "nativeView": entry.native_view,
            "hasRun": entry.run is not None,
            "hasDoctor": isinstance(manifest.get("doctor"), dict),
            "hasSetup": isinstance(manifest.get("setup"), dict),
            "runCommand": display_command(entry.run, entry.directory, entry.id) if entry.run else [],
            "doctorCommand": display_command(manifest.get("doctor"), entry.directory, entry.id)
            if isinstance(manifest.get("doctor"), dict) else [],
        },
        "cli": {
            "describe": "mct describe %s --json" % entry.id,
            "schema": "mct schema %s" % entry.id,
            "run": "mct run %s --input key=value" % entry.id,
            "doctor": "mct doctor %s" % entry.id,
            "batch": "mct batch %s --input <batchInput>=<dir>" % entry.id
            if manifest.get("batch") else None,
            "mcpName": agent["mcpName"],
        },
        "paths": {
            "toolDir": str(entry.directory),
            "readme": str(entry.directory / "README.md")
            if (entry.directory / "README.md").is_file() else None,
        },
    }


# ---------------------------------------------------------------- values

def _coerce(field, raw):
    typ = field.get("type")
    key = field.get("key")
    if raw is None:
        return None
    if typ == "toggle":
        if isinstance(raw, bool):
            return raw
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            return bool(raw)
        if isinstance(raw, str):
            lowered = raw.strip().lower()
            if lowered in ("1", "true", "yes", "on"):
                return True
            if lowered in ("0", "false", "no", "off", ""):
                return False
        raise ValueError("input %s 需要布尔值，收到 %r" % (key, raw))
    if typ == "number":
        if isinstance(raw, bool):
            raise ValueError("input %s 需要数字，收到布尔值" % key)
        if isinstance(raw, (int, float)):
            value = raw
        elif isinstance(raw, str) and raw.strip():
            try:
                value = float(raw.strip())
            except ValueError:
                raise ValueError("input %s 需要数字，收到 %r" % (key, raw))
        else:
            raise ValueError("input %s 需要数字，收到 %r" % (key, raw))
        minimum, maximum = field.get("min"), field.get("max")
        if _is_number(minimum) and value < minimum:
            raise ValueError("input %s 不能小于 %s" % (key, minimum))
        if _is_number(maximum) and value > maximum:
            raise ValueError("input %s 不能大于 %s" % (key, maximum))
        return int(value) if float(value).is_integer() else value
    if isinstance(raw, (dict, list)):
        raise ValueError("input %s 需要标量值，收到 %s" % (key, type(raw).__name__))
    text = "" if raw is None else str(raw)
    if typ in ("file", "directory") and text.strip():
        text = os.path.abspath(os.path.expanduser(text.strip()))
    return text


def normalize_values(entry: ToolEntry, raw_values, preset_id=None,
                     require=True, check_files=True):
    """把 CLI/MCP 的输入规整成 config.json 的值。

    返回 (values, secrets, errors)。
    - preset 先应用 manifest.presets，再被显式输入覆盖；
    - secret 只返回 secrets，写入 config 时置空；
    - 未声明的字段报错，以下划线开头的内部字段放行。
    """
    manifest = entry.manifest
    fields = [item for item in entry.inputs if isinstance(item, dict)]
    by_key = {item.get("key"): item for item in fields}
    raw = dict(raw_values or {})
    errors = []

    chosen_preset = preset_id
    preset_field = next((item for item in fields if item.get("type") == "preset"), None)
    if not chosen_preset and preset_field:
        candidate = raw.get(preset_field.get("key"))
        if isinstance(candidate, str):
            chosen_preset = candidate

    merged = {}
    if chosen_preset and chosen_preset != "custom":
        preset = next(
            (item for item in manifest.get("presets") or []
             if isinstance(item, dict) and item.get("id") == chosen_preset),
            None,
        )
        if preset is None:
            errors.append("找不到 preset：%s" % chosen_preset)
        else:
            merged.update(preset.get("values") or {})
    merged.update(raw)

    for key in merged.keys():
        if key not in by_key and not str(key).startswith("_"):
            errors.append("未知输入字段：%s（用 mct describe %s 查看可用字段）"
                          % (key, entry.id))

    values, secrets = {}, {}
    for field in fields:
        key = field.get("key")
        typ = field.get("type")
        if key in merged:
            candidate = merged[key]
        elif field.get("default") is not None:
            candidate = field.get("default")
        elif typ == "toggle":
            candidate = False
        else:
            candidate = ""
        if typ == "number" and candidate == "" and field.get("required") is not True:
            candidate = 0
        try:
            value = _coerce(field, candidate)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        if typ == "secret":
            text = "" if value is None else str(value)
            if text:
                secrets[key] = text
            values[key] = ""
            continue
        if value is None:
            value = ""
        if typ in ("select", "preset"):
            options = field.get("options")
            allowed = [item.get("value") for item in options or []
                       if isinstance(item, dict) and isinstance(item.get("value"), str)]
            if not allowed and typ == "preset":
                allowed = [item.get("id") for item in manifest.get("presets") or []
                           if isinstance(item, dict) and isinstance(item.get("id"), str)]
                if preset_field and field is preset_field:
                    allowed = allowed + ["custom"]
            if isinstance(value, str) and value and allowed and value not in allowed:
                errors.append("input %s 的值不在选项中：%r（可选：%s）"
                              % (key, value, ", ".join(allowed)))
        if require and field.get("required") is True:
            if isinstance(value, str) and not value.strip():
                errors.append("必填字段为空：%s（%s）" % (key, field.get("label") or key))
        if typ == "file" and check_files and isinstance(value, str) and value:
            if not Path(value).is_file():
                errors.append("文件不存在：%s" % value)
        # directory 不要求预先存在：输出目录由工具创建，批量输入目录由 batch_files 校验。
        values[key] = value

    for key, value in raw.items():
        if str(key).startswith("_") and key not in values:
            values[key] = value

    return values, secrets, errors


def batch_files(values, batch, recursive=False, max_files=1000):
    """按 batch.input / batch.accept 枚举文件，返回 (files, errors)。"""
    source = str(values.get(batch.get("input"), "") or "")
    if not source:
        return [], ["批量输入为空：%s" % batch.get("input")]
    path = Path(source).expanduser()
    accept = {str(item).lower().lstrip(".") for item in batch.get("accept") or []}

    def matches(item: Path):
        return not accept or item.suffix.lower().lstrip(".") in accept

    files = []
    if path.is_file():
        files = [path]
    elif path.is_dir():
        if recursive:
            for item in sorted(path.rglob("*")):
                if item.is_file() and not item.name.startswith(".") and matches(item):
                    files.append(item)
        else:
            for item in sorted(path.iterdir()):
                if item.is_file() and not item.name.startswith(".") and matches(item):
                    files.append(item)
    else:
        return [], ["批量输入既不是文件也不是目录：%s" % path]
    errors = []
    if len(files) > max_files:
        errors.append("匹配文件过多（%d），只处理前 %d 个" % (len(files), max_files))
        files = files[:max_files]
    return files, errors


def skip_target(file_path, values, batch):
    """复刻 GUI 的 skipExisting 目标推断：format > batch.outputExtension。"""
    fmt = values.get("format")
    if fmt == "both":
        fmt = batch.get("outputExtension") or "txt"
    if not isinstance(fmt, str) or not fmt:
        fmt = batch.get("outputExtension")
    if not isinstance(fmt, str) or not fmt:
        return None
    output_dir = values.get("outputDir")
    directory = Path(output_dir).expanduser() if isinstance(output_dir, str) and output_dir \
        else Path(file_path).parent
    return directory / ("%s.%s" % (Path(file_path).stem, fmt.lstrip(".")))


# ---------------------------------------------------------------- config / fingerprint

def fingerprint(entry: ToolEntry, values) -> str:
    digest = hashlib.sha256()
    digest.update(b"toolbox-fingerprint-v1\0")
    digest.update(entry.id.encode("utf-8") + b"\0")
    digest.update(entry.version.encode("utf-8") + b"\0")

    for path in sorted(entry.directory.rglob("*")):
        if not path.is_file():
            continue
        if "__pycache__" in path.parts:
            continue
        if path.suffix.lower() in (".pyc", ".log", ".tmp") or path.name == ".DS_Store":
            continue
        try:
            digest.update(str(path.relative_to(entry.directory)).encode("utf-8") + b"\0")
            digest.update(path.read_bytes())
        except Exception:
            digest.update(b"unreadable\0")

    stable = {key: value for key, value in values.items()
              if entry.field(key) is None or entry.field(key).get("type") != "secret"}
    digest.update(json.dumps(stable, ensure_ascii=False, sort_keys=True,
                             separators=(",", ":")).encode("utf-8"))
    for field in entry.inputs:
        if not isinstance(field, dict) or field.get("type") != "file":
            continue
        path_text = stable.get(field.get("key"))
        if not isinstance(path_text, str) or not path_text:
            continue
        try:
            stat_result = os.stat(os.path.expanduser(path_text))
            digest.update(("%s|%d|%d" % (path_text, stat_result.st_size,
                                        stat_result.st_mtime_ns)).encode("utf-8"))
        except OSError:
            digest.update(("%s|missing" % path_text).encode("utf-8"))
    return digest.hexdigest()


def write_config(entry: ToolEntry, values, job_dir, resume=False, fp=None, created_at=None):
    payload = {}
    secret_keys = {field.get("key") for field in entry.inputs
                   if isinstance(field, dict) and field.get("type") == "secret"}
    for key, value in values.items():
        payload[key] = "" if key in secret_keys else value
    payload["resume"] = bool(resume)
    meta = {
        "toolID": entry.id,
        "toolVersion": entry.version,
        "toolDir": str(entry.directory),
        "jobDir": str(job_dir),
        "jobID": Path(job_dir).name,
        "createdAt": created_at or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if fp:
        meta["fingerprint"] = fp
    payload["_meta"] = meta
    path = Path(job_dir) / "config.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")
    return path


def load_config(job_dir):
    path = Path(job_dir) / "config.json"
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


# ---------------------------------------------------------------- exports for agent

def openai_tools(entries) -> list:
    result = []
    for entry in entries:
        agent = effective_agent(entry.manifest)
        if not agent.get("enabled", True):
            continue
        result.append({
            "type": "function",
            "function": {
                "name": agent["mcpName"],
                "description": agent.get("description") or entry.name,
                "parameters": input_schema(entry.manifest),
            },
        })
    return result


def mcp_tools(entries) -> list:
    result = []
    for entry in entries:
        agent = effective_agent(entry.manifest)
        if not agent.get("enabled", True):
            continue
        result.append({
            "name": agent["mcpName"],
            "description": "[%s] %s" % (entry.id, agent.get("description") or entry.name),
            "inputSchema": input_schema(entry.manifest),
            "annotations": {
                "readOnlyHint": bool(agent.get("readOnly")),
                "idempotentHint": bool(agent.get("idempotent")),
            },
        })
    return result


def tool_for_mcp_name(entries, name):
    for entry in entries:
        if effective_agent(entry.manifest)["mcpName"] == name:
            return entry
    return None


# ---------------------------------------------------------------- misc

def is_executable(path) -> bool:
    try:
        mode = os.stat(str(path)).st_mode
    except OSError:
        return False
    return bool(mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))


def which(name: str):
    return shutil.which(name)
