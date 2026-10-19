# SSH 社区痛点证据：Tabby 原始 issue 与 iTerm2 做法边界

核验日期：2026-10-19（北京时间）；下列 issue 创建、关闭及评论日期采用 GitHub 返回的 UTC 日期。

## 口径

- 只采用 Tabby 官方 GitHub issue、关联事件和官方文档，以及 iTerm2 官方文档；不重复竞品功能列表，不采集私人信息或原始日志。本机海外请求均经指定 HTTP 代理。
- 以下是 **5 组具体痛点证据，不是“全市场高频榜”**。优先选择重复反馈、后续补充或维护者明确回应；未用票数、评论数、搜索命中数推算用户量，也未使用 Termius 路线图计数。
- 状态为核验时 GitHub API 的 `state`；关闭不自动等于已发布修复，开放也不证明最新版仍可复现。官方文档只用于解释解决方式和限制，不作为需求频率证据；本次未运行竞品复现。

## 1. 断线后需要保留上下文，而“重连”容易被误解为恢复原会话

- **来源 / 日期 / 状态**：[Tabby #761](https://github.com/Eugeny/tabby/issues/761)，创建于 2019-04-11；`closed`，2020-07-05 关闭。
- **用户痛点**：最初请求在原标签重连，避免关闭标签、另建连接时丢失之前的屏幕日志。后续既有人找不到入口，也有人于 [2024-03-19](https://github.com/Eugeny/tabby/issues/761#issuecomment-2007286226) 追问为何重连后是新 SSH 会话、旧会话没有回来。
- **维护者回应**：[2020-06-11](https://github.com/Eugeny/tabby/issues/761#issuecomment-642925891) 明确表示已增加断线后的重连按钮。这是历史解决方案，不是对“远端进程恢复”的承诺。
- **iTerm2 边界对照**：[Session Restoration](https://iterm2.com/documentation-restoration.html) 说明依靠继续存活的进程服务器，在应用崩溃或升级后重新接管；机器重启不能恢复任务，默认正常退出也会终止任务。文档首次发布日期无法确认；核验时页面可访问。它解决的主要是应用恢复，不能用来证明 SSH 断网后原远端进程一定保活。
- **归纳 / 限制**：同一讨论中存在跨年份补充，支持“日志保留、重连入口、原会话保活必须分开表达”的产品假设；不是独立用户数统计，也不能据此宣称 Tabby 当前重连损坏。

## 2. 命令重用的痛点是快捷入口与职责割裂，不只是“有没有片段”

- **来源 / 日期 / 状态**：[Tabby #7963](https://github.com/Eugeny/tabby/issues/7963)，2023-02-20 创建，`open`；[Tabby #5167](https://github.com/Eugeny/tabby/issues/5167)，2021-12-15 创建并关闭，`closed`。
- **用户痛点**：#7963 请求保存、执行片段；[2025-11-04 的补充](https://github.com/Eugeny/tabby/issues/7963#issuecomment-3484176186) 指出替代插件缺少快速选择片段的快捷键。#5167 则明确要一个快捷键唤起命令历史面板，而非只在 shell 内补全。
- **维护者回应**：对片段，[2023-02-20](https://github.com/Eugeny/tabby/issues/7963#issuecomment-1437052857) 表示当时无内置功能，建议尝试 `quick-cmds`；对历史，[2021-12-15](https://github.com/Eugeny/tabby/issues/5167#issuecomment-994433845) 将历史补全归于所运行的 shell。插件建议不等于原需求完整解决，也不能把当时的“无内置”写成已验证的现状。
- **iTerm2 做法对照**：[Shell Integration / Command history](https://iterm2.com/documentation-shell-integration.html) 通过每台主机上的 shell 集成采集历史，按用户名与主机组合区分，并提供搜索入口；跨次启动保留还取决于落盘设置。首次发布日期无法确认；核验时页面可访问。这说明整合历史有环境配置和持久化前提，并非证明该功能使用量高。
- **归纳 / 限制**：值得验证的是“少切换工具、快速找到合适命令”。片段与历史是不同需求，不应合并成同一缺陷的重复报告；证据强度为具体请求及后续补充。

## 3. SFTP 本地编辑回传不能只验证内容，权限变化会破坏文件可执行性

- **来源 / 日期 / 状态**：[Tabby #7522](https://github.com/Eugeny/tabby/issues/7522)，2022-11-20 创建；[Tabby #7577](https://github.com/Eugeny/tabby/issues/7577)，2022-11-30 创建；均为 `closed`，2022-12-03 关闭。
- **用户痛点**：#7522 报告可执行文件经本地编辑、保存后失去执行位；#7577 给出 1.0.186 / 1.0.187 的复现步骤，原 `755` 权限变成 `644`，并关联前一 issue。不是单纯请求新增编辑功能。
- **官方处置证据**：两条官方 issue 的关闭事件均关联同一个提交 `78b17d3980f6b7381f6f683b9e2d7b4edca556d4`（[事件 #7522](https://api.github.com/repos/Eugeny/tabby/issues/7522/events)、[事件 #7577](https://api.github.com/repos/Eugeny/tabby/issues/7577/events)）。这是提交关联的历史关闭记录；本次没有核验进入哪个发行版。
- **归纳 / 限制**：两个相关 issue 支持“编辑—回传—权限保持”应作为完整验收链路。它们很可能属于同一缺陷，不能相加成两类需求；历史问题已经关闭，不能包装成当前未修复漏洞或高发故障率。

## 4. SFTP 打开当前目录的预期，与远端 shell 配置前提存在落差

- **来源 / 日期 / 状态**：[Tabby #5229](https://github.com/Eugeny/tabby/issues/5229)，2021-12-20 创建并关闭；[Tabby #7369](https://github.com/Eugeny/tabby/issues/7369)，2022-10-26 创建并关闭；均为 `closed`。
- **用户痛点**：#5229 希望 SFTP 直接进入当前 SSH 目录，方便上传，并质疑为何每台远端都需要配置；#7369 再次报告 SFTP 打开的不是当前目录。
- **维护者回应 / 官方做法**：两次均指向 [Shell working directory reporting](https://github.com/Eugeny/tabby/wiki/Shell-working-directory-reporting)。指南解释远端 shell、WSL、tmux / Screen 的目录不能由宿主终端可靠推断，需要 shell 上报；配置应加在**远端**，然后重启 shell 或重新登录。指南首次发布日期无法确认；核验时页面可访问。
- **归纳 / 限制**：跨 issue 重复反馈支持“配置位置、前提提示与失败诊断”值得优先验证。官方表述是让 SFTP **打开时进入当前目录**，不能扩写成已验证的持续双向跟随；关闭也不代表无配置即用。

## 5. 多终端广播不仅要能开启，还要让退出方式与特殊按键行为可预期

- **来源 / 日期 / 状态**：[Tabby #3919](https://github.com/Eugeny/tabby/issues/3919)，2021-05-28 创建并关闭，`closed`；[Tabby #7957](https://github.com/Eugeny/tabby/issues/7957)，2023-02-17 创建，`open`。
- **用户痛点**：#3919 找不到向多个分屏广播命令的入口；#7957 报告普通键入可广播，但 Ctrl 组合键或粘贴不工作，后续补充右键粘贴、Home / End 的问题。[2024-12-10 的补充](https://github.com/Eugeny/tabby/issues/7957#issuecomment-2530758687) 明确说这种差异造成编辑混乱与错误。
- **维护者回应**：对 #3919，[2021-05-28](https://github.com/Eugeny/tabby/issues/3919#issuecomment-850274553) 指向 `focus all panes`，并在[后续回应](https://github.com/Eugeny/tabby/issues/3919#issuecomment-850563254)表示已调整点击同一分屏也可退出广播。#7957 中的后续第三方插件自述不作为官方修复结论。
- **归纳 / 限制**：重复补充支持验证“广播状态、目标范围、退出动作、控制键与粘贴一致性”。这些是终端输入广播证据，不是批量任务编排或执行结果汇总证据；开放状态不能替代最新版复现。

## 对 Farport 的可验证假设（不是需求规模结论）

优先验证三条闭环：断线前后日志与进程状态是否说清楚；编辑回传后权限及目标目录是否正确；广播时目标和特殊输入是否一致。命令片段 / 历史另测快捷入口与主机上下文。以上优先级是基于本次证据的研究判断，仍需要 Farport 自身访谈或测试支持，不能据此推出市场占比或投入回报。
