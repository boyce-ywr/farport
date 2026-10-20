# 当前终端设备上的 Agent 会话查找与恢复：官方事实与首版适配建议

## 0. 研究口径与快照

- **核验日期与抓取窗口**：2026-10-20 17:01–17:12，Asia/Shanghai（UTC+08:00）。只描述本次实际取得的官方正文与源码，不保证其他版本、用户已安装版本或所有部署环境相同。
- **范围**：Claude Code、OpenAI Codex CLI、Pi coding agent 的会话发现、恢复、cwd、元数据、运行态及同设备执行边界。只提供事实和适配建议，不实现功能，不替代主线程 UX 决策。
- **Pi 身份**：调查原 `badlogic/pi-mono` 项目；其 GitHub API 在本次请求中指向 `earendil-works/pi`，固定源码中的包名为 `@earendil-works/pi-coding-agent`、命令为 `pi`。不是 Inflection Pi，也不泛指其他同名 Agent。[P0][V3]
- **资料获取**：已读取 research、openai-docs skill；先执行官方域名限定的 Codex 搜索并打开官方页面，`web.run` 未返回可核验正文，随后使用 `curl --proxy http://127.0.0.1:7897` 取得正文。未使用搜索摘要代替证据；来源表保留请求 URL、实际重定向及源码 SHA。
- **执行边界**：只读检查了适用 AGENTS 路径、Git 状态及少量 Farport 源码；目标路径没有额外 AGENTS，遵循本任务提供的规则。只新增本文；没有改 Docker 附件代码、主设计文档、配置或安装，没有运行 Agent、SDK 会话查询、app-server、SSH 或 Docker 命令，没有读取真实会话正文、真实凭据，没有提交。
- **版本口径**：GitHub `releases/latest` 分别返回 Codex `rust-v0.163.0`（2026-10-15T21:30:38Z）、Claude Code `v2.1.304`（2026-10-19T21:34:39Z）、Pi `v1.3.0`（2026-10-15T19:17:33Z）。这只是当时发行端点返回值；下文固定源码可能含发布后变更，**不能把 main 的每个字段都归属于这些发行包**。未检查用户安装版本。[V1][V2][V3]

## 1. 可直接交给主线程的结论

| 工具 | 官方结构化发现能力 | 是否适用于磁盘 CLI 历史 | 运行态能力 | 首版建议，不是已实现事实 |
| --- | --- | --- | --- | --- |
| Codex | app-server JSON-RPC `thread/list`、`thread/read`，支持分页、cwd、来源、归档过滤 | **是**；不是仅云端任务列表。使用目标设备正确的 Codex 数据目录，并显式选择 `cli` 等来源 | 同一个 app-server 的 `thread/loaded/list`、线程 `status`、状态通知 | 优先官方 API；不要先解析 SQLite/JSONL。没有可用服务或能力不匹配时打开 `codex resume`。[C1][C2] |
| Claude Code | SDK `list_sessions` / `get_session_info`，TS 对应 `listSessions` / `getSessionInfo`；CLI `claude agents --json` | **SDK 是**；`agents --json --all` **不是全部磁盘历史** | `agents --json` 包含前台/后台活跃会话，区分任务 state 和进程 status | 历史用 SDK，运行态用官方 JSON；不具备 SDK 时原生 `claude --resume` 兜底。[A1][A3][A4][A5] |
| Pi | SDK `SessionManager.list` / `listAll`；RPC `get_state`、`get_session_stats` | **SDK 是**；RPC 状态只针对受控进程当前会话，不是跨项目历史列表 | RPC `get_state` 有 `isStreaming`、`isCompacting`、`sessionId`、`sessionFile` | 首版优先原生 `pi --resume`；需要自绘列表时再评估 SDK 的正文读取、性能及 mkdir 副作用。[P2][P3][P5] |

**三个必须分开的“只读”**：① 不发模型请求、不恢复；② 不修改用户文件/工具状态；③ 不读取会话正文。三者不等价。官方名称叫“metadata”的接口也可能读取 transcript 片段；启动一个服务或 SDK helper 也不能仅凭接口名称宣称绝不写盘。下文逐项说明。

## 2. 命令矩阵：继续、选择、按 ID 与目录

以下均为**未执行的调用模板**；变量必须来自已确认的目标设备元数据，不能把名称、路径或 ID 直接拼接为 shell 代码。这里的 `$CWD` 是目标设备路径，不是 Farport 所在 Mac 的路径。

