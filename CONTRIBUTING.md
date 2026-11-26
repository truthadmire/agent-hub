# 开发与贡献

在 Apple Silicon Mac 上安装 Xcode 并选择其开发者目录。首次打开 Xcode 完成其系统组件安装。用 `swift --version`、`xcodebuild -version` 和 `git --version` 确认当前工具链。主要构建入口是根目录的 SwiftPM manifest。项目直接链接系统 SQLite 和 Apple 框架，当前没有需要下载、解析或锁定的第三方 Swift 包。

## 运行与验证

```sh
swift build
swift test
./scripts/smoke.sh --fixture gallery
./script/build_and_run.sh --verify
```

从源码运行时使用开发数据目录。指定环境变量 `AGENTHUB_DATA_DIR` 可以在单独的绝对路径保存验收数据。真实 CLI 冒烟会消耗对应账号的模型额度，使用临时示例仓库，并按[冒烟说明](docs/smoke.md)单独执行。桌面交互用例和截图见[桌面验收](docs/desktop-verification.md)。

## 目录

| 路径 | 职责 |
| --- | --- |
| `Sources/AgentHub` | 原生窗口、看板、协作、成果、设置与应用服务桥接 |
| `Sources/HubKit` | SQLite、模型、计划、调度、检查、预览、审计 |
| `Sources/HubProviders` | 官方 CLI 发现与认证检查、适配、凭据、事件解析 |
| `Sources/HubProcess`、`Sources/CProcessSupport` | 子进程流、超时、进程身份和监督 helper |
| `Sources/HubGit` | 基线、受管 worktree、冲突、补丁与采用 |
| `Sources/HubSmoke`、`Tests`、`Examples` | 开发验证程序、临时示例、协议及故障回归 |
| `Packaging`、`scripts`、`.github/workflows` | 资源、构建、签名、公证、交付工作流 |

涉及调度、凭据或 Git 的改动请附上可在临时目录重现的场景、原始失败和修复后执行的命令。协议 fixture 请标明来源与版本，去除账号、路径和用户内容。要支持新的 CLI 版本，先检验其实际选项和事件，更新适配器和兼容性记录。

正式版使用独立的签名环境。仓库仅维护变量名、脚本和配置示例。[发布说明](docs/releasing.md)
