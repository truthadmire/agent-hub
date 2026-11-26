# 首版验收进度

核查日期为 2026-11-26（新加坡）。每个编号对应原需求第 28 节的一条完整场景。勾选表示该条列出的目标层级已有可核对的通过记录。未勾选项中也列出已运行的部分；「已实现」只说明对应入口有代码。

## 连接、项目和协作

- [ ] **A01　全新安装、无 CLI**　已桌面验证 Debug 安装包在全新隔离数据目录通过 LaunchServices 启动、欢迎页正常；测试机装有 CLI。缺少所有 CLI 的干净系统尚待验证；工作流在零可用连接下保留任务和证据的测试已通过。（`BoardWelcome`、`WorkflowIsolationTests`）[桌面观察](desktop-verification.md)
- [x] **A02　仅一家已连接**　已真实接入验证。正常引擎入口只启用 Antigravity 1.5.18，以订阅运行一次，写入 status.txt。基线 grep 退出 1，结果退出 0，重开 SQLite 后仍为 completed，原项目干净。另有 single fixture 自动通过。
- [ ] **A03　Finder 启动发现 CLI**　已桌面验证。真实 LaunchServices 启动进程只有系统 PATH，欢迎页发现已配置 Codex、Antigravity，显示 DSH 需要配置。手选含空格路径、版本、登录探测另由 `ProviderTests` 自动测试。直接从 Finder 打开安装副本待验证；常规下载隔离见 A37。[桌面观察](desktop-verification.md)
- [x] **A04　无效或过期 key**　已自动测试。auth fixture 经正常引擎入口产生认证失败，数据库重开后保留任务与工作区，原因是 authentication，原项目未改动。未用实际失效的云端 key 付费调用。（`ProviderStreamDecoder`、`EngineAttempts`、`HubSmoke --fixture auth`）
- [x] **A05　导入带修改仓库**　已自动测试。实际临时仓库包含删除、重命名、二进制和未跟踪文件；创建任务快照后原工作树与原索引字节保持不变，过时预览会要求重查。独立 Git 测试组 7 项全部通过。（`GitSnapshot`、`GitWorkspaceTests.testDirtySourceIndexBytesAndInspectableSnapshot`）
- [ ] **A06　跨前后端目标**　已真实接入。CCD0267C… 是单一任务；Codex 规划后 Codex 后端与 Antigravity 前端在不同工作树分别交付，两个 grep 由退出 1 变为 0。另有 gallery fixture 测出两个先行工作项及一个确实收到上游文件的依赖项。桌面该真实任务的一卡与计划显示待观察。（`PlanRules`、`BoardTaskCard`）[运行记录](smoke.md)
- [ ] **A07　两个 agent 并行**　已真实接入。Codex 和 Antigravity 订阅 worker 同时存活，观察到重叠 18.279 秒，两个文件集成于 4dc265e。已桌面核对受控 gallery 的双角色输出、接收对象和草稿；同一真实任务的双槽桌面记录待验。（`EngineScheduling`、`WorkspaceFeed`）[运行记录](smoke.md) · [桌面记录](desktop-verification.md)
- [x] **A08　切换输入对象/发送**　已桌面验证两个角色草稿分别输入、切换后仍保留；核对成对面板截图。数据库测试验证发送归属与重放；进行中末轮的后续派发见 `EngineLifecycleTests.testInputDuringOnlyAttemptGetsNewTurnBeforeCompletion`。（`WorkspacePane`、`HubStore`）[桌面记录](desktop-verification.md)
- [ ] **A09　读历史时收到新消息**　已实现滚动锚点、历史分页和「有新消息」入口（`WorkspaceFeed`）。待在真实窗口上滚后注入新事件，确认锚点保持，并点击提示回到底部。
- [x] **A10　修改整体需求**　已自动测试。独立三角色引擎场景在第 1 版规划进程执行期间调用需求修订，再加入共享决策，持久历史 1→2→3。旧规划被中断且没有集成记录。新目标进入第 3 版三个 worker 的实际 stdin，独立测试在该版最终快照上通过。（`HubEngine.revise`、`Store.requirementHistory`）
- [x] **A11　局部改动影响公共接口**　已自动测试。通过 `HubEngine.addDecision` 写入“先筛选再分页”的共享约定；在新负责人规划和前端/后端/测试三个替身实际收到的 stdin 中核对相同决策及新目标。UI 提供显式共享决策入口。（`WorkspaceSheet`、`EngineScheduling.brief`）

## 协议、进程和恢复

