# AGENTS.md

本仓库是 macOS 原生 SwiftUI 工具箱 `MacToolbox Demo`。改代码或新增工具前先读本文件。

## 构建与运行

```bash
cd "/Volumes/APPLE 1TB/Code/MacToolbox"
./scripts/build_app.sh
open dist/MacToolboxDemo.app
```

- 本机不要用 `swift build`（DSH 嵌套沙箱会失败）；用 `scripts/build_app.sh` 的 `swiftc` 单模块构建。
- `dist/MacToolboxDemo.app` 是生成物，不要手改。
- 开发自测可用独立数据目录：`MCT_DATA_DIR="$PWD/.demo-data" open dist/MacToolboxDemo.app`。

## 新增/修改工具

**先读 [`docs/新工具开发指南.md`](docs/新工具开发指南.md)。**

最短路径：

```bash
python3 scripts/new_tool.py --id demo.echo --name "回显" --category "示例"
python3 scripts/tool_lint.py --all --strict
bin/mct describe demo.echo --json
bin/mct run demo.echo --input text=hello --json
```

- 内置工具：`Tools/<id>.toolbox/`；用户工具：`~/Library/Application Support/MacToolboxDemo/Tools/`。
- **每个工具必须有 `run` 和 `agent` 块**；`nativeView` 工具也必须声明 `run`，
  否则只有 GUI、没有 CLI/Agent 入口。
- 统一 CLI 是 `bin/mct`（实现 `scripts/mct.py`，契约 `scripts/toolbox_spec.py`）；
  新工具验收必须跑 `mct describe/schema/doctor/run`，不能只靠 App 手点。
- 第三方工具不需要改源码：`mct install <目录|zip>` 会装到用户 Tools/，
  App「重新扫描」即可；`--tools-dir` / `TOOLBOX_TOOLS_DIR` 可覆盖同名工具。
- Agent 任务状态在 `AgentJobs/<jobID>/job.json`（`scripts/agent_jobs.py`），
  GUI 由 `Sources/ToolboxCore/AgentJobs.swift` 轮询显示；CLI 用 `mct jobs list/show/cancel`。
- 工具的 `resources` 会同时被 GUI 和 CLI 用 `Locks/*.lock`（fcntl）调度；
  改动调度逻辑时必须同时改 `ResourceScheduler.swift` 与 `toolbox_spec.ResourceLocks`。
- `Tools/_template.toolbox/` 是隐藏模板，以 `_` 开头的目录不会出现在工具列表。
- 原生工具用 `nativeView`（当前为 `system.homebrew` 与 `media.image-ocr`）：
  GUI 由 `BrewManagerView` / `ImageOCRView` 直接管理；CLI/Agent 仍通过 `run` 走 JobRunner/Protocol。
  不要给普通新工具设置 `nativeView`；新增/修改原生工具先读
  [`docs/原生工具开发指南.md`](docs/原生工具开发指南.md)，并同步
  `NativeToolKind`、`ToolDetailView.nativeBody`、manifest 与 CLI 脚本。
- 当前执行器只支持 `run.command + run.args`；`run.mode = "steps"` 未实现。
- stdout 必须是 JSONL Tool Protocol；stderr 才是人类日志。
- 新增或修改 `tool.json` 后必须跑 `tool_lint.py --all --strict`，再在 App 里真实跑一遍。
- 新增或修改工具后还要跑 `bin/mct validate --all --strict` 和至少一次
  `bin/mct run <id> --json`；Agent 接口变更同步更新 `toolbox_spec.py`、Swift 校验和指南。
- 涉及 Agent/MCP/调度的改动必须跑 `python3 -m unittest discover -s Tests -v`，
  并验证 `mct jobs list` 与 GUI 任务页能看到同一条任务。
- 改工具包后重新构建；App 内「工具管理 → 重新扫描」可热加载用户工具。

## 代码边界

- `ToolboxCore`：manifest、扫描/校验、任务引擎、调度、持久化。
- `MacToolboxDemo`：SwiftUI 外壳、表单、控制台。
- 不要把某个工具的领域逻辑写进 Swift；逻辑放工具脚本，App 只认 manifest + 协议。
- 改核心模型时同步更新 `tool_lint.py` 和指南，避免契约漂移。
- AgentJobs 状态字段变更时，同步 `scripts/agent_jobs.py`、`Sources/ToolboxCore/AgentJobs.swift`
  和 `scripts/mct.py` 的 `mct jobs` 输出。

## 提交前

```bash
python3 scripts/tool_lint.py --all --strict
bin/mct validate --all --strict
./scripts/build_app.sh
```

并检查没有把 `config.json` / `records.json` / API Key 写进仓库。
