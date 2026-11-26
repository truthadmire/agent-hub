# 首版验收进度

核查日期为 2026-11-26（新加坡）。每个编号对应原需求第 28 节的一条完整场景。勾选表示该条列出的目标层级已有可核对的通过记录。未勾选项中也列出已运行的部分；「已实现」只说明对应入口有代码。

## 连接、项目和协作

- [ ] **A01　全新安装、无 CLI**　已实现欢迎页、三家连接和安装入口（`BoardWelcome`、`SettingsConnections`、`ProviderDiscovery`）。待在缺少所有 CLI 的实际安装环境启动并逐项核对。
- [x] **A02　仅一家已连接**　已真实接入验证。正常引擎入口只启用 Antigravity 1.5.18，以订阅运行一次，写入 status.txt。基线 grep 退出 1，结果退出 0，重开 SQLite 后仍为 completed，原项目干净。另有 single fixture 自动通过。
- [ ] **A03　Finder 启动发现 CLI**　已实现固定路径发现和手选覆盖；`ProviderTests.testFinderManualSelectionAndDetectionWithoutModel` 已自动测试含空格路径、版本与登录探测。独立启动 Finder 安装副本的结果待验证。
- [x] **A04　无效或过期 key**　已自动测试。auth fixture 经正常引擎入口产生认证失败，数据库重开后保留任务与工作区，原因是 authentication，原项目未改动。未用实际失效的云端 key 付费调用。（`ProviderStreamDecoder`、`EngineAttempts`、`HubSmoke --fixture auth`）
- [x] **A05　导入带修改仓库**　已自动测试。实际临时仓库包含删除、重命名、二进制和未跟踪文件；创建任务快照后原工作树与原索引字节保持不变，过时预览会要求重查。Git 测试组 6 项全部通过。（`GitSnapshot`、`GitWorkspaceTests.testDirtySourceIndexBytesAndInspectableSnapshot`）
- [ ] **A06　跨前后端目标**　已实现一任务一卡；gallery fixture 以一个目标启动四次尝试，三文件集成，4 个 Python 单测及本机 HTTP 预览通过。桌面实际查看该任务的多角色计划与依赖待验证。（`BoardTaskCard`、`PlanRules`、`WorkspaceSheet`）
- [ ] **A07　两个 agent 并行**　已自动测试 gallery 内两个受控 CLI 确有运行区间重叠，合入不同文件。已实现双角色事件过滤及双面板；两份真实订阅输出在实际窗口的归属与输入未同时验证。（`Examples/FixtureCLI/provider.py`、`EngineScheduling`、`WorkspaceFeed`）
- [ ] **A08　切换输入对象/发送**　已实现按任务与接收对象持久化草稿（`WorkspacePane`、`Store.saveDraft`）。`StoreTests.testDraftQueueReplayAndConversationPages`、桌面草稿用例覆盖不同层级。进行中末轮消息须验证能在当前轮后续接，见下方调度场景。
- [ ] **A09　读历史时收到新消息**　已实现滚动锚点、历史分页和「有新消息」入口（`WorkspaceFeed`）。待在真实窗口上滚后注入新事件，确认锚点保持，并点击提示回到底部。
- [ ] **A10　修改整体需求**　已实现需求、计划和 generation 递增、历史保留及重规划（`HubEngine.revise`、`Store.saveRevisions`、`ResultVerification`）。待测执行中修订、迟到旧结果、用户界面与新验收的完整组合。
- [ ] **A11　局部改动影响公共接口**　已实现记录共享决策、重新规划以及下一尝试读到决策（`WorkspaceSheet`、`HubEngine.addDecision`、`EngineScheduling.brief`）。待用两角色核实共享决策可见、两边实际收到并遵守新版接口。

## 协议、进程和恢复