| 操作 | Claude Code | Codex CLI | Pi |
| --- | --- | --- | --- |
| 继续当前目录最近会话 | `claude --continue` / `claude -c` | `codex resume --last` | `pi --continue` / `pi -c` |
| 原生恢复 picker | `claude --resume` / `claude -r` | `codex resume` | `pi --resume` / `pi -r` |
| 按准确 ID 恢复 | `claude --resume "$SESSION_ID"` | `codex resume "$THREAD_ID"` | `pi --session "$SESSION_ID"`，**不是** `pi --resume ID` |
| 按已知 transcript 路径恢复 | `claude --resume "$ABS_JSONL_PATH"` | 本文未确认普通 CLI 的公开路径恢复入口；用 thread ID | `pi --session "$ABS_JSONL_PATH"` |
| 扩大原生查找范围 | picker 内扩大到其他 worktree/项目；ID 查找另有跨项目规则 | `codex resume --all`；`--last --all` 取跨目录最近会话 | picker 可使用跨项目列表；不能凭空添加 `--all` |
| 指定启动 cwd | 在进程启动参数中设 cwd，或 `(cd -- "$CWD" && claude --resume "$SESSION_ID")` | `codex resume "$THREAD_ID" --cd "$CWD"`，短参数 `-C` | 在进程启动参数中设 cwd，或 `(cd -- "$CWD" && pi --session "$SESSION_ID")`；**实际恢复 cwd 见下文** |
| 显式分叉而非原地恢复 | `claude --resume "$SESSION_ID" --fork-session` | `codex fork "$THREAD_ID"` | `pi --fork "$SESSION_ID"` 或文件路径 |

矩阵依据官方 CLI/会话文档及参数解析源码；不存在统一的三工具 `resume --id --cwd --json` 协议。[A1][A2][C1][C3][P1][P4][P6]

### 2.1 Claude 的选择范围及 cwd

- 交互式 `--continue` 不是“所有 transcript 中 mtime 最大者”：当前文档说明它跳过 `-p`、SDK 和首条提示为 `/loop` 的会话，包含将当前目录加入 `/add-dir` 的会话；`-p --continue` 的集合不同。不要用自行排序的全量历史模拟其选择。[A1]
- 当前文档中按 UUID 恢复会先查当前项目及其 worktree，再查本机其他项目；跨项目 ID 搜索从 v2.1.223 起提供。按名称、原生 picker 与 UUID 的搜索范围并不完全相同。建议保存 UUID，不把可重复或可修改的标题作为主键。[A1][A2]
- `claude agents --cwd PATH` 是 **agents 列表过滤参数**，不能据此推导普通 `claude --resume` 支持同名 cwd 参数。普通恢复以目标进程 cwd 启动；“找到了别的项目的 ID”也不能证明已校验正确工作树。[A1][A2]
- `--session-id` 用于指定会话 ID，**不要拿它替代 `--resume`**。`--add-dir` 是增加可访问目录，不是切换 cwd。[A1]

### 2.2 Codex 的 cwd 与 thread ID

- `--all` 取消 cwd 过滤；`--last` 默认仍限当前目录。当前源码另有 `--include-non-interactive`，用于将非交互会话纳入 picker/最近会话选择；它需要能力探测，不是所有旧安装都支持。[C1][C3]
- 启动目录与保存目录不同，当前官方文档说明 Codex 会询问使用哪个目录；配置 `tui.resume_cwd = "current"` 或 `"session"` 可影响选择，而显式 `--cd` 优先。首版按已核实的记录 cwd 传 `--cd`，不要依赖用户未知的默认配置。[C1]
- app-server 恢复使用 **`thread.id` → `threadId`**。当前 API 中 `thread.sessionId` 表示会话树根，fork 的 thread 可以共享它；不能拿根 sessionId 替代选中 thread 的 ID。[C2]
- `codex exec resume ...` 是非交互继续执行，`--json` 是执行事件输出，不是历史列表命令；`codex cloud list --json` 是云任务列表，也不能替代本地 CLI 历史。[C1]

### 2.3 Pi 的 cwd 是首版最容易误判的点

- 固定源码里，`--resume` 是无值 picker 开关，`--session` 才接受路径或 ID。ID 支持前缀，但源码前缀匹配使用首个匹配结果；适配器应使用完整 ID 或已核实的绝对文件路径，避免短前缀歧义。[P4][P6]
- `--session` 先找当前目录的精确 ID，再做列表/前缀匹配，随后查跨项目列表。**跨项目 ID 命中会询问是否 fork 到当前目录**，不是无条件原地 resume。使用已核实的文件路径直接打开，与跨项目 ID 路线并不等价。[P6]
- 加载已存在会话后，运行时使用 `sessionManager.getCwd()`，即保存的 cwd；启动前 `cd` 主要决定发现范围，**不保证覆盖会话 cwd**。保存目录不存在时，交互模式询问是否使用当前 cwd；非交互模式报错退出。[P6][P7]
- 未在本次完整参数帮助源码中确认普通 `pi --cwd`。SDK 能显式提供 cwd；不要把 SDK 参数写成 CLI 参数。`--session-id` 是“使用精确项目 ID，不存在时创建”，不能作为失败后自动新建的恢复兜底。[P4][P6][P8]

## 3. Codex：优先 app-server，而不是直接读取内部数据库

### 3.1 已确认的结构化接口

app-server 是官方面向富客户端的接口。先建立 transport，发送 `initialize`，再发送 `initialized`；这不是无需握手的一次性 stdout 列表命令。[C2]

下列 JSON 只是协议示意，未连接或启动用户服务：

