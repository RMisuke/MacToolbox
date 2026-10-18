#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mct / toolbox_spec 的基础回归测试。

运行：
  python3 -m unittest discover -s Tests -v
"""
from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MCT = ROOT / "scripts" / "mct.py"
LINT = ROOT / "scripts" / "tool_lint.py"
NEW_TOOL = ROOT / "scripts" / "new_tool.py"

sys.path.insert(0, str(ROOT / "scripts"))
import toolbox_spec as spec  # noqa: E402


def run(command, env=None, cwd=ROOT, timeout=120):
    merged = dict(os.environ)
    if env:
        merged.update(env)
    return subprocess.run(
        command, cwd=str(cwd), env=merged, capture_output=True,
        text=True, timeout=timeout,
    )


class ToolboxCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="mct-test-"))
        self.tools_dir = self.temp / "Tools"
        self.data_dir = self.temp / "data"
        self.tools_dir.mkdir()
        self.env = {"MCT_DATA_DIR": str(self.data_dir)}

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def make_echo(self):
        result = run([
            sys.executable, str(NEW_TOOL),
            "--id", "demo.echo",
            "--name", "回显工具",
            "--category", "示例",
            "--summary", "把输入文本重复输出",
            "--tools-dir", str(self.tools_dir),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.tools_dir / "demo.echo.toolbox"

    def make_sleep(self):
        tool_dir = self.tools_dir / "demo.sleep.toolbox"
        (tool_dir / "scripts").mkdir(parents=True)
        (tool_dir / "tool.json").write_text(json.dumps({
            "schemaVersion": 1,
            "id": "demo.sleep",
            "name": "睡眠示例",
            "version": "0.1.0",
            "category": "示例",
            "summary": "MCP 进度/取消测试",
            "inputs": [{
                "key": "text", "type": "text", "label": "文本",
                "default": "x", "required": True, "help": "测试",
            }],
            "agent": {
                "capability": "demo.sleep", "checkpoint": "never",
                "timeoutSec": 30, "readOnly": False, "idempotent": True,
                "examples": [],
            },
            "run": {
                "command": "/usr/bin/env",
                "args": ["python3", "{{toolDir}}/scripts/tool.py", "run",
                         "--config", "{{configFile}}"],
            },
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        (tool_dir / "scripts" / "tool.py").write_text(
            "import json, sys, time\n"
            "cfg = json.load(open(sys.argv[sys.argv.index('--config') + 1], encoding='utf-8'))\n"
            "def emit(**payload):\n"
            "    print(json.dumps(payload, ensure_ascii=False), flush=True)\n"
            "emit(type='step', step='sleep', title='占用', state='running')\n"
            "for i in range(8):\n"
            "    emit(type='progress', fraction=(i + 1) / 8, step='sleep')\n"
            "    time.sleep(0.2)\n"
            "emit(type='result', ok=True, summary='done:' + str(cfg.get('text')), artifacts=[])\n",
            encoding="utf-8",
        )
        return tool_dir

    def mcp_process(self):
        return subprocess.Popen(
            [sys.executable, str(MCT), "--tools-dir", str(self.tools_dir), "mcp"],
            cwd=str(ROOT), env={**os.environ, **self.env},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )

    def mcp_send(self, process, payload):
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()

    def mcp_read(self, process, timeout=15):
        ready, _, _ = select.select([process.stdout], [], [], timeout)
        if not ready:
            self.fail("MCP response timeout")
        line = process.stdout.readline()
        if not line:
            self.fail("MCP process closed")
        return json.loads(line)

    def stop_mcp(self, process):
        try:
            if process.poll() is None:
                self.mcp_send(process, {"jsonrpc": "2.0", "id": 999, "method": "shutdown"})
        except Exception:
            pass
        try:
            process.wait(timeout=5)
        except Exception:
            process.kill()
            process.wait(timeout=2)
        for stream in (process.stdin, process.stdout, process.stderr):
            try:
                stream.close()
            except Exception:
                pass

    def test_repo_tools_validate_strict(self):
        result = run([sys.executable, str(LINT), "--all", "--strict", "--json"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["errors"], 0)
        self.assertGreaterEqual(len(payload["tools"]), 5)

    def test_catalog_has_cli_and_agent(self):
        catalog = spec.discover()
        ids = {tool.id for tool in catalog.tools}
        for expected in (
            "media.subtitle", "media.image-convert", "media.video-convert",
            "system.homebrew", "media.image-ocr",
        ):
            self.assertIn(expected, ids)
        for tool in catalog.tools:
            self.assertIsNotNone(tool.run, "%s 缺少 run" % tool.id)
            agent = spec.effective_agent(tool.manifest)
            self.assertTrue(agent["capability"], "%s 缺少 capability" % tool.id)

    def test_schema_exports(self):
        result = run([sys.executable, str(MCT), "schema", "--all", "--format", "openai"])
        self.assertEqual(result.returncode, 0, result.stderr)
        tools = json.loads(result.stdout)
        self.assertEqual(len(tools), 5)
        names = {item["function"]["name"] for item in tools}
        self.assertIn("media_image-ocr", names)

        result = run([sys.executable, str(MCT), "schema", "media.image-convert"])
        self.assertEqual(result.returncode, 0, result.stderr)
        schema = json.loads(result.stdout)
        self.assertIn("image", schema["properties"])
        self.assertEqual(schema["properties"]["quality"]["type"], "number")
        self.assertIn("image", schema["required"])

        result = run([sys.executable, str(MCT), "schema", "--all", "--format", "mcp"])
        self.assertEqual(result.returncode, 0, result.stderr)
        mcp_tools = json.loads(result.stdout)
        self.assertEqual(len(mcp_tools), 5)
        self.assertTrue(all(item["inputSchema"]["type"] == "object" for item in mcp_tools))

    def test_demo_run_doctor_and_dry_run(self):
        self.make_echo()
        common = [sys.executable, str(MCT), "--tools-dir", str(self.tools_dir)]

        described = run(common + ["describe", "demo.echo", "--json"], self.env)
        self.assertEqual(described.returncode, 0, described.stderr)
        self.assertEqual(json.loads(described.stdout)["capability"], "demo.echo")

        doctor = run(common + ["doctor", "demo.echo", "--json"], self.env)
        self.assertEqual(doctor.returncode, 0, doctor.stderr + doctor.stdout)
        doctor_payload = json.loads(doctor.stdout)
        self.assertTrue(doctor_payload["healthy"])
        self.assertTrue(doctor_payload["checks"])

        setup = run(common + ["setup", "demo.echo", "--json"], self.env)
        self.assertEqual(setup.returncode, 0, setup.stderr + setup.stdout)
        self.assertTrue(json.loads(setup.stdout)["ok"])

        ran = run(common + [
            "run", "demo.echo",
            "--input", "text=hello",
            "--input", "repeat=2",
            "--input", "uppercase=true",
            "--json",
        ], self.env)
        self.assertEqual(ran.returncode, 0, ran.stderr + ran.stdout)
        payload = json.loads(ran.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["status"], "succeeded")
        self.assertTrue(payload["artifacts"])
        artifact = Path(payload["artifacts"][0]["path"])
        self.assertTrue(artifact.is_file())
        self.assertEqual(artifact.read_text(encoding="utf-8").strip(), "HELLO\nHELLO")

        dry = run(common + [
            "run", "demo.echo", "--input", "text=hello", "--dry-run",
        ], self.env)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertEqual(json.loads(dry.stdout)["status"], "dry-run")

    def test_checkpoint_and_resume(self):
        tool_dir = self.tools_dir / "demo.checkpoint.toolbox"
        (tool_dir / "scripts").mkdir(parents=True)
        (tool_dir / "tool.json").write_text(json.dumps({
            "schemaVersion": 1,
            "id": "demo.checkpoint",
            "name": "检查点示例",
            "version": "0.1.0",
            "category": "示例",
            "summary": "验证检查点与续跑",
            "inputs": [{
                "key": "text", "type": "text", "label": "文本",
                "default": "hello", "required": True, "help": "测试文本",
            }],
            "agent": {
                "capability": "demo.checkpoint", "checkpoint": "manual",
                "timeoutSec": 60, "readOnly": False, "idempotent": True,
                "examples": [],
            },
            "run": {
                "command": "/usr/bin/env",
                "args": ["python3", "{{toolDir}}/scripts/tool.py", "run",
                         "--config", "{{configFile}}"],
            },
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        (tool_dir / "scripts" / "tool.py").write_text(
            "import json, sys\n"
            "cfg = json.load(open(sys.argv[sys.argv.index('--config') + 1], encoding='utf-8'))\n"
            "def emit(**payload):\n"
            "    print(json.dumps(payload, ensure_ascii=False), flush=True)\n"
            "if not cfg.get('resume'):\n"
            "    emit(type='checkpoint', checkpoint={'id': 'review', 'title': '确认'})\n"
            "    for line in sys.stdin:\n"
            "        try:\n"
            "            event = json.loads(line)\n"
            "        except Exception:\n"
            "            continue\n"
            "        if event.get('type') == 'continue':\n"
            "            break\n"
            "emit(type='result', ok=True, summary='done:' + str(cfg.get('text')), artifacts=[])\n",
            encoding="utf-8",
        )

        result = run([
            sys.executable, str(MCT), "--tools-dir", str(self.tools_dir),
            "run", "demo.checkpoint", "--input", "text=abc", "--json",
        ], self.env, timeout=30)
        self.assertEqual(result.returncode, 6, result.stderr + result.stdout)
        waiting = json.loads(result.stdout)
        self.assertEqual(waiting["status"], "waiting")
        self.assertTrue(Path(waiting["jobDir"]).is_dir())

        resumed = run([
            sys.executable, str(MCT), "--tools-dir", str(self.tools_dir),
            "resume", "--job", waiting["jobDir"], "--checkpoint", "auto", "--json",
        ], self.env, timeout=30)
        self.assertEqual(resumed.returncode, 0, resumed.stderr + resumed.stdout)
        payload = json.loads(resumed.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["summary"], "done:abc")

    def test_mcp_tools_list_and_call(self):
        self.make_echo()
        process = self.mcp_process()
        try:
            self.mcp_send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": {}})
            self.mcp_read(process)
            self.mcp_send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
            self.assertIn("tools", self.mcp_read(process)["result"])
            self.mcp_send(process, {
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": "demo_echo", "arguments": {"text": "mcp", "repeat": 2}},
            })
            call = None
            deadline = time.time() + 15
            while time.time() < deadline:
                item = self.mcp_read(process, timeout=max(0.1, deadline - time.time()))
                if item.get("id") == 3:
                    call = item["result"]
                    break
            self.assertIsNotNone(call)
            self.assertFalse(call["isError"])
            self.assertTrue(call["structuredContent"]["ok"])
            self.assertEqual(call["structuredContent"]["summary"], "已生成 result.txt（2 次）")
        finally:
            self.stop_mcp(process)


    def test_agent_job_state_and_jobs_commands(self):
        self.make_echo()
        ran = run([
            sys.executable, str(MCT), "--tools-dir", str(self.tools_dir),
            "run", "demo.echo", "--input", "text=state", "--json",
        ], self.env)
        self.assertEqual(ran.returncode, 0, ran.stderr + ran.stdout)
        payload = json.loads(ran.stdout)
        state_path = Path(payload["statePath"])
        self.assertTrue(state_path.is_file())
        state = json.loads(state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["status"], "succeeded")
        self.assertEqual(state["source"], "cli")
        self.assertEqual(state["progress"], 1.0)
        self.assertTrue(state["artifacts"])

        listed = run([sys.executable, str(MCT), "jobs", "list", "--json"], self.env)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        jobs = json.loads(listed.stdout)["jobs"]
        self.assertTrue(any(job["id"] == state["id"] for job in jobs))

        shown = run([
            sys.executable, str(MCT), "jobs", "show", state["id"], "--json",
        ], self.env)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertEqual(json.loads(shown.stdout)["status"], "succeeded")

    def test_python_cross_process_locks(self):
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import sys, time; sys.path.insert(0, %r); "
             "from toolbox_spec import ResourceLocks; "
             "l = ResourceLocks(['gpu'], timeout=2).acquire(); "
             "print('held', flush=True); time.sleep(2); l.release()"
             % str(ROOT / "scripts")],
            env={**os.environ, **self.env},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(holder.stdout.readline().strip(), "held")
            start = time.time()
            with self.assertRaises(spec.ResourceTimeout):
                spec.ResourceLocks(["gpu"], timeout=0.6, env=self.env).acquire()
            self.assertGreaterEqual(time.time() - start, 0.5)
        finally:
            holder.wait(timeout=10)
            for stream in (holder.stdout, holder.stderr):
                try:
                    stream.close()
                except Exception:
                    pass
        lock = spec.ResourceLocks(["gpu"], timeout=2, env=self.env).acquire()
        self.assertTrue(lock.held)
        lock.release()

    def test_mcp_resources_and_prompts(self):
        self.make_echo()
        process = self.mcp_process()
        try:
            self.mcp_send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            init = self.mcp_read(process)
            self.assertIn("resources", init["result"]["capabilities"])
            self.assertIn("prompts", init["result"]["capabilities"])

            self.mcp_send(process, {"jsonrpc": "2.0", "id": 2, "method": "resources/list"})
            resources = self.mcp_read(process)["result"]["resources"]
            self.assertTrue(any(item["uri"] == "mct://tools" for item in resources))
            self.assertTrue(any(item["uri"] == "mct://jobs" for item in resources))

            self.mcp_send(process, {
                "jsonrpc": "2.0", "id": 3, "method": "resources/read",
                "params": {"uri": "mct://tools/demo.echo"},
            })
            descriptor = json.loads(self.mcp_read(process)["result"]["contents"][0]["text"])
            self.assertEqual(descriptor["id"], "demo.echo")

            self.mcp_send(process, {"jsonrpc": "2.0", "id": 4, "method": "prompts/list"})
            prompts = [item["name"] for item in self.mcp_read(process)["result"]["prompts"]]
            self.assertIn("run_tool", prompts)
            self.assertIn("review_job", prompts)

            self.mcp_send(process, {
                "jsonrpc": "2.0", "id": 5, "method": "prompts/get",
                "params": {"name": "run_tool", "arguments": {"tool": "demo.echo"}},
            })
            message = self.mcp_read(process)["result"]["messages"][0]["content"]["text"]
            self.assertIn("demo_echo", message)
        finally:
            self.stop_mcp(process)

    def test_mcp_subscribe_and_logging(self):
        self.make_echo()
        process = self.mcp_process()
        try:
            self.mcp_send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            capabilities = self.mcp_read(process)["result"]["capabilities"]
            self.assertTrue(capabilities["resources"]["subscribe"])
            self.mcp_send(process, {
                "jsonrpc": "2.0", "id": 2, "method": "resources/subscribe",
                "params": {"uri": "mct://jobs"},
            })
            self.assertEqual(self.mcp_read(process)["result"], {})
            self.mcp_send(process, {
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": "demo_echo", "arguments": {"text": "watch"}},
            })
            saw_log = False
            call_done = False
            saw_update = False
            deadline = time.time() + 10
            while time.time() < deadline and not (call_done and saw_update):
                item = self.mcp_read(process, timeout=max(0.1, deadline - time.time()))
                if item.get("method") == "notifications/message":
                    saw_log = True
                elif item.get("method") == "notifications/resources/updated":
                    self.assertEqual(item["params"]["uri"], "mct://jobs")
                    saw_update = True
                elif item.get("id") == 3:
                    call_done = True
            self.assertTrue(call_done)
            self.assertTrue(saw_log)
            self.assertTrue(saw_update)
        finally:
            self.stop_mcp(process)

    def test_mcp_progress_and_cancel(self):
        self.make_sleep()
        process = self.mcp_process()
        try:
            self.mcp_send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            self.mcp_read(process)
            self.mcp_send(process, {
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": {
                    "name": "demo_sleep", "arguments": {"text": "progress"},
                    "_meta": {"progressToken": "tok"},
                },
            })
            saw_progress = False
            result = None
            deadline = time.time() + 15
            while time.time() < deadline:
                item = self.mcp_read(process, timeout=max(0.1, deadline - time.time()))
                if item.get("method") == "notifications/progress":
                    self.assertEqual(item["params"]["progressToken"], "tok")
                    saw_progress = True
                elif item.get("id") == 2:
                    result = item
                    break
            self.assertTrue(saw_progress)
            self.assertFalse(result["result"]["isError"])
            self.assertTrue(result["result"]["structuredContent"]["ok"])

            self.mcp_send(process, {
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {
                    "name": "demo_sleep", "arguments": {"text": "cancel"},
                    "_meta": {"progressToken": "tok-cancel"},
                },
            })
            # 等第一个进度，确认工具已经启动。
            while True:
                item = self.mcp_read(process)
                if item.get("method") == "notifications/progress":
                    break
            self.mcp_send(process, {
                "jsonrpc": "2.0", "method": "notifications/cancelled",
                "params": {"requestId": 3, "reason": "test"},
            })
            cancelled = None
            deadline = time.time() + 10
            while time.time() < deadline:
                item = self.mcp_read(process, timeout=max(0.1, deadline - time.time()))
                if item.get("id") == 3:
                    cancelled = item
                    break
            self.assertEqual(cancelled["error"]["code"], -32800)
        finally:
            self.stop_mcp(process)


if __name__ == "__main__":
    unittest.main()
