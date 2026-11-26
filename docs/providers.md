# 本机 CLI 连接与兼容性

2026-11-26 在 Apple Silicon Mac 核对了以下安装。Agent Hub 的安装包使用用户另外安装的官方 CLI。设置里的“重新检测”检查版本、协议参数、认证线索与模型目录。用户确认“测试连接”后，Hub 才在独立临时目录发送固定短请求，要求返回 `HUB_OK`，30 秒超时。DSH 按用户 API 账户计费。

| 工具 | 本机版本 | 接入方式 | 认证和模型 |
| --- | --- | --- | --- |
| Codex | `codex-cli 0.170.0` | `exec --json`，stdin 为任务原文 | `login status` 报告 ChatGPT 登录。设置从官方 CLI 本机模型缓存读取可见模型，缓存可能过期或为空 |
| Antigravity | 初检 `1.5.16`，复核 `1.5.18` | stdin 和 stdout 均使用 stream-json，每个进程提交一轮 | `agy models` 返回 tab 分隔的模型标识和显示名。本机观察到 27 条。套餐、余额、单个模型的实时可用性仍需订阅服务确认 |
| DeepSeek Harness | `@deepseek-ai/dsh 0.2.0-rc.2` | `--profile headless --json -`，stdin 为任务原文 | Hub 钥匙串中的 API key。此发行版内置目录提供 `deepseek-flash`、`deepseek-v4-pro`。选择通过独立官方 profile overlay 生效 |

## 安装与连接