```json
{"id":1,"method":"thread/list","params":{"limit":50,"sortKey":"updated_at","cwd":"/target/project","sourceKinds":["cli","vscode","exec","appServer"],"archived":false,"useStateDbOnly":true}}
{"id":2,"method":"thread/read","params":{"threadId":"<selected-thread-id>","includeTurns":false}}
{"id":3,"method":"thread/loaded/list"}
```

- `thread/list`：分页列出保存的线程；用响应 `nextCursor` 继续，直到为 null；不要只取第一页便声明“全设备全部会话”。不传 cwd 可扩大范围；`cwd` 是精确路径匹配，当前协议也接受路径数组，相对路径相对于 **app-server** cwd 解析。[C2]
- `sourceKinds` 缺省或空数组默认只含交互来源 `cli`、`vscode`，不是全部来源；需要 exec/其他来源时显式请求。`archived: true` 只列归档项，false/省略只列非归档项，需要分别取后再合并。[C2]
- `thread/read` 默认或 `includeTurns:false` 返回线程摘要，不加载完整 turns、不恢复线程、不订阅，也不发 `thread/started`。它适合选择后复核，不需要为了得到 cwd 先 resume。[C2]
- `thread/resume` 接受 `threadId`，当前协议支持 `excludeTurns:true`，只把返回体控制为元数据及运行态，不返回完整历史；它仍然是**加载/恢复动作**，不是查找 API。真正发起下一轮是独立的 `turn/start`。官方还说明 resume 本身不更新线程更新时间或 rollout mtime；这不等于全部运行时都不写盘。[C2]
- `thread/loaded/list` 只列该服务内存中的线程；`status` 有 `notLoaded`、`idle`、`systemError`、`active`，`activeFlags` 可表示等待批准等。**loaded 不等于正在生成，notLoaded 不等于整个设备无对应进程**。另开一个服务不能推断其他实例的运行态。[C2；范围推论]

### 3.2 能否“同设备只读”

- **可做不恢复的查询**：已存在且可访问的正确服务上，调用 list/read/loaded，而不是 resume/start/turn。不需要为列 CLI 历史调用云任务接口。[C2]
- **但默认 list 不保证无副作用**：官方明确说明 `useStateDbOnly:true` 跳过 JSONL 扫描修复；省略/false 会扫描并修复元数据。因此不能把默认 `thread/list` 当成严格无写入的文件查看器。[C2]
- **严格边界的建议**：如正确服务已经存在，能力探测后使用 `useStateDbOnly:true`、不请求 turns、不发送 turn；若数据库不完整，应显示“仅已索引历史”，不能擅自通过修复扫描补齐。启动 app-server 的配置加载、数据库初始化和其他后台活动不在该参数的“无写入”保证内，本轮未运行验证。
- 返回 `preview`、`name` 可能包含对话信息；`includeTurns:false` 不表示响应完全没有正文衍生字段。若未来要求不把文本离开目标设备，应在目标侧只输出白名单 ID/cwd/时间/source/status；若要求连底层正文片段也不得读取，则还需独立审核后端，不能只靠过滤输出。[C2]
- 依赖目标设备上兼容的 Codex app-server/CLI、正确数据目录与服务权限；不是 Farport 本地开一个服务就能自动看到 SSH/容器里同名用户的数据。现有 CLI `codex agents` 是共享服务器的交互式总览，当前参数源码没有 JSON 历史列表选项。[C1][C3]

### 3.3 磁盘事实与稳定性

- 默认配置根为 `~/.codex`，可由 `CODEX_HOME` 改写；目录中也有敏感认证和配置，不能全量读取/复制。[C4]
- 固定源码仍有 `sessions/YYYY/MM/DD/rollout-<timestamp>-<thread-id>.jsonl`，以及 `archived_sessions`；revert 等情况可产生额外 rollout ID，读取器也有压缩文件处理。**不要把一个线程等同于一个固定 `.jsonl` 文件名**。[C5][C6]
- `session_meta` 中可有 `id`、`session_id`、`timestamp`、`cwd`、`cli_version`、`source`、provider；同一对象也能包含 `base_instructions`、动态工具和账户标识。首行不能未经字段过滤就当成“无敏感内容的元数据”。[C7]
- `session_index.jsonl` 在固定源码中是追加式名称索引，字段是 `id`、`thread_name`、`updated_at`，最近记录覆盖旧名称；**没有 cwd，也不能充当完整会话目录**。[C8]
- 官方源码有 SQLite 元数据层及 `CODEX_SQLITE_HOME` 覆盖入口。本文不猜定所有版本的数据库文件名/表结构，也不建议首版绑定它；直接 SQLite 会把 schema、迁移、WAL、与正文存储的一致性变成 Farport 的责任。这是适配风险判断，不是官方对外 API。[C9]
- `history.jsonl`/history 配置不能直接替代可恢复线程清单；首版以官方 thread API 为依据。内部文件格式本轮未找到跨版本稳定承诺。[C2][C4][C5][C8]

## 4. Claude Code：SDK 历史与 CLI 运行态分开用