- [x] **A12　JSON 与 UTF-8 分片**　已自动测试。三家 `ProviderStreamDecoder` 用例覆盖输入拆分、同块多行、增量与最终快照、文本及 token 数不重复。[适配器与复验命令](providers.md)
- [x] **A13　极快或异常退出**　已自动测试。真实子进程在 `ProcessRunnerTests` 中覆盖快速退出、信号终止、标准错误与并发大输入，核对输出及退出状态；`ProviderTests` 覆盖失败协议终态。[进程测试](../Tests/HubProcessTests/ProcessRunnerTests.swift)
- [ ] **A14　未知事件或协议错误**　已自动测试。未知非关键事件和破损协议由解码测试覆盖；protocol fixture 经过正常引擎返回 needsUser / protocolError，退出重开后仍保存。桌面该异常的交互反馈待单独观察。（`ProviderStream`、`HubSmoke --fixture protocol`）
- [x] **A15　限流重试或切换**　已自动测试。quota fixture 先触发两次 Codex 限流，再向允许的 Antigravity 切换一次，继承 partial-quota 工作区，独立检查通过。此处使用受控 CLI。（`EngineAttempts.handleFailure`、`EngineScheduling.dispatch`）
- [ ] **A16　跨 provider 接力**　已实现持久交接包、工作树引用和前次尝试关系（`HubEngine.handoff`、`EngineScheduling.brief`）。待验证新 provider 实际收到具体产物、验证结果与下一步，检查传入提示而非只查数据库字段。
- [x] **A17　重复失败停止**　已自动测试。stalled fixture 在两次尝试和一次修复后进入 needsUser，保存失败验收，原项目保持干净。（`EngineVerification.repair`、`HubSmoke --fixture stalled`）
- [ ] **A18　暂停、继续**　已自动测试。pause fixture 在实际写入部分内容并启动子进程后暂停；确认 paused，再继续新尝试，断言子进程结束、上次写入被继承，完成独立验证。桌面多处状态同步待观察。（`HubEngine.pause/resume`）
- [x] **A19　取消后的输出**　已自动测试。cancel fixture 取消后保持一次尝试、集成 diff 为空、部分文件可读且子进程退出。StoreTests 追加旧 generation 的迟到事件后仍为 cancelled，进程测试确认 TERM 末尾输出可收尾。（`HubEngine.cancel`、`Store.appendEvent`）
- [x] **A20　运行中退出并重启**　已自动测试。restart fixture 对运行中的进程真实执行 _exit(86)，用新进程重开数据库，先得到 needs_user/interrupted；用户继续后继承未提交的部分文件，旧子进程消失，最终独立检查退出 0。原始 checkout 保持干净。（`EngineRecovery`、[引擎冒烟记录](smoke.md)）
- [x] **A21　PID 复用**　已自动测试。对仍存活的真实进程修改保存的启动时间，检查器把该身份判为不匹配；恢复扫描只核对身份，不据裸 PID 发信号。（`ProcessRunner.inspect`、`testKernelIdentityWhileSuspendedAndPIDReuseMismatch`）
- [ ] **A22　两 worker 修改同一文件**　已实现分支隔离和 Git 冲突留存，`GitWorkspaceTests.testParallelBranchesConflictRestartResolutionAndAdoption` 覆盖底层。待复验从引擎/UI 运行路径修复、暂存、继续后能完成原合并。（`GitIntegration`、`EngineAttempts.integrate`）

## 验证、预览和日常使用