1. **Codex**。按照官方 macOS 安装说明安装 Codex CLI，在终端执行 `codex --version` 和 `codex login`，选择 ChatGPT 登录，再回到设置重新检测。Hub 通过官方登录存储复用账号，指定 OpenAI provider 和 ChatGPT 登录方式。检测到 API key 路由时会提示切换。执行时忽略用户自定义 Codex 配置以明确 provider 与沙箱边界。[官方 CLI](https://developers.openai.com/codex/cli/) · [非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode)
2. **Antigravity**。在官方快速入门中选择 Antigravity CLI，安装后运行 `agy --version`。首次在终端运行 `agy`，选择个人 Google 账号并完成官方浏览器登录，再点击重新检测。Hub 以清理过的环境启动 CLI，检测和启动时检查 CLI 设置里的 Gemini API 或显式其他计费配置。账号现有的服务端计费和 AI credits 规则仍由 Google 管理。[安装](https://antigravity.google/docs/getting-started) · [认证方式](https://antigravity.google/docs/install) · [Headless](https://antigravity.google/docs/cli/headless)
3. **DSH**。先安装 Node.js 与 npm，然后用 `npm install -g @deepseek-ai/dsh@0.2.0-rc.2` 安装受测发行版，运行 `dsh --version` 确认。在连接设置输入自己的 DeepSeek API key 并保存。Hub 的“删除 key”只删除本应用的钥匙串条目，“测试连接”可验证账号能否实际请求模型。[官方仓库](https://github.com/deepseek-ai/deepseek-harness) · [CLI](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/README.md) · [上游 headless 协议](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/headless/README.md)

Finder 启动时，Hub 查询 Homebrew、用户 bin、常用 Node 版本管理器目录、受控 PATH 和已知 Codex app bundle。手选路径必须是可执行文件。手选文件失效时将提示重新选择。整个查找过程无需启动 login shell。默认保存的模型值为空时由所选官方工具使用其默认模型。

## 事件、会话与权限

| 行为 | Codex | Antigravity | DSH rc.2 |
| --- | --- | --- | --- |
| 启动边界 | 官方 read-only 或 workspace-write 沙箱，权限策略 never | 终端沙箱，计划阶段 plan 并禁写和 shell，执行阶段 accept-edits 与 proceed-in-sandbox；实际能力取决于宿主 | 官方 sandbox-policy，按任务选 read-only 或 workspace-write，保留受管范围和默认审批行为 |
| 成功判定 | `turn.completed`，退出 0 | `result.status=SUCCESS`，退出 0，同时监控 soft denial | `status/turn_end.reason.kind=completed`、`final`、退出 0 |
| 文本 | 同一 item id 的 agent message 是完整快照 | `step_update.text_delta` 是增量，包括 DONE 上的最后一段。终止 response 是完整回答 | text 为已提交的消息块，final.text 为最终回答。thinking 不作为公开消息 |
| 用量 | `turn.completed.usage` 的输入与输出 token | 取 result.usage。续接时是整个会话的累计量，不能逐次相加 | 对 step_end 的同一 turn/step 取一次。缺失步骤数据时保留未知 |
| 显式恢复 | `exec resume <UUID>` | `--conversation <UUID>` | `--session-id session-<UUID>`，相同工作目录、模型与权限 profile |
| 取消和再启动 | 由 HubProcess 终止并等待受管进程组 | 同左 | 同左 |

适配器提供按精确 ID 续接的参数构造。跨 provider 的尝试使用工作区与交接包。每次请求使用 stdin 并在送入后一并关闭。当前适配不提供实时审批桥、原生暂停或向正在生成的单轮注入指令。三家协议都不能在此实现中为任务提供可靠的金额硬上限或订阅余额。限额、认证、网络、权限、协议和中断分别映射为独立错误原因。

Antigravity 的 `--sandbox` 约束终端，`--mode plan` 选择官方计划模式。只读轮还显式禁用文件写入、命令和外部 MCP。执行轮允许受管工作目录内编辑，终端命令只在官方沙箱内自动运行。Hub 为单次进程提供工作区与权限覆盖，保留用户的 ask 和 deny 规则。工具返回 DONE 或顶层进程退出 0 仍可能出现权限拒绝；Hub 同时检查步骤详情与 stderr。具体被拒时应调整对应的工作区权限或交回用户处理。[官方权限说明](https://antigravity.google/docs/cli/headless#permissions-in-headless-mode)

解码器为 stdout 和 stderr 分别进行有界字节分帧。默认单个 JSON 记录上限为 1 MiB，支持 UTF-8 跨块、无末尾换行、ANSI、额外字段和未知非关键事件。无效 JSON、非 UTF-8 或超大协议行会使本轮失败。文本事件携带 item 标识和最新快照。已识别的输出仅保留规范化业务字段和原始类型，工具返回的完整参数、模型思考过程以及原始 JSONL 没有持久化。实际任务还需要满足独立验收。

## DSH 凭据与版本差异

Hub 将 key 保存在通用密码钥匙串条目，类型为仅本机、解锁时可访问。在 DSH 的单次进程环境中注入 `DEEPSEEK_API_KEY`。受管 `DSH_HOME` 按权限和模型分开，以免继承用户已有 Web 或 ACP 配置。受管 profile 使用官方 DeepSeek Messages 终点并禁用 DSH 的旧版凭据服务、账号桥及会话遥测导出。CLI 进程在请求期间可以读取 key。Hub 管理的普通工具和官方 DSH 沙箱 Bash 子进程各自过滤环境。

本机发行版和上游 master 有明确差异。rc.2 的 help 没有 `--permission-mode` 和 `--model`，它的终止 reason 在 turn_end 中。master 已经实现额外的权限参数、最终 reason 字段，并调整了默认凭据服务。Hub 将 DSH 兼容范围限定为上述发行版。升级后应重跑 headless 协议、启动和子进程凭据测试，再调整兼容版本。[上游 headless 文档](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/headless/README.md)

## 复验

`swift test --filter ProviderTests` 运行三家事件 fixture、错误分类、快照去重、拆包、中文路径、stdin 安全传递、环境净化、手选 CLI 等测试。测试产物使用独立目录。额外的本机检查遵循官方安装位置，使用合成哨兵。

```sh
AGENTHUB_PROBE_AGY=1 AGENTHUB_PROBE_DSH=1 swift test --filter ProviderTests
```

在受测机器上，这组检查的 11 个测试全部通过。实装 agy 1.5.18 在最终只读、可写两套权限配置下均进入协议解析，拒绝不支持的 control_request，退出码均为 2。该检查没有提交用户轮次。随后在最终 accept-edits 和上述权限设置下，Antigravity 1.5.18 通过一次真实订阅任务，单个尝试仅修改示例的 status.txt。基线检查退出 1，集成后退出 0，重开数据库保留完成状态。CLI 报告输入 20,257、输出 2,361 token。无推理检查成功挂载 DSH 的受管配置，未知 session 被准确拒绝。Hub 启动的普通 shell 中 key 存在为 false。另一次检查通过真实 DSH 的 Cordis、sandbox-policy、sandbox-local、subprocess-local、bash-sandbox 模块运行 read-only Bash，子进程中 key 存在也为 false。此检查覆盖受测发行版的 Bash 路径；第三方自定义插件具备自己的进程权限。真实模型请求与验收命令详见[工作流冒烟报告](smoke.md)。

## 真机续接与启动阶段取消

2026-11-26，使用正式适配器和 HubProcess 在两次已完成的临时示例上各执行了一次原生续接。会话 ID、原工作目录及原本改过的文件来自对应任务的 SQLite 记录。续接请求只问“上一轮被分配修改哪个文件”，未提供文件名，并要求不使用工具、不改文件。

| CLI 与原始合成任务 | 传入并返回的完整会话 ID | 结果 |
| --- | --- | --- |
| Codex 0.170.0，双订阅示例的后端角色，任务 `CCD0267C-388B-45DE-8661-378E6C8E5EFA` | `01a21875-efdb-75f0-9881-22491ee40e5a` | 在原 worktree 用 read-only 续接，准确回答 `backend.txt`。0 次工具事件，CLI 成功终止，退出 0。用量事件报输入 63,018、输出 168 token |
| Antigravity 1.5.18，最终权限版单文件示例，任务 `0CD0FA0E-ACA8-4AD5-B325-1054A55B5B7C` | `169cfc9e-6dc1-4528-a2bf-a2d38d2a9544` | 在原 worktree 用 plan 和只读权限规则续接，准确回答 `status.txt`。0 次工具事件，CLI 成功终止，退出 0。会话累计输入 36,071、输出 2,506 token |

对上述相同两组参数，各运行一次正式进程监督取消检查。监督器创建受管进程，核对 PID、启动时间及可执行程序身份后，在释放挂起进程之前收到取消。Codex 进程 PID 为 60967，Antigravity 为 61015。两者的取消标志均为 true，退出后身份检查均为 gone；对各自进程组的存活检查均返回 ESRCH。stdout 与 stderr 均为 0 字节。这两次检查覆盖真实 CLI 的启动阶段取消，未发送 prompt，也未启动模型轮次。运行中含子进程的取消另有进程监督 fixture 覆盖。最后再核对两处 worktree，HEAD 各为 `ac971073396d8f527c9b09bbbacb1470a167a912` 和 `2b2585581c92fc5642197ef65c87ab16392375ff`，前后相同且工作区干净。

正式任务从暂停或中断恢复时，引擎按检查点、工作区和交接记录建立新 Attempt 和新会话。原生续接是适配器在指定原会话与原工作目录时提供的单独能力。DSH 的未知会话拒绝已在真实 CLI 验证，本机缺少 Hub 专用 key，因此没有执行带模型轮次的原生续接。
