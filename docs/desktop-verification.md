# 原生桌面验收

测试机为 MacBook Pro（Apple M1 Pro、16 GiB），运行 macOS 26.6.2（25G83）。测试使用 Xcode 27.0（27A266a）、XcodeGen 2.44.1 和已登录的原生桌面会话。以下记录的执行日期为 2026-11-26，新加坡时间。

## 已安装应用的真实 Codex 任务

从最终 arm64 DMG 挂载、复制到专用 Applications 目录并弹出磁盘映像后，测试直接使用该副本。Developer ID 签名版本为 0.1.0（1），对应产品提交 `8795c4ad77105fbc4fa962f67299875a075d7aba`。DMG 的 SHA-256 为 `76cfb80f4e987bb8c87386e4b820fde8848f84399eb344a64a0ddbdb91a3ae8c`。分发验证见 [发布与分发](releasing.md)。

应用通过 LaunchServices 打开。测试在原生目录选择面板输入临时 Git 仓库的完整路径，核对位置按钮以及导入后 SQLite 内的实际项目路径。在新建任务表单输入并回读目标，然后按“创建并开始”。完全隔离 HOME 时，官方 Codex 状态为 `Not logged in`。用户专门授权这一次安装版使用现有登录。此次 App 继续使用独立数据库和偏好，只有这次真实执行允许官方 CLI 使用原账号的 HOME。团队仅启用 Codex，最多一次尝试，修复和重试均为零。

| 核验项 | 实际结果 |
|---|---|
| 正式 App 创建的任务 | `8AFF2A55-7CA4-4416-9FBF-ABD348CAB47E`，数据库终态 `completed` |
| CLI 尝试 | `AD488750-6364-473B-B6BE-930011B03C23`，仅一次，状态 `succeeded`，收到官方会话标识 |
| CLI 用量 | 该尝试报告输入 80,484 tokens、输出 270 tokens；API 请求次数和订阅剩余额度未由此记录给出 |
| 基线 | `eb76faee8ee29c69b58061a197892bb4c54dadaf`，`grep -Fx verified status.txt` 退出 1 |
| 最终工作树 | `1eeb7785f0c67ac3673400f43bf53693c7e306b3`，只改 `status.txt`。相同检查退出 0，检查前后提交一致，独立读取文件得 `verified\n` |
| 原项目 | 独立读取仍为 `pending\n`，Git porcelain 状态为空 |
| 重开 | 应用正常退出；恢复完全隔离的 HOME 后，重开成功回到该项目的任务成果页。单项原生 XCTest 通过 |

另一个独立过程在同一正式安装副本中运行无网络、受控的 Codex 协议替身，实际派生子进程、写文件、整合和执行 grep。任务 `D8A8C5BE-D55A-4451-AFDB-2EE8C6258881` 同样从基线检查 1 到整合检查 0。成果页原始单窗口截图含测试机的临时绝对路径，留在本机忽略目录 `dist/evidence/desktop/`。

## 双角色与本机操作

使用三家受控 CLI 的 gallery 记录时，在原生前后端面板分别输入 `Keep the layout` 和 `Check the API`，将前端切换为负责人再切回，两份草稿逐项匹配。该 XCTest 在 Debug 应用上通过，用时 13.295 秒。对真实双订阅任务 `live-team` 的隔离数据库副本，签名安装版断言看板只有一张任务卡。点入后可见 Antigravity 前端和 Codex 后端各自的输出与接收者，双份数字草稿往返断言亦通过。模型执行来源见 [CLI 验收](smoke.md)。

![真实双订阅任务在已安装 App 内的工作区](images/desktop-live-team.png)

签名安装版已实测快速跳转（⌘K）、关闭次级界面（Esc）、新建任务（⌘N）、创建待开始任务、返回任务卡和查看成果。验收使用配套工具代发用户操作，并通过窗口专属 ScreenCaptureKit 过滤器单独抓取目标窗口。图中不显示其他应用。

签名安装版的同次离线测试运行中，双角色、受控任务执行、原生桌面交互三个 XCTest 全部通过，零跳过、零失败，耗时 81.485 秒。窗口从 1280×805 调至 760×650 点，截图确认主要操作、接收者和输入区可见。通过设置页面切换深浅外观，两个窗口截图显示所选选项和对应配色。关闭设置和主窗口后进程仍运行，LaunchServices 重新打开主窗口并恢复原任务；完全退出、重启后该任务仍可访问。物理睡眠唤醒和浏览器下载后带隔离属性的冷启动仍需单独验证。

[窄窗口](images/desktop-compact.png) · [深色设置](images/desktop-settings-dark.png) · [浅色设置](images/desktop-settings-light.png)

### 查看历史时收到新消息

A09 在同一正式安装副本通过，独立 XCTest 耗时 22.967 秒。受控 CLI 在真实工作进程内输出 100 条不同的活动后等待。测试滚动实际滚动区域，点“查看更早记录”，记录一条可见历史消息及其纵坐标。随后允许 CLI 输出一条新的、可辨识的消息。App 显示“有新消息”，原历史文本仍可见，纵坐标变化在 3 点断言容差内。点提示后，指定的新消息出现在最新页。该项测试仅使用本地协议替身。

## 冷启动与空闲快照

使用同一设备、ad-hoc 签名的 Debug 包及全新专用数据库测量，从发出 LaunchServices 打开请求到首次读到主进程的 AXWindow 为 **1.917 秒**。启动后第 14 秒，主进程 `ps` 快照为 **106,368 KiB RSS、0.0% CPU**；外部 CLI 与测试进程另计。此开发机预装了 CLI，首次启动画面显示 Codex 和 Antigravity 已配置，DeepSeek Harness 需要配置。未在物理无 CLI 的独立用户环境上重复该测量。

## 复现

普通模式在新的临时 HOME、项目和数据库中导入 Git 仓库，并使用本地协议替身验证进程与文件。指定额外的已完成示例数据库时，脚本备份 SQLite，再测试双角色。目标为 `org.agenthub.desktop`，运行前需关闭其他 Agent Hub 实例。最后一个输出目录须为新目录。

```sh
scripts/ui-smoke.sh '/path/to/Agent Hub.app' /tmp/new-offline-evidence
scripts/ui-smoke.sh --history '/path/to/Agent Hub.app' /tmp/new-history-evidence
scripts/ui-smoke.sh '/path/to/Agent Hub.app' /tmp/new-paired-evidence /path/to/completed-example/data
```

显式的 `--live-codex` 模式会使用当前官方 Codex 登录及一次模型执行机会。只在授权使用当前账号、准备运行真实任务时执行。此模式不参与普通 CI。

```sh
scripts/ui-smoke.sh --live-codex '/path/to/installed/Agent Hub.app' /tmp/new-live-evidence
```