### 4.1 SDK 的列表和单条元数据

官方 Python 包 `claude_agent_sdk` 提供同步函数；TypeScript 包 `@anthropic-ai/claude-agent-sdk` 提供对应异步 API。[A4][A5]

```python
list_sessions(directory=None, limit=None, offset=0, include_worktrees=True)
get_session_info(session_id, directory=None)
```

```typescript
listSessions({ dir: "/target/project", limit: 50 })
getSessionInfo("<session-uuid>")
```

- `directory` / `dir` 是筛选项目目录；省略查各项目。Python 可用 limit/offset 分页，默认包括 git worktree；严格当前目录视图应显式设置 `include_worktrees=False`，而不是假设默认不扩展。[A4][A5]
- `get_session_info` 为选中的 UUID 查询元数据，未找到返回 None；不指定 directory 仍可能搜索多个项目目录，不能笼统承诺任何条件下都 O(1)。官方源码还会排除某些 sidechain 或无法提取摘要的记录，所以 None 不等于磁盘上绝对不存在同名文件。[A4][A6]
- `SDKSessionInfo` 包括 ID、可选 cwd、创建/修改时间、file size、git branch，以及 summary、custom title、first prompt、tag 等。cwd 允许缺失，缺失时应标“未知”，不能用编码目录名反解成确定 cwd。[A4][A5]
- **依赖/只读范围**：需要目标设备已有兼容 SDK 及对应 Python/Node 运行时，或后续经用户同意部署 helper；不用启动 `query()` 或发送模型请求。源码本地列表路径通过 stat、文件 head/tail 读取元数据，而不是启动交互会话。[A6]
- **隐私关键点**：当前 Python 源码每端读取最多 65,536 字节，可能包含会话正文，并抽取 first prompt/summary。它是只读文件的元数据 API，**不是严格“不读取正文”的 API**。在本任务禁止实际会话正文读取的约束下，本轮没有调用它；只把它列为后续功能候选。[A6]

### 4.2 官方 JSON 运行态：不要漏掉新版 CLI 能力

```sh
claude agents --json
claude agents --json --all
claude agents --json --all --cwd /target/project
```

- 官方定义的 active 列表包括每个 live 会话，以及仍 working/blocked 但进程已退出的后台任务。`--all` 增加已完成后台任务，**不等于枚举所有历史 transcript**。[A3]
- 固定字段包括 `cwd`、`kind`（interactive/background）、`startedAt`；后台任务的短 `id` 用于 `claude attach`，完整 `sessionId` 用于 `claude --resume`。进程活着时有 `pid`、`status`（busy/waiting/idle）；后台任务另有 `state`（working/blocked/done/failed/stopped），不要混用。[A3]
- 任务 done 仍可有活进程，working 也不保证此刻有活进程。运行态首选这些官方字段，而不是根据 transcript mtime 推断。`~/.claude/jobs/<id>/state.json` 官方明确不是稳定接口，应使用 JSON 命令。[A3]
- 该能力可能被配置禁用；旧版本的 `claude agents` 还可能输出“配置的 subagents 列表”，因此必须检查实际 JSON 结构和 capabilities，不能只看命令名。此处不自动更新、安装或开启后台服务。[A3]
- `agents --json` 是官方查询入口，但文档没有给出整个 CLI 启动过程零文件写入的保证；不要为满足“绝不写主机”的检查而直接运行它。本次只是资料核实。

### 4.3 恢复、运行中的后台任务及并发

- 对保存的会话用 `claude --resume UUID`；对后台短 ID 可用 `claude attach ID`。当前文档说明，自 v2.1.285 起，resume 命中仍运行的后台会话会转为 attach；附带 prompt 会发送给那条活会话，**不是只预填输入框**。[A1][A2][A3]
- 上述后台自动 attach 路径遇到重定向、`--permission-mode`/model/settings 等配置参数、输出格式参数等会拒绝并退出；不应该自动 stop 或 fork 来“修好”它。[A2]
- 普通历史恢复与附着到存活进程是两种动作。官方说明同一 transcript 在两个终端不分叉地恢复，会把两边消息交错写进一个 transcript。没有可靠运行态时应提示未知，不能自动制造第二个写者。[A2]
- 原地 resume 恢复历史，fork 只分叉历史，不自动隔离工作目录中的文件；适配层不能把 fork 宣传成文件系统安全副本。[A2]

### 4.4 元数据路径及稳定性

- 默认 transcript：`~/.claude/projects/<project>/<session-id>.jsonl`；`<project>` 来自工作目录路径编码，当前文档还描述超过 200 字符的截断/hash。`CLAUDE_CONFIG_DIR` 可移动根，`CLAUDE_CODE_PROJECT_DIR_NAME` 与它配合可指定项目目录名。[A2]
- JSONL 行格式官方明确属于内部格式、版本间可变；不要把非字母数字替换规则反向解码成真实路径。历史 SDK 的 cwd 才是其返回的事实字段，且允许未知。[A2][A4]
- 默认保留期 30 天，可由 `cleanupPeriodDays` 更改；禁用持久化、清理等也会让历史缺失。空列表只能说明当前数据根/过滤/索引下没有结果，不能声称这个设备从没运行过 Claude。[A2]
- `jobs` 状态、supervisor/socket/roster 与 transcript 是不同层；不要读取日志正文，也不要解析内部 jobs 文件替代官方运行态 JSON。[A3]