- [x] **A12　JSON 与 UTF-8 分片**　已自动测试。三家 `ProviderStreamDecoder` 用例覆盖输入拆分、同块多行、增量与最终快照、文本及 token 数不重复。[适配器与复验命令](providers.md)
- [x] **A13　极快或异常退出**　已自动测试。真实子进程在 `ProcessRunnerTests` 中覆盖快速退出、信号终止、标准错误与并发大输入，核对输出及退出状态；`ProviderTests` 覆盖失败协议终态。[进程测试](../Tests/HubProcessTests/ProcessRunnerTests.swift)
- [ ] **A14　未知事件或协议错误**　已自动测试。未知非关键事件和破损协议由解码测试覆盖；protocol fixture 经过正常引擎返回 needsUser / protocolError，退出重开后仍保存。桌面该异常的交互反馈待单独观察。（`ProviderStream`、`HubSmoke --fixture protocol`）
- [x] **A15　限流重试或切换**　已自动测试。quota fixture 先触发两次 Codex 限流，再向允许的 Antigravity 切换一次，继承 partial-quota 工作区，独立检查通过。此处使用受控 CLI。（`EngineAttempts.handleFailure`、`EngineScheduling.dispatch`）
- [x] **A16　跨 provider 接力**　已自动测试。quota 替代者亲自读取前次的 partial 文件才能继续。另在三角色 gallery 测试 worker 的真实 stdin 核对目标、需求版本、基线、已改文件、共享接口、存在的 .patch 文件、基线检查结果与下一步；最终完成时的检查绑定新版提交。（`HubEngine.handoff`、`EngineScheduling.brief`）[修订与接力场景](smoke.md)
- [x] **A17　重复失败停止**　已自动测试。stalled fixture 在两次尝试和一次修复后进入 needsUser，保存失败验收，原项目保持干净。（`EngineVerification.repair`、`HubSmoke --fixture stalled`）
- [ ] **A18　暂停、继续**　已自动测试。pause fixture 在实际写入部分内容并启动子进程后暂停；确认 paused，再继续新尝试，断言子进程结束、上次写入被继承，完成独立验证。桌面多处状态同步待观察。（`HubEngine.pause/resume`）
- [x] **A19　取消后的输出**　已自动测试。cancel fixture 取消后保持一次尝试、集成 diff 为空、部分文件可读且子进程退出。StoreTests 追加旧 generation 的迟到事件后仍为 cancelled，进程测试确认 TERM 末尾输出可收尾。（`HubEngine.cancel`、`Store.appendEvent`）
- [x] **A20　运行中退出并重启**　已自动测试。restart fixture 对运行中的进程真实执行 _exit(86)，用新进程重开数据库，先得到 needs_user/interrupted；用户继续后继承未提交的部分文件，旧子进程消失，最终独立检查退出 0。原始 checkout 保持干净。（`EngineRecovery`、[引擎冒烟记录](smoke.md)）
- [x] **A21　PID 复用**　已自动测试。对仍存活的真实进程修改保存的启动时间，检查器把该身份判为不匹配；恢复扫描只核对身份，不据裸 PID 发信号。（`ProcessRunner.inspect`、`testKernelIdentityWhileSuspendedAndPIDReuseMismatch`）
- [x] **A22　两 worker 修改同一文件**　已自动测试。在真实临时仓库准备两个独立提交修改同一行，经正常引擎整合进入 needs_user / merge_conflict。冲突未解决时继续被拒；在任务工作树解决并暂存后再调用 resume，产生双父合并提交，两个子项均完成且新提交上独立检查通过。原仓库未变，未额外调用 provider。（`GitIntegration`、`EngineRecovery`、`EngineAttempts.integrate`）

## 验证、预览和日常使用

