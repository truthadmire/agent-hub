# 首版验证记录

环境为 Apple M1 Pro、16 GiB、macOS 26.6.2（25G83）、Xcode 27.0（27A266a）、Apple Swift 6.4 与 Git 2.54.0。目标为 arm64、macOS 14。本文中的时间使用新加坡时区。[签名安装包对应的源码](https://github.com/truthadmire/agent-hub/tree/8795c4ad77105fbc4fa962f67299875a075d7aba)

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

- **Codex 0.170.0**。本机 ChatGPT 登录。最终签名 DMG 的安装副本通过 GUI 发起 1 次真实 Codex 尝试，仅修改 `status.txt`。基线检查退出 1，整合后退出 0。实读原库内容为 `pending`、任务分支为 `verified`，原仓库干净。退出并重开后成果页可恢复。示例任务提交为 `1eeb7785f0c67ac3673400f43bf53693c7e306b3`。[安装副本实测](desktop-verification.md)
- **Antigravity 1.5.18**。通过官方账号、应用适配器和最终权限配置完成一次文件修改。基线 `grep` 退出 1，集成后退出 0，重开数据库仍为完成。该次 CLI 报告输入 20,257、输出 2,361 token。[单工具实测](smoke.md)
- **DeepSeek Harness 0.2.0-rc.2**。验证了本机命令、headless profile、适配器与沙箱内 Bash 工具的凭据隔离。应用钥匙串中没有 DeepSeek API key，未进行真实付费模型请求。[连接兼容性](providers.md)

Codex 和 Antigravity 均按完整会话 ID 在原示例工作目录续接，准确说出上一轮修改的文件。真实 CLI 启动阶段的取消也经进程身份及退出状态核验。运行中取消和残余子进程回收另有故障测试。应用中的常规中断恢复会从已核实的 Git 检查点新建尝试。[原生会话实测](providers.md#真机续接与启动阶段取消)

## 同一任务的真实并行

在新建的两文件仓库里，Codex 先制定计划，随后 Codex 负责后端、Antigravity 负责前端。三次执行都成功，未重试。两名 worker 的进程身份在同一时刻得到核对，记录的执行区间重叠约 18.28 秒。两项独立检查均从基线退出 1 转为交付提交退出 0。重开数据库后任务仍为完成，原仓库干净。示例库的交付提交为 `4dc265e82cb6718ef80b6e61915f91c2580ac813`。[可复检摘要](../Examples/Evidence/2026-11-26.json)

## 复现

```sh
swift test
AGENTHUB_PROBE_AGY=1 AGENTHUB_PROBE_DSH=1 swift test --filter ProviderTests
./scripts/smoke.sh --fixture gallery
```

将源代码提交 `c1f8ffe409bd8ff12dfcf18aed56b289def3ccbb` 归档后解压到全新目录，用上述两个探针开关运行完整 `swift test`，70 项全部通过，零跳过。包括 HubKit 36 项、Git 7 项、受管进程 16 项和 provider 11 项。签名包提交 `8795c4a` 与该版本的应用源码、测试和 Package.swift 相同，后者修正了两处发行校验脚本，并更新了实测记录。未开启本机探针的普通 CI 会跳过 3 项本机 CLI 检查。真实模型验收单独在临时示例中运行。[A01–A40 清单](progress.md)

GitHub 托管的 macOS runner 也在签名包对应的提交上运行了 Verify。无个人模型和签名凭据的测试、摄影示例，以及 arm64 本地 DMG 的构建和安装副本校验均成功，作业耗时 6 分 26 秒。[GitHub Actions 运行记录](https://github.com/truthadmire/agent-hub/actions/runs/45851368401)

2026-11-27 00:05，更新后的 Verify 在干净的 macOS runner 上从独立 Applications 目录打开打包应用。WindowServer 观测到该进程的一个窗口。SQLite schema 为 3，初始项目与任务均为 0。三家 CLI 检测都返回路径和版本为空，随后应用正常退出。该检查记录了缺少全部 CLI 时的启动行为；安装入口交互另见桌面记录。[干净宿主实测日志](https://github.com/truthadmire/agent-hub/actions/runs/45854361787)

## 分发

0.1.0（build 1）从源码提交 `8795c4ad77105fbc4fa962f67299875a075d7aba` 的干净检出构建。App 与 helper 均通过 Developer ID 签名核验，启用了 Hardened Runtime，并带有 Apple 安全时间戳。正式发行使用此前完成桌面验收的这份签名应用。[构建源码](https://github.com/truthadmire/agent-hub/commit/8795c4ad77105fbc4fa962f67299875a075d7aba)

| 产物 | 字节或校验 |
| --- | --- |
| `dist/release/0.1.0/AgentHub-0.1.0-arm64.dmg`（公开发行包） | 2,825,678 字节，SHA-256 `11d65026ead3b8ccd3f4716733f5c33e17440893c6ea9c56d2ea6d435b35744b` |
| `dist/signed/0.1.0/AgentHub-0.1.0-arm64-signed-pending-notarization.dmg`（公证前候选包） | 2,822,828 字节，SHA-256 `76cfb80f4e987bb8c87386e4b820fde8848f84399eb344a64a0ddbdb91a3ae8c` |
| `dist/source/0.1.0/AgentHub-0.1.0-source.zip` | SHA-256 `8be69759006b4f9ca1905aa63b41782fb54979eaa84cacbcf894f5644bfe2e36`，ZIP 注释含同一源码提交 |

2026-11-27，Apple 接受了应用提交 `50b58a27-e38e-48d3-b759-114a4f79c769` 和 DMG 提交 `2ca3f642-b634-41d4-8f70-207afa8ee763`，两份结果的 `issues` 均为空。应用附票后装入 DMG，DMG 完成签名、公证与附票。两份票据分别通过 `stapler validate`。Apple 结果中的 SHA-256 对应提交时的字节，发行校验和对应最终附票文件。[应用公证结果](https://github.com/truthadmire/agent-hub/releases/download/v0.1.0/notarization-app.json) · [DMG 公证结果](https://github.com/truthadmire/agent-hub/releases/download/v0.1.0/notarization-dmg.json) · [发行校验和](https://github.com/truthadmire/agent-hub/releases/download/v0.1.0/SHA256SUMS.txt)

09:29:47（新加坡），`v0.1.0` 作为公开稳定版发布到 GitHub Releases。远端标签指向构建提交，六个附件的远端大小和 SHA-256 与本地一致。09:31 使用临时、未登录的 Chrome 配置从公开直链重新下载。浏览器写入的隔离标记为 `0081`，来源为 Chrome，下载文件的 SHA-256 与发行校验和一致。[GitHub Release](https://github.com/truthadmire/agent-hub/releases/tag/v0.1.0)

在本机只读挂载该下载文件后，核对了 Applications 链接，将 App 复制到独立的 Applications 目录。下载的 DMG 和安装后的 App 均通过票据验证和 Gatekeeper 评估，后者返回 `accepted` 和 `source=Notarized Developer ID`。安装副本的主程序与 helper 和公证前的实测候选版逐字节相同。

09:37 通过 LaunchServices 启动该副本。Gatekeeper 使用了 App Translocation 临时路径。验收工具核对了两个可执行文件和该 PID 持有的独立数据库锁。WindowServer 实际观测到一个应用窗口，schema 3 空库初始化成功，三家 CLI 的检测均完成。验收实例随后正常退出。