## 5. Pi：SDK 列表存在，但不是免费、纯元数据、零写入

### 5.1 列表及其真实 I/O

固定源码提供：

```typescript
SessionManager.list(cwd, sessionDir?, onProgress?, signal?)
SessionManager.listAll(sessionDir?, onProgress?, signal?)
```

- `list` 返回当前项目集合，`listAll` 返回跨项目集合；支持进度回调和取消信号。官方示例使用 `SessionManager.list(process.cwd())`，不需要创建 Agent 模型会话来调用列表。[P2][P3]
- 返回 `SessionInfo` 有 `path`、`id`、`cwd`、name、parent session path、created、modified、messageCount、**firstMessage、allMessagesText**。源码逐行流式读 transcript，收集消息文本，再生成这些字段，不能说它只读一个 header。[P3]
- **额外写入风险已由源码确认**：默认 `list(cwd)` 调用 `getDefaultSessionDir(cwd)`，目录不存在时执行 `mkdirSync(..., {recursive:true})`。因此不能在本轮“只准写研究文档”的约束下运行它；未来 strict read-only helper 也不能照抄这个调用并声称零写入。[P3]
- 本轮检查的 CLI 参数/命令参考没有独立 `pi list-sessions --json`，RPC 参考也没有全历史 list 方法；这是被检查版本的证据边界，不宣称所有扩展、未来版本都没有。[P4][P5]

### 5.2 RPC 是受控进程状态，不是任意终端发现器

- `pi --mode rpc` 提供进程 stdin/stdout JSON 协议。`{"type":"get_state"}` 返回当前会话 ID、文件、名称、messageCount、pendingMessageCount、isStreaming/isCompacting 等，不需要 `get_messages`。[P4][P5]
- `get_session_stats` 也提供当前 sessionId/sessionFile 等统计，但不是历史搜索。`switch_session` 使用 `sessionPath` 加载另一会话，还可能被 extension 的 session-before-switch 事件取消；它是状态改变，不是元数据查询。[P5]
- 没有证据表明任意已在 TTY 运行的 Pi 都暴露可附着的 RPC 服务。只有 Farport 已掌握某个 RPC 进程的通道，才能读取那条进程的状态；新开 RPC 进程不会附着到原终端中的 Pi。[P5；接口范围推论]
- 启动 Pi 会初始化运行时/资源；不能为“被动发现”偷偷启动 RPC Agent。受控进程内的 `get_state` 可作为后续集成的状态读取入口，本轮未做运行时无副作用验证。[P6]

### 5.3 存储、header 与 cwd 真实性

- 默认 `~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<session-id>.jsonl`。配置根由 `PI_CODING_AGENT_DIR` 决定，session 目录还可由 `--session-dir`、`PI_CODING_AGENT_SESSION_DIR`、sessionDir setting 覆盖；CLI 参数优先。[P1][P3][P9]
- 官方 session-format 定义首行为 session header，当前版本 3，含 `type`、`version`、`id`、`timestamp`、`cwd`，可有 parentSession；后续是树状 entries。名称可能在后续 `session_info` 中，因此**只读 header 的候选方案拿不到完整标题/最后活动时间**。[P10][P3]
- 旧格式在加载时会迁移；`--no-session` 是临时运行，退出后不能恢复。适配器不应为了查看元数据而调用会触发 load/migrate 的恢复接口，也不应把 `--no-session` 与 resume 拼起来当“无写入恢复”。[P1][P10][P6]
- **建议的严格隐私降级**：如后续真的要求不读取正文，可独立评估只读文件 stat 和有大小上限的第一行 header，以 ID/cwd/创建时间为候选；不读取其余 entries，不承诺标题、活跃状态或与官方列表完全一致。仍须按格式版本和自定义 session 根适配，属于建议而非现成官方列表接口。

## 6. 同设备、同用户、SSH 与容器执行边界

### 官方事实

- 三个工具都存在本地数据根或会话存储；“当前终端设备”必须包含存储所在环境和用户，而不只是 UI 标签上的 hostname。[A2][C4][P1]
- OpenSSH 可指定远端用户并运行远端命令；`-t` 强制 PTY，`-T` 禁用 PTY。交互 picker/Agent 和机器 JSON 管道应使用不同通道；无 PTY 通道不应混入 TUI 控制序列。[E2]
- Docker `exec` 在**运行中**容器里启动新命令，并不附着到现存 Agent 进程；支持 `--user`、`--workdir`、`--env`、`-i`、`-t`。默认 cwd/环境来自容器创建配置，不是当前交互 shell 的实时 `cd` 和 `export` 状态；容器重启也不会重启该 exec 命令。[E1]

### 首版适配建议

