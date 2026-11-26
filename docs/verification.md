# 首版验证记录

环境为 Apple M1 Pro、16 GiB、macOS 26.6.2（25G83）、Xcode 27.0（27A266a）、Apple Swift 6.4 与 Git 2.54.0。目标为 arm64、macOS 14。本文中的时间使用新加坡时区。

## 软件执行

| 层级 | 验证入口 | 已观察到的结果 |
| --- | --- | --- |
| 原生编译 | `swift build --product AgentHub`；`scripts/bundle.sh debug` | SwiftUI 应用和独立监督 helper 生成，包结构与本地签名校验通过 |
| 协议与进程 | `swift test`；本机 CLI 协议探针 | JSON 与 UTF-8 分片、终止事件、用量、stderr 排空、超时、单任务取消、父进程意外退出与 PID 身份核对覆盖在测试中 |
| Git 与持久化 | `swift test` | 临时仓库中复核原索引字节、同一基线竞争、快照、冲突、移动、归档、SQLite 迁移备份和重复调度 |
| 真实项目检查与预览 | `ProjectToolsTests`、`ProjectToolsToolchainTests`、`PreviewTests` | 单独执行测试/构建；静态站点与真实的 Python HTTP 服务各自绑定回环地址；验证由实际进程与文件状态决定 |
| 故障注入 | `./scripts/smoke.sh --fixture gallery`，以及 `repair`、`restart` 等场景 | 使用受控 CLI，实际执行 Git、SQLite、验证器和进程监督。各次验收及其证据见[冒烟记录](smoke.md) |
| 桌面 | LaunchServices、XCUITest、窗口截图 | 初次开窗 1.917 秒；M1 Pro 上启动后第 14 秒的主进程 RSS 约 103.9 MiB、CPU 0.0%，为一次观测。[桌面验证](desktop-verification.md) |

## 三家官方 CLI

- **Codex 0.170.0**。本机 ChatGPT 登录，在临时 Git worktree 实际改写文件，独立读取确认，原仓库文件和状态保持干净。安装副本及多工具任务单独记录。
- **Antigravity 1.5.18**。通过官方账号、应用适配器和最终权限配置完成一次文件修改。基线 `grep` 退出 1，集成后退出 0，重开数据库仍为完成。该次 CLI 报告输入 20,257、输出 2,361 token。[单工具实测](smoke.md)
- **DeepSeek Harness 0.2.0-rc.2**。验证了本机命令、headless profile、适配器与沙箱内 Bash 工具的凭据隔离。应用钥匙串中没有 DeepSeek API key，未进行真实付费模型请求。[连接兼容性](providers.md)

## 同一任务的真实并行

在新建的两文件仓库里，Codex 先制定计划，随后 Codex 负责后端、Antigravity 负责前端。三次执行都成功，未重试。两名 worker 的进程身份在同一时刻得到核对，记录的执行区间重叠约 18.28 秒。两项独立检查均从基线退出 1 转为交付提交退出 0。重开数据库后任务仍为完成，原仓库干净。示例库的交付提交为 `4dc265e82cb6718ef80b6e61915f91c2580ac813`。[可复检摘要](../Examples/Evidence/2026-11-26.json)

## 复现

```sh
swift test
AGENTHUB_PROBE_AGY=1 AGENTHUB_PROBE_DSH=1 swift test --filter ProviderTests
./scripts/smoke.sh --fixture gallery
```

普通测试可以在没有个人模型账号的环境运行。本机 opt-in 协议探针使用本机已安装的程序和合成哨兵。真实模型验收在独立临时目录内运行。初次启动截图、任务窗口及各项功能的证据按验收场景索引。[A01–A40 清单](progress.md)

## 分发

本机具备有效的 Developer ID Application 签名身份。公证需要同一团队配置的 Apple 凭据；GitHub 公开交付需要明确目标仓库。最终安装包、签名、校验和、安装及 Gatekeeper 检查在出包后记录于此。[发布流程](releasing.md)
