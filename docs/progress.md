# 首版验收进度

2026-11-26 至 2026-11-27（新加坡）核查了原需求第 28 节的 40 个场景，35 项达到对应的验收层级。其余 5 项涉及物理睡眠唤醒、DSH 真实账号调用，以及已安排延期的公证、正式下载和稳定版 Release。每项列有实现位置、已执行的验证和适用条件。

## 连接、项目和协作

- [x] **A01　全新安装、无 CLI**　已在干净托管 macOS 主机完成首次启动实测（2026-11-27 00:05:30 SGT）。通过 LaunchServices 打开安装副本后出现 1 个屏上窗口，SQLite schema 3、0 项目、0 任务。三个探测均完成，路径与版本均为空，App 正常退出。连接与官方安装入口可在 `BoardWelcome` 和 `SettingsConnections` 定位。该次 CI 未逐个点击安装按钮。[首启运行记录](https://github.com/truthadmire/agent-hub/actions/runs/45854361787)
- [x] **A02　仅一家已连接**　已真实接入验证。正常引擎入口只启用 Antigravity 1.5.18，以订阅运行一次，写入 status.txt。基线 grep 退出 1，结果退出 0，重开 SQLite 后仍为 completed，原项目干净。另有 single fixture 自动通过。
- [x] **A03　Finder 启动发现 CLI**　已桌面验证。Finder 冷启动隔离开发副本后，核对实际进程路径、空数据库和全新检测记录，找到了 Codex 0.170.0、Antigravity 1.5.18 和 DSH 0.2.0-rc.2。手选含空格路径由 `ProviderTests` 自动测试。正式分发包的安装和 Gatekeeper 状态分别见 A36–A38。[桌面观察](desktop-verification.md)
- [x] **A04　无效或过期 key**　已自动测试。auth fixture 经正常引擎入口产生认证失败，数据库重开后保留任务与工作区，原因是 authentication，原项目未改动。未用实际失效的云端 key 付费调用。（`ProviderStreamDecoder`、`EngineAttempts`、`HubSmoke --fixture auth`）
- [x] **A05　导入带修改仓库**　已自动测试。实际临时仓库包含删除、重命名、二进制和未跟踪文件；创建任务快照后原工作树与原索引字节保持不变，过时预览会要求重查。独立 Git 测试组 7 项全部通过。（`GitSnapshot`、`GitWorkspaceTests.testDirtySourceIndexBytesAndInspectableSnapshot`）
- [x] **A06　跨前后端目标**　已真实接入。CCD0267C… 是单一任务；Codex 规划后 Codex 后端与 Antigravity 前端在不同工作树分别交付，两个 grep 由退出 1 变为 0。另有 gallery fixture 测出两个先行工作项及一个确实收到上游文件的依赖项。在真实任务 SQLite 的隔离副本上，桌面 XCTest 确认看板只有一张可打开的目标卡；其两份实际 worker 输出可从同一任务查看。（`PlanRules`、`BoardTaskCard`）[运行记录](smoke.md)
- [x] **A07　两个 agent 并行**　已真实接入。Codex 和 Antigravity 订阅 worker 同时存活，观察到重叠 18.279 秒，两个文件集成于 4dc265e。签名安装副本的桌面 XCTest 打开该真实任务数据库的隔离副本，检查前后端实际输出、各自的接收控件和切换后草稿。测试窗口读取的是已完成的两次真实执行。[双订阅桌面截图](images/desktop-live-team.png)（`EngineScheduling`、`WorkspaceFeed`）[运行记录](smoke.md) · [桌面记录](desktop-verification.md)
- [x] **A08　切换输入对象/发送**　已桌面验证两个角色草稿分别输入、切换后仍保留；核对成对面板截图。数据库测试验证发送归属与重放；进行中末轮的后续派发见 `EngineLifecycleTests.testInputDuringOnlyAttemptGetsNewTurnBeforeCompletion`。（`WorkspacePane`、`HubStore`）[桌面记录](desktop-verification.md)
- [x] **A09　读历史时收到新消息**　已桌面验证最终签名安装版。以 100 条受控进程事件填充会话，进入较早页后观测指定历史行及纵坐标；新输出抵达时出现提示，原行偏移不超过 3 pt。点击后可见指定的新消息，XCTest 通过（22.967 秒）。（`WorkspaceFeed`）[桌面记录](desktop-verification.md)
- [x] **A10　修改整体需求**　已自动测试。独立三角色引擎场景在第 1 版规划进程执行期间调用需求修订，再加入共享决策，持久历史 1→2→3。旧规划被中断且没有集成记录。新目标进入第 3 版三个 worker 的实际 stdin，独立测试在该版最终快照上通过。（`HubEngine.revise`、`Store.requirementHistory`）
- [x] **A11　局部改动影响公共接口**　已自动测试。通过 `HubEngine.addDecision` 写入“先筛选再分页”的共享约定；在新负责人规划和前端/后端/测试三个替身实际收到的 stdin 中核对相同决策及新目标。UI 提供显式共享决策入口。（`WorkspaceSheet`、`EngineScheduling.brief`）

## 协议、进程和恢复

- [x] **A12　JSON 与 UTF-8 分片**　已自动测试。三家 `ProviderStreamDecoder` 用例覆盖输入拆分、同块多行、增量与最终快照、文本及 token 数不重复。[适配器与复验命令](providers.md)
- [x] **A13　极快或异常退出**　已自动测试。真实子进程在 `ProcessRunnerTests` 中覆盖快速退出、信号终止、标准错误与并发大输入，核对输出及退出状态；`ProviderTests` 覆盖失败协议终态。[进程测试](../Tests/HubProcessTests/ProcessRunnerTests.swift)
- [x] **A14　未知事件或协议错误**　已自动、桌面测试。未知非关键事件与破损 JSON 有解码覆盖；protocol fixture 经引擎返回 needs_user / protocolError，重开后仍保存。签名安装版回放该任务，实际显示「需要你」「CLI 返回了无效 JSON」，看板可「打开并处理」「重试」，详情的「继续处理」可用。（`ProviderStream`、`HubSmoke --fixture protocol`）[桌面记录](desktop-verification.md)
- [x] **A15　限流重试或切换**　已自动测试。quota fixture 先触发两次 Codex 限流，再向允许的 Antigravity 切换一次，继承 partial-quota 工作区，独立检查通过。此处使用受控 CLI。（`EngineAttempts.handleFailure`、`EngineScheduling.dispatch`）
- [x] **A16　跨 provider 接力**　已自动测试。quota 替代者亲自读取前次的 partial 文件才能继续。另在三角色 gallery 测试 worker 的真实 stdin 核对目标、需求版本、基线、已改文件、共享接口、存在的 .patch 文件、基线检查结果与下一步；最终完成时的检查绑定新版提交。（`HubEngine.handoff`、`EngineScheduling.brief`）[修订与接力场景](smoke.md)
- [x] **A17　重复失败停止**　已自动测试。stalled fixture 在两次尝试和一次修复后进入 needsUser，保存失败验收，原项目保持干净。（`EngineVerification.repair`、`HubSmoke --fixture stalled`）
- [x] **A18　暂停、继续**　已自动、桌面测试。签名安装版收到第 84 条受控 CLI 活动后从详情点暂停，SQLite 先写 pausing 再写 paused；详情「继续」与看板「已暂停」一致。从看板继续后详情恢复暂停按钮，第二次尝试从保留的 partial 文件续做，最终独立验证通过。（`HubEngine.pause/resume`）[桌面记录](desktop-verification.md)
- [x] **A19　取消后的输出**　已自动测试。cancel fixture 取消后保持一次尝试、集成 diff 为空、部分文件可读且子进程退出。StoreTests 追加旧 generation 的迟到事件后仍为 cancelled，进程测试确认 TERM 末尾输出可收尾。（`HubEngine.cancel`、`Store.appendEvent`）
- [x] **A20　运行中退出并重启**　已自动测试。restart fixture 对运行中的进程真实执行 _exit(86)，用新进程重开数据库，先得到 needs_user/interrupted；用户继续后继承未提交的部分文件，旧子进程消失，最终独立检查退出 0。原始 checkout 保持干净。（`EngineRecovery`、[引擎冒烟记录](smoke.md)）
- [x] **A21　PID 复用**　已自动测试。对仍存活的真实进程修改保存的启动时间，检查器把该身份判为不匹配；恢复扫描只核对身份，不据裸 PID 发信号。（`ProcessRunner.inspect`、`testKernelIdentityWhileSuspendedAndPIDReuseMismatch`）
- [x] **A22　两 worker 修改同一文件**　已自动测试。在真实临时仓库准备两个独立提交修改同一行，经正常引擎整合进入 needs_user / merge_conflict。冲突未解决时继续被拒；在任务工作树解决并暂存后再调用 resume，产生双父合并提交，两个子项均完成且新提交上独立检查通过。原仓库未变，未额外调用 provider。（`GitIntegration`、`EngineRecovery`、`EngineAttempts.integrate`）

## 验证、预览和日常使用

- [x] **A23　自报完成但检查失败**　已自动测试。repair fixture 首次自报成功后独立 grep 失败，实际修复、重新整合并在新快照通过。重开 SQLite 保留失败和通过两次证据。（`EngineVerification`、`HubSmoke --fixture repair`）
- [x] **A24　必需验证缺环境**　已自动测试。独立引擎探针把必需命令设为不存在的 /agenthub-missing-test-tool/verify，得到 needs_user / verification_blocked，所验提交为 3ab751ee。通过正常引擎 API 显式填写豁免理由后才 completed；SQLite 同时保留原 blocked 记录与该提交上的 waived 记录。真实产品路径见 `EngineVerification.recordHumanCheck`。
- [x] **A25　代码再次变化**　已自动测试。独立引擎探针用真实验证命令将合成项目 status.txt 格式化，旧检查的起始 commit 为 ae10a730，结束源码树不同。引擎保存修改后重跑，最终检查前后均为 77e29069、退出 0，才标记完成；源项目仍是 pending。已完成工作区被人工再次编辑后的桌面入口另待观察。（`EngineVerification`、`ResultSnapshot`）
- [x] **A26　多个预览并存**　已自动测试。两次独立 loopback HTTP 请求得到各自页面，端口不同；停止其一后另一项仍可用。另启动真实项目命令，拒绝冒用别的任务已监听的端口。（`PreviewManager`、[PreviewTests](../Tests/HubKitTests/PreviewTests.swift)）
- [x] **A27　大量日志与历史任务**　已完成有界负载和桌面抽样。151 个任务、4,400 条事件实保留 4,145 条；ff267e6 上完整读取平均 5.00 ms、索引读取 0.07 ms。每页 60 条，签名版在 100 条受控活动下可翻页、阅读及接收新消息。对输出、UI 交互与尝试重启并存的 26.251 秒取 36 个主进程样本，RSS 177,328–209,472 KiB、CPU 0.3–61.2%。长期内存增长与更多任务量仍待观测。（`StoreTests.testIndexedRefreshAndBoundedStreamWithHistory`、`WorkspaceFeed`）[桌面记录](desktop-verification.md)
- [ ] **A28　退出、重开、睡眠唤醒**　已实现窗口与选择持久化、重启恢复及 didWake 时重新核对时间预算（`AgentHubApp`、`HubController`、`HubEngine.reconcile`）。已桌面验证关闭主窗口后进程保留、LaunchServices 重开恢复任务，以及签名安装副本完整退出重开后 A38 真实 Codex 成果仍可见。物理睡眠/唤醒与执行中网络变化未实测。
- [x] **A29　中文、空格和特殊字符**　已自动测试。真实子进程用含中文及空格的工作目录、含 shell 替换符的字面 argv，输出与输入一致；手选 CLI 路径的空格也已覆盖。（`ProcessRunnerTests.testArgvCwdControlledEnvironmentAndFastExit`、`ProviderTests`）
- [x] **A30　日志和诊断导出**　已自动测试。结果页可预览并导出 allowlist JSON；测试将同一合成敏感值写入路径、命令、模型输出、事件种类与详情、版本和验证证据，序列化后全文不含该值，仍能读取退出码和 provider。入库脱敏、参数清理另有独立测试。（`TaskDiagnostics`、`TaskDiagnosticButton`、`DiagnosticsTests.testReportExportsEvidenceWithoutProjectTextOrCredentials`）
- [x] **A31　归档、恢复和清理**　已自动、桌面测试。签名安装版从归档历史进入成果页，对已整合尝试点击清理并确认。SQLite 记录 workspace.cleaned，目标目录移除，中断/失败尝试、成果工作树和验收仍在。保留分支 71e1d789ee41a0694f9ddc34287ff442d85d9086 仍可读出 verified，源仓库保持 pending、Git clean。另在冲突夹具中关闭/重开数据库并取消归档，2 份补丁字节保持一致。（`ResultHistory`、`GitIntegration.removeWorkspace`）[桌面记录](desktop-verification.md)
- [x] **A32　窄窗口、主题、键盘**　已实现紧凑布局、深浅色与原生快捷键（`WorkspaceView`、`DesignSystem`、`AgentHubApp`）。已桌面验证最终签名安装版从 1280×805 收窄到 760×650 pt，接收对象与输入区可用。实际切换深色、浅色并核对画面；⌘K、Esc、⌘N 通过。[桌面记录](desktop-verification.md)

## 工程、真实接入与发行

- [x] **A33　普通 PR 无模型凭据**　本机 ff267e6 普通模式 65 项通过、3 个实装探测按设计跳过；c1f8ffe 启用实装探测后 70/70 通过。托管 macOS 上，相同的 Verify 作业在签名包源码 8795c4a 及提交 c23143e 均成功，覆盖无模型凭据测试、gallery、arm64 包与挂载复验。两次实跑均由 main 的 push 触发，PR 使用同一作业。[签名源码 CI](https://github.com/truthadmire/agent-hub/actions/runs/45851368401) · [含干净首启的 CI](https://github.com/truthadmire/agent-hub/actions/runs/45854361787) · [CI 配置](../.github/workflows/verify.yml)
- [ ] **A34　三家真实接入**　部分已真实接入。Codex 0.170.0 与 Antigravity 1.5.18 均经正常 HubEngine 完成付诸文件的工作和独立检查，另有真实双订阅并行。DSH 0.2.0-rc.2 已以真实 CLI 验证配置和沙箱，缺应用专属钥匙串 key，未发真实模型请求。[接入记录](providers.md) · [逐次真实结果](smoke.md)
- [x] **A35　macOS 源码构建**　在干净签出 8795c4ad77105fbc4fa962f67299875a075d7aba 上实际构建版本 0.1.0（1）、arm64、最低 macOS 14.0。工具链 Xcode 27.0/Swift 6.4；本机实际生成 .app、helper 和 DMG，核对二进制架构及依赖。[构建源码](https://github.com/truthadmire/agent-hub/commit/8795c4ad77105fbc4fa962f67299875a075d7aba) · [分发记录](verification.md)
- [ ] **A36　正式签名和公证**　已签名。Developer ID Application 的团队要求对 helper、App、DMG 均通过；两个可执行程序验证了安全时间戳与 Hardened Runtime。用户决定推迟公证，本轮没有 Apple submission 或票据。
- [ ] **A37　DMG 下载、安装和启动**　已验证 0.1.0 的签名 DMG，2,822,828 字节，SHA-256 为 `76cfb80f4e987bb8c87386e4b820fde8848f84399eb344a64a0ddbdb91a3ae8c`。只读挂载、复制安装及复制后签名复核通过；签名安装副本已通过 LaunchServices 在实际桌面启动并操作。签名 App 本机 Gatekeeper 评估返回退出码 3（Unnotarized Developer ID）。用户已推迟公证及稳定 Release，下载后的隔离标记与正式 Gatekeeper 放行尚待复验。[分发记录](verification.md)
- [x] **A38　安装后执行真实任务**　已在最终 DMG 的 Developer ID 安装副本内通过 GUI 创建任务；经用户授权复用官方 Codex 登录，实际修改并整合 status.txt，最终提交 1eeb7785f0c67ac3673400f43bf53693c7e306b3。独立 grep 基线退出 1、最终退出 0；原仓库保留 pending 且 Git 状态干净，签名 App 退出重开后仍显示 completed 和成果。任务 ID 为 8AFF2A55-7CA4-4416-9FBF-ABD348CAB47E。另有安装副本的离线受控 CLI 版闭环。[签名安装副本桌面记录](desktop-verification.md)
- [ ] **A39　GitHub 开源交付**　已建立公开 GitHub 仓库，main 首次推送包含签名包对应的 8795c4a。许可证、第三方声明、源码与双 CI 工作流已公开。用户决定推迟公证及稳定 Release；远端检查结果见 A33。[公开仓库](https://github.com/truthadmire/agent-hub) · [发行流程](releasing.md)
- [x] **A40　结果报告**　已记录签名包源码、大小、SHA-256、Developer ID 和 Gatekeeper 结果，区分本机测试、远端 CI、受控 CLI、正式订阅和签名安装副本。DSH 真实付费调用、公开下载与公证、未实测桌面情形均逐项列出。[验证汇总](verification.md) · [真实运行索引](../Examples/Evidence/2026-11-26.json)

完整场景的可复验步骤与证据见[验证汇总](verification.md)、[工作流与真实 CLI 记录](smoke.md)、[原生桌面验收](desktop-verification.md)和[发行流程](releasing.md)。[底座选型](architecture/base-selection.md)记录了系统与上游模块探针。