- [x] **A23　自报完成但检查失败**　已自动测试。repair fixture 首次自报成功后独立 grep 失败，实际修复、重新整合并在新快照通过。重开 SQLite 保留失败和通过两次证据。（`EngineVerification`、`HubSmoke --fixture repair`）
- [x] **A24　必需验证缺环境**　已自动测试。独立引擎探针把必需命令设为不存在的 /agenthub-missing-test-tool/verify，得到 needs_user / verification_blocked，所验提交为 3ab751ee。通过正常引擎 API 显式填写豁免理由后才 completed；SQLite 同时保留原 blocked 记录与该提交上的 waived 记录。真实产品路径见 `EngineVerification.recordHumanCheck`。
- [x] **A25　代码再次变化**　已自动测试。独立引擎探针用真实验证命令将合成项目 status.txt 格式化，旧检查的起始 commit 为 ae10a730，结束源码树不同。引擎保存修改后重跑，最终检查前后均为 77e29069、退出 0，才标记完成；源项目仍是 pending。已完成工作区被人工再次编辑后的桌面入口另待观察。（`EngineVerification`、`ResultSnapshot`）
- [x] **A26　多个预览并存**　已自动测试。两次独立 loopback HTTP 请求得到各自页面，端口不同；停止其一后另一项仍可用。另启动真实项目命令，拒绝冒用别的任务已监听的端口。（`PreviewManager`、[PreviewTests](../Tests/HubKitTests/PreviewTests.swift)）
- [ ] **A27　大量日志与历史任务**　已自动测试数据层。`StoreTests.testIndexedRefreshAndBoundedStreamWithHistory` 在 151 个任务、4,400 条事件下实保留 4,145 条；本次平均完整读取 6.56 ms、索引读取 0.08 ms。界面每次最多显示 60 条，实际长时间滚动及进程内存峰值仍待测。（`HubStore`、`WorkspaceFeed`）
- [ ] **A28　退出、重开、睡眠唤醒**　已实现窗口与选择持久化、重启恢复及 didWake 时重新核对时间预算（`AgentHubApp`、`HubController`、`HubEngine.reconcile`）。待观察桌面重开、实际睡眠唤醒后的进程与任务状态。
- [x] **A29　中文、空格和特殊字符**　已自动测试。真实子进程用含中文及空格的工作目录、含 shell 替换符的字面 argv，输出与输入一致；手选 CLI 路径的空格也已覆盖。（`ProcessRunnerTests.testArgvCwdControlledEnvironmentAndFastExit`、`ProviderTests`）
- [ ] **A30　日志和诊断导出**　已实现入库脱敏、连接诊断和日志边界（`HubRedaction`、`ProviderStreamDecoder`、`SettingsGeneral`）。合成凭据已在协议测试中检查；待核对桌面导出范围与任务诊断结果。
- [ ] **A31　归档、恢复和清理**　已实现归档标记及 Git 受管工作树校验（`HubController.perform`、`GitIntegration.removeWorkspace`）。待从已归档任务实际清理合格工作树，复查成果仍可恢复，脏目录和替代目录仍保留。
- [ ] **A32　窄窗口、主题、键盘**　已实现紧凑布局、深浅色与原生快捷键（`WorkspaceView`、`DesignSystem`、`AgentHubApp`）。XCUITest 运行器编译成功，实际窗口断言和截图待验证。[桌面记录](desktop-verification.md)

## 工程、真实接入与发行

- [ ] **A33　普通 PR 无模型凭据**　已在本机运行完整 `swift test`（23:19 SGT，47 项通过，3 个安装探测按设计跳过，0 失败），gallery fixture 也通过。远端 PR工作流受仓库目标缺失阻塞。[CI 配置](../.github/workflows/verify.yml) · [冒烟记录](smoke.md)
- [ ] **A34　三家真实接入**　部分已真实接入。最终 Antigravity 1.5.18 适配参数经正常 HubEngine 重跑一次，通过修改、独立验证、原区核对及数据库重开。Codex 0.170.0 已在临时工作区通过直接 CLI 写文件。DSH 0.2.0-rc.2 已验证真实配置及沙箱，缺 Agent Hub 专属钥匙串 key，未发真实模型请求。[接入记录](providers.md) · [逐次真实结果](smoke.md)
- [ ] **A35　macOS 源码构建**　已建立 macOS 14+ SwiftPM 工程。底座探针、多个模块与 UI 测试运行器各自构建成功。待记录完整工程 build、arm64 app、对应源码标识及二进制检查结果。
- [ ] **A36　正式签名和公证**　已实现 Developer ID 签名、Apple 公证和票据检查脚本；已查有可用签名身份。正式产品签名待执行，公证受专用 profile 或相应 Apple 凭据阻塞。[发行流程](releasing.md)
- [ ] **A37　DMG 下载、安装和启动**　已实现 DMG 只读挂载及安装副本验证。合成微型包预检通过；Agent Hub 的正式下载、隔离标记、Finder 安装与 Gatekeeper 验证待执行。[发行流程](releasing.md)
- [ ] **A38　安装后执行真实任务**　待通过安装副本连接 provider、创建任务并核对实际 diff 和检查结果；命令行工作流不替代安装后验收。
- [ ] **A39　GitHub 开源交付**　已建立本地许可证、第三方声明与 CI/release 配置。远端仓库归属和名称待指定，尚无公开 Release 或下载地址。[第三方说明](../THIRD_PARTY_NOTICES.md)
- [ ] **A40　结果报告**　本表与底座、连接、桌面、发行报告均按实际证据区分层级。待本轮代码冻结后对齐最终提交、测试、产物版本和外部阻塞。

完整场景的可复验步骤与证据见[工作流与真实 CLI 记录](smoke.md)、[原生桌面验收](desktop-verification.md)和[发行流程](releasing.md)。[底座选型](architecture/base-selection.md)记录了系统与上游模块探针。
