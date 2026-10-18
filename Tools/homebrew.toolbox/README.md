# Homebrew 管理器

`system.homebrew` 是 MacToolbox 的原生 GUI 工具（`nativeView=homebrew`），
由 `BrewManagerView` 提供软件包、依赖、可更新、维护和镜像源界面。

从 0.2.0 起，它同时提供 CLI/Agent 入口：`scripts/tool.py` 把常用 brew 操作
封装成 Tool Protocol，GUI 与 CLI 共用同一份 `tool.json`。

## CLI / Agent

```bash
# 只读
bin/mct run system.homebrew --input action=status --json
bin/mct run system.homebrew --input action=outdated --json
bin/mct run system.homebrew --input action=search --input package=ffmpeg --json
bin/mct run system.homebrew --input action=info --input package=ffmpeg --json

# 修改（必须显式允许）
bin/mct run system.homebrew \
  --input action=install --input package=rectangle --input cask=true \
  --input allowMutations=true --json
```

支持 action：

```text
status / outdated / list / search / info / install / uninstall /
upgrade / doctor / update / cleanup
```

- `install/uninstall/upgrade/update/cleanup` 默认拒绝；必须 `allowMutations=true`。
- 输出写入 jobDir：`homebrew-*.json` / `homebrew-*.txt`；选择 `outputDir` 时复制过去。
- 环境检测：`bin/mct doctor system.homebrew --json`。
- CLI 只覆盖常用 brew 操作；brew services / tap / 镜像源管理仍只在 GUI。

## 依赖

- Homebrew：<https://brew.sh>
- 只使用本机 `brew` 与已配置镜像；不改 shell 配置。

