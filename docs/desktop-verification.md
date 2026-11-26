# 原生桌面验收

测试机为 MacBook Pro（Apple M1 Pro、16 GiB），运行 macOS 26.6.2（25G83）。测试使用 Xcode 27.0（27A266a）、XcodeGen 2.44.1 和已登录的原生桌面会话。验收于 2026-11-26 至 27 日执行，使用新加坡时间。

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

2026-11-27 00:11:17–22（新加坡），通过 Finder 的打开操作冷启动开发版的临时副本。该副本使用一次性 bundle ID 和独立的数据目录，经过 ad hoc 重签。Finder 返回成功，核对了进程 ID、实际应用包及可执行文件路径。新建的 schema 3 数据库有 0 个项目和 0 个任务。该进程自动找到 Homebrew 的 Codex 0.170.0、用户安装目录的 Antigravity 1.5.18 和 Homebrew 的 DSH 0.2.0-rc.2。最后正常退出。此项测量覆盖 Finder 冷启动和 CLI 发现。

使用同一设备、ad-hoc 签名的 Debug 包及全新专用数据库测量，从发出 LaunchServices 打开请求到首次读到主进程的 AXWindow 为 **1.917 秒**。启动后第 14 秒，主进程 `ps` 快照为 **106,368 KiB RSS、0.0% CPU**；外部 CLI 与测试进程另计。此开发机预装了 CLI，首次启动画面显示 Codex 和 Antigravity 已配置，DeepSeek Harness 需要配置。未在物理无 CLI 的独立用户环境上重复该测量。

## 协议错误、暂停、清理和资源采样

11 月 27 日的补测继续使用上述 Developer ID 安装副本。所有模型输出均来自受控本地 CLI。A14 读取已有 `fixture-protocol` 数据库的副本；A18、A31 使用新的临时 Git 仓库，以及同一任务 `4DA31F47-A123-4F0C-8387-EC4D20D7FC4B`。

| 场景 | 原生操作与独立核对 |
|---|---|
| A14 协议错误 | 打开协议错误任务。卡片菜单提供“打开并处理”和“重试”，详情显示“需要你”“CLI 返回了无法识别的事件”“CLI 返回了无效 JSON。”；“继续处理”按钮可用。数据库记录为 `needs_user / protocolError`。本项检查恢复入口，未重新派发。 |
| A18 暂停与继续 | 收到 84 条活动时从详情点击“暂停”。数据库依次记入 `task.pausing` 和 `task.paused`，详情出现“继续”，返回看板后卡片显示“已暂停”。从看板菜单点击“继续”，详情重新出现“暂停”。首个尝试状态为 interrupted，保存的 `status.txt` 为 `partial\n`；第二次尝试先核对该内容再工作，最后完成。整合区 grep 从基线退出 1 到最终退出 0。独立原生 XCTest 用例通过，用时 35.808 秒。 |
| A31 归档与清理 | 从卡片菜单归档，在历史归档中重开任务，从成果页展开执行尝试，选中“负责人 · Codex · 本轮已结束”，点击“清理尝试工作区…”并在原生确认框选择“清理工作目录”。数据库记录 `workspace.cleaned`。成功尝试的目录已消失；它的保留分支和任务整合工作树仍指向 `71e1d789ee41a0694f9ddc34287ff442d85d9086`，分别用 `git show` 和文件读取核对为 `verified\n`。中断尝试的分支和目录仍保留，原项目文件仍为 `pending\n`，Git 工作区干净。 |

此次补测同时使用 XCTest 和按签名 App 路径、PID 限定的系统辅助功能操作。A14 的初版自动断言与实际中文提示不同，A31 的初版滚动选择器未找到空标识的控件；表中相应细项由实际可访问性树、原生按钮操作和 SQLite/Git 核对完成。

A27 的资源样本来自 A18 运行期间。外部采样器核对进程可执行路径后对同一个 Agent Hub PID 执行 `ps -p PID -o rss=,%cpu=`。从第一至最后一个样本间隔 **26.251 秒**，运行状态共取 **36 个样本**，覆盖流式输出、应用界面操作和恢复后的第二次尝试。App 主进程 RSS 范围 **177,328–209,472 KiB**，CPU 范围 **0.3%–61.2%**。采样器只记录 App 主进程；外部 CLI、进程守护助手与测试运行器位于其他 PID。CPU 为各次 `ps` 读数。长时间持续运行时的内存曲线仍需单独测量。原始计数、采样时间和独立存储核对保存在本机忽略目录 `dist/evidence/desktop/followup/`。

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