1. 用“执行设备/SSH 目标、Docker daemon/context 与容器完整 ID、目标 UID/GID、配置根、CLI 身份与版本”定义发现范围；cwd 是该范围内的过滤，不是设备身份的替代物。
2. 在目标环境执行查询和恢复：SSH 上用原用户；容器里用已确认的 UID/GID、容器内 cwd、可见数据根。不能在 Mac 扫 `~/.codex` 后标成远端结果，也不能假设宿主 `~/.claude` 等于容器用户的 HOME。
3. 只读取需要的环境元数据；不抓整个 `env`、命令行 prompt、日志或 auth 文件，不复制凭据。设置 `--user` 不构成 HOME/CLI PATH/自定义数据根已正确的证据，必须分别确认。
4. 不 sudo，不 `--privileged`，不自动挂载宿主 HOME，不为了发现安装 SDK/启动守护进程。依赖缺失明确降级；原生 picker 也必须由用户点击启动，不能作为后台只读探测。
5. 在确认恢复之前重新核对目标身份、目录存在与 ID。容器被替换、UID 改变、cwd 消失、会话不存在时停止；不自动回落到本机、不自动新建会话、不自动 fork/stop。

### 与当前 Farport 实现的有限衔接

只读快照基于 HEAD `db16a305d8ece320edf37461944cb0e8ceaca5d2` 加当时未提交 Docker 改动，不代表发布包能力：

- `TerminalSession.swift:339` 已有本地终端启动 cwd 参数；这是进程启动目录，不足以证明一直知道交互 shell 或 Agent 后续 cwd。[F1]
- `LocalDockerTerminal.swift:5` 记录 tmux target、前台 PID、进程开始时间、Docker invocation；`localDockerTerminal` 限本地 host、检查进程用户。`DockerAttachments.swift:81` 确认容器身份/运行状态并解析 UID/GID，`validate` 会复核 binding。[F2][F3]
- **建议仅借用身份复核思路**：发现前后绑定同一个目标，列表迟到不能覆盖已切换的终端。不能直接把附件上传/准备流程当只读发现流程，更不能声称这些本地 Docker 检查已覆盖 SSH 内再进入容器的完整路径。本文未修改这些文件，也未运行其逻辑。

## 7. 恢复参数的安全边界

这些是**未来用户确认恢复后的候选命令**，不是“保证零写入”或“本次已验证”的命令：

| 场景 | 建议 | 边界与依据 |
| --- | --- | --- |
| Claude 非运行中历史，普通人工审批 | `claude --resume "$SESSION_ID" --permission-mode default` | 当前 default/manual 是人工模式；不要继承未知 bypass/auto。已有配置规则仍影响批准行为；后台活会话的自动 attach 路径不接受此类覆盖参数。[A1][A2] |
| Codex 历史，保守工具权限 | `codex resume "$THREAD_ID" --cd "$CWD" --sandbox read-only --ask-for-approval on-request` | 控制模型命令的 sandbox/审批，不保证 Codex 自身不写会话或启动资源；运行中线程应走正确服务/附着路径，不能承诺此命令能收紧另一个活进程。[C1][C2] |
| Pi 保守查看式启动 | `pi --session "$ABS_JSONL_PATH" --no-tools --no-extensions --no-mcp --no-approve` | 当前源码支持这些参数；禁用工具和扩展发现并忽略项目本地资源，不是 OS sandbox，也不保证不写 transcript/配置。恢复会改变工作方式，需用户明确选择；默认动作不应悄悄加一套安全模式。[P4][P6] |

- 不自动附带 prompt，不用 `-p`、`exec resume` 或生成“总结历史”的模型请求冒充发现。Claude 当前 resume 还会恢复活跃 goal、未过期调度任务等状态，因此“没有 prompt”本身也不是纯被动或无后续动作保证。[A2]
- 禁用危险兜底：Claude `--dangerously-skip-permissions` / bypassPermissions，Codex `--dangerously-bypass-approvals-and-sandbox` / `--yolo`，以及 Docker `--privileged`；不自动扩大目录权限、重配认证、接受 workspace trust。[A1][C1][E1]
- 原生 picker、resume、fork、attach 都是用户操作入口，不是研究阶段只读验证手段。恢复本来就可能追加 transcript，安全要求应分别说明“工具权限”“设备身份”“原地历史写入”，不能只标一个“安全恢复”。

## 8. 建议的首版落地顺序与兜底

以下全部是**建议，未实现、未实机验收**：

