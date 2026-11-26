# 第三方组件说明

Agent Hub 使用 macOS 提供的 SwiftUI、AppKit、Foundation 与 Security 框架。SQLite 通过系统库访问，其上游交付代码属于公有领域。[Apple 平台文档](https://developer.apple.com/documentation/) · [SQLite 版权说明](https://sqlite.org/copyright.html)

Git、Codex CLI、Antigravity CLI 和 DeepSeek Harness（DSH）通过本机已安装的可执行文件调用，各自保留其许可证、服务条款与账户要求。Agent Hub 的源代码许可只适用于本项目。发行包不附带这四个程序。

本项目在底座选型时审查了 AionUi、AionCore、Paradev 和 Tauri；本版本没有复制或修改这些项目的源码、图标及品牌素材。核查提交、相关许可证和独立设计决定见[底座选型](docs/architecture/base-selection.md)。
