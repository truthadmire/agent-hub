# 版本记录

## 0.1.0

- 首个 Apple Silicon 桌面版本。中文看板、任务协作双面板、连接配置和成果页使用同一份本地任务记录。
- 接入 Codex、Antigravity 与 DeepSeek Harness 的官方 CLI。DeepSeek API key 保存在 macOS 钥匙串。
- 任务和执行尝试分别使用 Git worktree。集成后实际运行项目检查，将结果关联到需求修订和代码版本。
- 保存 SQLite 事件、草稿、交接、执行和验证历史，支持任务暂停、取消、恢复和有限修复。
- 提供可复现的 SwiftPM 构建、独立进程监督程序、DMG、Developer ID 签名与公证发布脚本。

各连接、安装包和发布层级的本机实测状态见[验证记录](docs/verification.md)。