1. **共用目标上下文与能力探测**：不扫描真实正文；明确目标用户、配置根和 cwd 可信度。能力版本不匹配返回“不支持/未知”，不把解析失败当空列表。
2. **Codex 第一优先**：正确服务已存在且支持时，官方 `thread/list` + `thread/read` 提供历史，`thread/loaded/list/status` 提供服务范围内运行态；严格不扫描正文时请求 `useStateDbOnly:true` 并披露索引完整性限制。依赖不满足则在目标 cwd 打开 `codex resume`，不先写一个 SQLite parser。
3. **Claude 双数据源**：有兼容 SDK 且未来产品允许目标侧读取 transcript 片段时，用 `list_sessions/get_session_info`；用 `agents --json` 补充运行态。若只允许严格元数据字节读取，不调用历史 SDK，先保留官方运行态或原生 `claude --resume` 入口。
4. **Pi 首版可先 picker**：`pi --resume` 和已知完整 ID/路径恢复足够形成用户可操作入口。自绘列表再选择“用户允许全文扫描的官方 SDK”或“严格 header-only 候选”，不要把 `SessionManager.list` 当成零成本只读。RPC 状态仅用于已受控的 RPC 进程。
5. **统一列表但不抹平语义**：至少保留工具、准确 ID、目标身份、cwd 与来源、创建/更新/文件 mtime 的各自含义、历史/运行态来源。显示“运行中”“已加载但空闲”“历史记录”“运行态未知”；没有 runtime 证据不得由时间戳造出在线状态。
6. **按 ID 恢复前复核**：cwd 与目标 UID/容器身份没变、工具/配置根可用、会话存在；活进程优先官方 attach/已有终端，不默认创建第二写者。名字只是展示字段，失败后不得默默改成继续最近或新建。

### 首版必须保留的未定项

- 用户设备、SSH、容器内实际 CLI/SDK 版本、安装方式、PATH、配置覆盖与后台服务归属均未检查；不需要为本轮事实表检查它们。
- 本轮没有对任一客户端建立真实服务连接，没有验证当前 Farport 端到端恢复、超大历史性能、所有 cwd 变更/软链接/清理场景，亦没有执行安全参数组合。
- 官方结构化字段和固定源码足以支持首版策略，但不能据此保证启动查询 helper 的整个生命周期无写入；严格零写入环境优先不启动新 runtime，明确降级。
- Codex 直接 SQLite schema/文件名、所有压缩/归档形态不作为首版契约；Claude 内部 transcript/jobs 格式不作为契约；Pi 旧版本和已转移项目前发行包需日后按实际能力验证。
- 证据足够交付，不阻塞主线程整合。无需等待更多竞品研究，也无需先要求用户回答 UX 问卷。

## 9. 官方来源与复核入口

以下在线来源均在第 0 节抓取窗口实际读取。源码行号以固定 SHA 为准；标 main/master 的补充来源是当日快照而非固定版本。链接包含精确请求 URL，不使用无正文的 web 引用编号。

### Codex / OpenAI

