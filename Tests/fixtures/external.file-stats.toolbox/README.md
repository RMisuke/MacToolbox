# 文件统计（external.file-stats）

统计单个本地文件的字节数、行数（可选）和修改时间，并生成：

- `stats.json`：机器可读的统计结果；
- `stats.txt`：给人看的文本报告。

工具只读取目标文件，不会修改它。实现仅使用 Python 3 标准库（要求 Python 3.8+），
不依赖仓库内任何源码、模板或脚本。

## 工具包结构

```text
external.file-stats.toolbox/
├── tool.json          # manifest：身份、inputs、agent、run/doctor/setup
├── README.md          # 本文件
└── scripts/
    └── tool.py        # Tool Protocol 实现（run / doctor / setup）
```

## 输入

| key | 类型 | 必填 | 默认 | 说明 |
|---|---|---|---|---|
| `file` | `file` | 是 | — | 要统计的普通文件。只读，不会修改原文件。 |
| `includeLines` | `toggle` | 否 | `true` | 是否统计行数。关闭后只取文件元信息，不读取文件内容。 |
| `outputDir` | `directory` | 否 | 空 | 输出目录。留空时写入当前任务目录（`_meta.jobDir`）。目录不存在时会尝试创建。 |

`quick.inputs` 为 `["file", "includeLines"]`，GUI 快速运行只需要这两个参数；
`outputDir` 仍可在完整表单中指定。

## 输出

两个文件固定同名，写入 `outputDir`（未指定时写入 `_meta.jobDir`）：

- `stats.json`
- `stats.txt`

同名文件会被原子替换。若输出路径与输入文件本身相同（例如输入文件恰好叫
`stats.json`，且输出目录就是它所在目录），工具会拒绝运行，避免覆盖输入。

### stats.json

```json
{
  "tool": {
    "id": "external.file-stats",
    "version": "0.1.0",
    "protocolVersion": "0.2"
  },
  "generatedAt": "2026-10-18T17:50:00Z",
  "generatedAtLocal": "2026-10-19T01:50:00+08:00",
  "file": {
    "path": "/abs/path/example.txt",
    "name": "example.txt",
    "directory": "/abs/path",
    "sizeBytes": 18,
    "sizeHuman": "18 B",
    "lineCount": 3,
    "includeLines": true,
    "modifiedAt": "2026-10-18T17:50:00Z",
    "modifiedAtLocal": "2026-10-19T01:50:00+08:00",
    "modifiedUnix": 1792345800.785447
  }
}
```

- `lineCount`：`includeLines=false` 时为 `null`。
- 时间为 ISO 8601；UTC 以 `Z` 结尾，本地时间带时区偏移。
- 其他数值均为 JSON 数字，不包含路径对象或二进制内容。

### stats.txt

纯文本报告，包含路径、大小（字节 + 人类可读单位）、行数或“未统计”、修改时间
（本地 + UTC）、生成时间和工具版本。

## 行数口径

开启 `includeLines` 时，以二进制方式分块读取文件并统计 LF（`0x0A`）字节：

- 按逻辑行计数：末尾没有换行符的最后一行也会计入；
- 空文件为 0 行；
- `\r\n` 换行可正确计数；
- 仅含老式 `\r` 换行的文件不会被识别为多行；
- 二进制文件中的 `0x0A` 也会被当作换行。

大文件会边读边发 `progress`，不会整体载入内存。

## Tool Protocol

- stdout：每行一个 JSON 对象；
- stderr：人类可读日志；
- `run` 事件：`log`、`progress`、`step`、`artifact`、`result`；
- 失败时在 `result.ok=false` 前发 `error`，并以非 0 退出；
- 取消：进程接受 `SIGTERM`，清理未完成的临时文件后退出 143。

成功时发出两个 artifact：

| id | kind | 文件 |
|---|---|---|
| `statsJson` | `json` | `stats.json` |
| `statsText` | `text` | `stats.txt` |

`artifact` 与 `result.artifacts` 中的路径均为绝对路径。`agent.outputs` 声明为
`["json", "text"]`。

## doctor

`doctor` 输出一个 `env` 事件，检查：

- `python`：当前 Python 版本是否 >= 3.8；
- `manifest`：`tool.json` 是否存在且能解析；
- `inputFile`：`file` 是否提供、存在、为普通文件且可读（未提供时为 `warn`）；
- `output`：显式 `outputDir` 是否可用；未指定时检查 `_meta.jobDir`。

`doctor` 完成诊断即返回成功的 `result`；“是否健康”由 `env.checks` 的
`ok` / `warn` / `fail` 表达，供 `mct doctor` 汇总。

## setup

本工具没有外部依赖，`setup` 不安装、不下载、不修改文件，只确认 Python 版本与
`tool.json` 可用，然后返回 `result.ok=true`。环境不满足要求时返回 `ok=false` 并以
非 0 退出，因为 setup 无法自动修复 Python 环境。

## 运行方式

GUI 中填写参数后运行即可。CLI / Agent 入口由 `mct` 提供（示例）：

```bash
mct run external.file-stats \
  --input file=/tmp/example.txt \
  --input includeLines=true \
  --input outputDir=/tmp/file-stats-out \
  --json
```

低层协议调试（`config.json` 由 `mct` 或 App 生成时最可靠）：

```bash
python3 scripts/tool.py run    --config /abs/job/config.json
python3 scripts/tool.py doctor --config /abs/job/config.json
python3 scripts/tool.py setup  --config /abs/job/config.json
```

`run` 必须能从 config 解析出输出位置：优先使用 `outputDir`，否则使用
`_meta.jobDir`。两者都没有时以配置错误退出（退出码 2）。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功，已发 `result.ok=true` |
| 1 | 输入/输出/内部错误，已发 `error` 与 `result.ok=false` |
| 2 | 配置或参数错误（缺少 `file`、config 非法、找不到输出目录） |
| 130 | 收到 `SIGINT` |
| 143 | 收到 `SIGTERM` |

## 安全与边界

- 对输入文件只调用 `stat` 与只读 `open(..., "rb")`；
- 只写入 `outputDir` 或 `_meta.jobDir`，写入使用同目录临时文件 + `os.replace`；
- 不访问网络，不读取工具包之外的仓库文件；
- 不声明 `batch`：本工具一次只统计一个文件。