- [x] **A23　自报完成但检查失败**　已自动测试。repair fixture 首次自报成功后独立 grep 失败，实际修复、重新整合并在新快照通过。重开 SQLite 保留失败和通过两次证据。（`EngineVerification`、`HubSmoke --fixture repair`）
- [x] **A24　必需验证缺环境**　已自动测试。独立引擎探针把必需命令设为不存在的 /agenthub-missing-test-tool/verify，得到 needs_user / verification_blocked，所验提交为 3ab751ee。通过正常引擎 API 显式填写豁免理由后才 completed；SQLite 同时保留原 blocked 记录与该提交上的 waived 记录。真实产品路径见 `EngineVerification.recordHumanCheck`。
- [x] **A25　代码再次变化**　已自动测试。独立引擎探针用真实验证命令将合成项目 status.txt 格式化，旧检查的起始 commit 为 ae10a730，结束源码树不同。引擎保存修改后重跑，最终检查前后均为 77e29069、退出 0，才标记完成；源项目仍是 pending。已完成工作区被人工再次编辑后的桌面入口另待观察。（`EngineVerification`、`ResultSnapshot`）
- [x] **A26　多个预览并存**　已自动测试。两次独立 loopback HTTP 请求得到各自页面，端口不同；停止其一后另一项仍可用。另启动真实项目命令，拒绝冒用别的任务已监听的端口。（`PreviewManager`、[PreviewTests](../Tests/HubKitTests/PreviewTests.swift)）
- [ ] **A27　大量日志与历史任务**　已自动测试数据层。`StoreTests.testIndexedRefreshAndBoundedStreamWithHistory` 在 151 个任务、4,400 条事件下实保留 4,145 条；ff267e6 测量平均完整读取 5.00 ms、索引读取 0.07 ms。界面每次最多显示 60 条，实际长时间滚动及进程内存峰值仍待测。（`HubStore`、`WorkspaceFeed`）
- [ ] **A28　退出、重开、睡眠唤醒**　已实现窗口与选择持久化、重启恢复及 didWake 时重新核对时间预算（`AgentHubApp`、`HubController`、`HubEngine.reconcile`）。待观察桌面重开、实际睡眠唤醒后的进程与任务状态。
- [x] **A29　中文、空格和特殊字符**　已自动测试。真实子进程用含中文及空格的工作目录、含 shell 替换符的字面 argv，输出与输入一致；手选 CLI 路径的空格也已覆盖。（`ProcessRunnerTests.testArgvCwdControlledEnvironmentAndFastExit`、`ProviderTests`）
- [x] **A30　日志和诊断导出**　已自动测试。结果页可预览并导出 allowlist JSON；测试将同一合成敏感值写入路径、命令、模型输出、事件种类与详情、版本和验证证据，序列化后全文不含该值，仍能读取退出码和 provider。入库脱敏、参数清理另有独立测试。（`TaskDiagnostics`、`TaskDiagnosticButton`、`DiagnosticsTests.testReportExportsEvidenceWithoutProjectTextOrCredentials`）
- [ ] **A31　归档、恢复和清理**　已实现归档及还原；成果区有可确认的已归档任务尝试清理入口。`GitWorkspaceTests` 已验证受管工作树身份、未合入或被替代目录不得清理、忽略文件保护及保留 Git 分支。归档、实际点击清理与重开成果的整个桌面路径待验。（`ResultHistory`、`GitIntegration.removeWorkspace`）
- [ ] **A32　窄窗口、主题、键盘**　已实现紧凑布局、深浅色与原生快捷键（`WorkspaceView`、`DesignSystem`、`AgentHubApp`）。XCUITest 运行器编译成功，实际窗口断言和截图待验证。[桌面记录](desktop-verification.md)

## 工程、真实接入与发行

- [ ] **A33　普通 PR 无模型凭据**　已在本机运行完整 `swift test`（ff267e6，共 68 项，其中 65 项通过、3 个安装探测按设计跳过，0 失败），gallery fixture 也通过。远端 PR 工作流受仓库目标缺失阻塞。[CI 配置](../.github/workflows/verify.yml) · [冒烟记录](smoke.md)
- [ ] **A34　三家真实接入**　部分已真实接入。Codex 0.170.0 与 Antigravity 1.5.18 均经正常 HubEngine 完成付诸文件的工作和独立检查，另有真实双订阅并行。DSH 0.2.0-rc.2 已以真实 CLI 验证配置和沙箱，缺应用专属钥匙串 key，未发真实模型请求。[接入记录](providers.md) · [逐次真实结果](smoke.md)
- [x] **A35　macOS 源码构建**　已在 Apple M1 Pro、macOS 26.6.2/Xcode 27.0/Swift 6.4 构建源码提交 ff267e6 的应用、监护 helper 及测试产品。真实 Debug .app 已通过包结构与 ad-hoc 校验并在 LaunchServices 开窗。正式签名与分发是 A36–A38 的独立项。[编译与产物](verification.md)
- [ ] **A36　正式签名和公证**　已实现 Developer ID 签名、Apple 公证和票据检查脚本；已查有可用签名身份。正式产品签名待执行，公证受专用 profile 或相应 Apple 凭据阻塞。[发行流程](releasing.md)
- [ ] **A37　DMG 下载、安装和启动**　已实现 DMG 只读挂载及安装副本验证。合成微型包预检通过；Agent Hub 的正式下载、隔离标记、Finder 安装与 Gatekeeper 验证待执行。[发行流程](releasing.md)
- [ ] **A38　安装后执行真实任务**　待通过安装副本连接 provider、创建任务并核对实际 diff 和检查结果；命令行工作流不替代安装后验收。
- [ ] **A39　GitHub 开源交付**　本地已建立 main 分支及首个提交 ff267e6，包含源码、许可证、第三方声明、文档和双 CI 工作流。远端仓库归属、名称尚未指定，尚无实际 PR CI、公开 Release 或下载地址。[第三方说明](../THIRD_PARTY_NOTICES.md) · [发行流程](releasing.md)
- [ ] **A40　结果报告**　本表与底座、连接、桌面、发行报告均按实际证据区分层级。待本轮代码冻结后对齐最终提交、测试、产物版本和外部阻塞。

完整场景的可复验步骤与证据见[验证汇总](verification.md)、[工作流与真实 CLI 记录](smoke.md)、[原生桌面验收](desktop-verification.md)和[发行流程](releasing.md)。[底座选型](architecture/base-selection.md)记录了系统与上游模块探针。