- [C1] [官方 CLI reference 请求地址](https://developers.openai.com/codex/cli/reference.md)，实际 HTTP 200 终点为 [Developer commands / CLI](https://learn.chatgpt.com/docs/developer-commands.md?surface=cli)。使用 global flags、codex resume/fork/agents/exec/cloud list 章节；Markdown 的动态参数表另以 HTML 正文与 C3 校验。
- [C2] [官方 app-server 请求地址](https://developers.openai.com/codex/app-server.md)，实际 HTTP 200 终点为 [Codex App Server](https://learn.chatgpt.com/docs/app-server.md)。使用 Initialization、API overview、Start or resume、Read/List threads、List loaded threads、Track thread status 章节。
- [C3] [CLI main.rs，固定 SHA](https://github.com/openai/codex/blob/e18a20d6eb6f5ede32a69fb56e3fe276d5e9d914/codex-rs/cli/src/main.rs)，`AgentsCommand`、`ResumeCommand`、resume 参数合并；[TUI cli.rs](https://github.com/openai/codex/blob/e18a20d6eb6f5ede32a69fb56e3fe276d5e9d914/codex-rs/tui/src/cli.rs)。SHA 的 committer 时间为 2026-10-20T07:56:07Z。
- [C4] [官方高级配置](https://developers.openai.com/codex/config-advanced.md)，CODEX_HOME 与本地数据、history 设置。
- [C5] [rollout lib.rs](https://github.com/openai/codex/blob/e18a20d6eb6f5ede32a69fb56e3fe276d5e9d914/codex-rs/rollout/src/lib.rs)，sessions/archived_sessions 常量与读取器。
- [C6] [rollout recorder.rs](https://github.com/openai/codex/blob/e18a20d6eb6f5ede32a69fb56e3fe276d5e9d914/codex-rs/rollout/src/recorder.rs)，路径日期布局、SessionMeta 构建、revert 文件 ID、压缩 materialize。
- [C7] [协议 SessionMeta](https://github.com/openai/codex/blob/e18a20d6eb6f5ede32a69fb56e3fe276d5e9d914/codex-rs/protocol/src/protocol.rs)。
- [C8] [session_index.rs](https://github.com/openai/codex/blob/e18a20d6eb6f5ede32a69fb56e3fe276d5e9d914/codex-rs/rollout/src/session_index.rs)，名称索引字段与追加行为。
- [C9] [state lib.rs](https://github.com/openai/codex/blob/e18a20d6eb6f5ede32a69fb56e3fe276d5e9d914/codex-rs/state/src/lib.rs)，SQLite 元数据层与 CODEX_SQLITE_HOME。

### Claude Code / Anthropic

- [A1] [官方 CLI reference](https://code.claude.com/docs/en/cli-reference.md)，continue/resume/fork/session-id、agents/attach、权限参数。
- [A2] [官方 Manage sessions](https://code.claude.com/docs/en/sessions.md)，恢复范围、后台 attach、恢复的状态、并发写入、transcript 格式和存储配置。
- [A3] [官方 Agent view](https://code.claude.com/docs/en/agent-view.md)，List sessions as JSON、Read session state from a script、supervisor、版本与不可用边界。
- [A4] [官方 Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python.md)，list_sessions、get_session_info、SDKSessionInfo。
- [A5] [官方 TypeScript SDK reference](https://code.claude.com/docs/en/agent-sdk/typescript.md)，listSessions、getSessionInfo、SDKSessionInfo；[官方 SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions.md) 明确提供历史枚举与单条元数据接口。
- [A6] [官方 Python SDK 本地 sessions 实现，main 快照](https://raw.githubusercontent.com/anthropics/claude-agent-sdk-python/main/src/claude_agent_sdk/_internal/sessions.py)，LITE_READ_BUF_SIZE、_read_session_lite、list_sessions、get_session_info。未确认用户 SDK 版本，不把 main 实现归属到其安装包。

### Pi / earendil-works

本组固定 SHA 为 `1d01b3b1f8de2e67a3a1c1694b14c984e4edd156`，committer 时间 2026-10-20T08:41:53Z；包 version 字段为 1.3.0，但不是断言该 SHA 等于 v1.3.0 tag。

- [P0] [package.json](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/package.json)，包名与 pi 命令。
- [P1] [Sessions](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/docs/sessions.md)，continue/picker、存储覆盖、临时会话。
- [P2] [SDK sessions example](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/examples/sdk/11-sessions.ts)。
- [P3] [session-manager.ts](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/src/core/session-manager.ts)，SessionHeader、SessionInfo、getDefaultSessionDir、buildSessionInfo、list/listAll。
- [P4] [CLI args.ts](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/src/cli/args.ts)，参数解析与完整帮助。
- [P5] [RPC](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/docs/rpc.md) 及 [RPC Commands](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/docs/rpc-commands.md)，get_state、get_session_stats、switch_session。
- [P6] [main.ts](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/src/main.ts)，resolveSessionPath、createSessionManager、跨项目 fork 提示、恢复 cwd 与运行时初始化。
- [P7] [session-cwd.ts](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/src/core/session-cwd.ts)，保存目录缺失检测。
- [P8] [SDK](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/docs/sdk.md)，cwd 的 SDK 语义与 runtime 切换。
- [P9] [config.ts](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/src/config.ts)，PI_CODING_AGENT_DIR、PI_CODING_AGENT_SESSION_DIR。
- [P10] [Session Format](https://github.com/earendil-works/pi/blob/1d01b3b1f8de2e67a3a1c1694b14c984e4edd156/packages/coding-agent/docs/session-format.md)，header、路径、版本与迁移。

### 执行环境、版本与本地依据

- [E1] [Docker CLI 官方 exec 文档源码，master 快照](https://raw.githubusercontent.com/docker/cli/master/docs/reference/commandline/container_exec.md)。
- [E2] [OpenSSH 官方 ssh.1，master 快照](https://raw.githubusercontent.com/openssh/openssh-portable/master/ssh.1)。
- [V1] [Codex releases/latest API](https://api.github.com/repos/openai/codex/releases/latest)，[对应 release](https://github.com/openai/codex/releases/tag/rust-v0.163.0)；[当日 commit 查询](https://api.github.com/repos/openai/codex/commits?per_page=1)。
- [V2] [Claude Code releases/latest API](https://api.github.com/repos/anthropics/claude-code/releases/latest)，[对应 release](https://github.com/anthropics/claude-code/releases/tag/v2.1.304)。
- [V3] [旧 Pi 仓库 releases/latest API](https://api.github.com/repos/badlogic/pi-mono/releases/latest)，返回 [earendil-works/pi v1.3.0](https://github.com/earendil-works/pi/releases/tag/v1.3.0)；[旧路径 commit API](https://api.github.com/repos/badlogic/pi-mono/commits?per_page=1) 返回新仓库固定 SHA。仓库 API 请求 `https://api.github.com/repos/badlogic/pi-mono` 最终为 `https://api.github.com/repositories/1035029907`。
- [F1] 本地只读 `Sources/WorkbenchApp/TerminalSession.swift:339`，启动进程 currentDirectory。
- [F2] 本地只读 `Sources/OpenSSHBackend/LocalDockerTerminal.swift:5`，目标/PID/启动时间；`Sources/OpenSSHBackend/LocalDockerTerminal.swift:16`，同用户进程验证。
- [F3] 本地只读 `Sources/OpenSSHBackend/DockerAttachments.swift:81`，容器和 UID/GID 确认；`Sources/OpenSSHBackend/DockerAttachments.swift:100`，binding 复核。F1–F3 含未提交代码，仅为快照事实，不作为既有发行功能承诺。
