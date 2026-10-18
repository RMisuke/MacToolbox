# __TOOL_NAME__

这是 `MacToolbox` 的工具模板。复制为 `<工具ID>.toolbox` 后修改：

1. `tool.json`：改 `id`、`name`、`category`、`summary`、`inputs`、`quick`。
2. 改 `agent`：capability、checkpoint、timeoutSec、examples（Agent 标准）。
3. `scripts/tool.py`：把 `run()` 里的示例逻辑替换成真实逻辑。
4. 保持 stdout 每行一个 JSON 事件；人类日志走 `log` 事件或 stderr。
5. 运行 `python3 scripts/tool_lint.py <工具目录> --strict` 校验。
6. CLI 自测：`bin/mct describe <id> --json`、`bin/mct run <id> --input ... --json`。
7. 放进用户工具目录，或在 App「工具管理 → 新建工具」创建。

用户工具目录：

```text
~/Library/Application Support/MacToolboxDemo/Tools/
```

## 最小协议

```json
{"type":"log","level":"info","message":"开始"}
{"type":"step","step":"work","title":"处理","state":"running"}
{"type":"progress","fraction":0.5,"step":"work","message":"一半"}
{"type":"artifact","id":"result","kind":"text","path":"/绝对路径/result.txt","label":"结果"}
{"type":"result","ok":true,"summary":"完成","artifacts":[...]}
```
