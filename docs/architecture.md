# 模块与平台边界

## 当前结构

0.1.8 的 `HostMonitorService` 通过现有 SSH 通道 stdin 发送只读系统脚本，`MonitorSnapshot` 解析标准化行并计算差分，`HostMonitorModel` 负责页面生命周期、取消和有限内存曲线；采集脚本不写远端文件。平台差异留在采集器，UI 明确显示权限/能力限制。终端菜单的鼠标转发和附件插入策略是独立偏好，不改变 Shell 输入协议或全局 tmux 配置。

```text
WorkbenchApp（SwiftUI / AppKit）
  ├─ TerminalSession → SwiftTerm / PTY → 系统 OpenSSH 或本机登录 Shell
  ├─ AppStore → 主机配置、传输队列、外观、临时隧道
  ├─ FileModel / TmuxModel → OpenSSHBackend
  └─ 独立 workbench-askpass → 原生认证提示 / Keychain

OpenSSHBackend
  ├─ SSHTransport → 参数构建、私有控制套接字、认证环境
  ├─ ProcessRunner → 有界输出、超时、取消
  ├─ SFTPClient → ssh -s sftp / SFTP v3 二进制协议
  ├─ TmuxService → 正确引用参数的远端 tmux 命令
  └─ TransferEngine → 源/目标端点、清单、断点校验、发布

WorkbenchCore（Foundation）
  ├─ 主机、文件、tmux、传输领域模型
  ├─ SFTP 数据包编解码与边界校验
  └─ 路径、引用、取消标记
```

Haven 仅作为需求参考；未引入 Android Context、Service、Compose 或 Haven 源码。

0.1.1 的文件工作区统一使用 `FileClient` 浏览接口，`LocalFileClient` 与 `SFTPClient` 分别提供本机/远端实现。`TransferBatch` 负责顶层多选条目的安全预检并生成队列任务。`TerminalLayout` 分开管理左右窗格和焦点，避免标签点击拆掉分屏。

0.1.2 的本机终端不保存伪 SSH 主机：`TerminalSession.host == nil` 明确表示本机进程。现有 macOS 适配模块中的 `LocalShellConfiguration` 从系统账户读取 Shell，检查可执行文件和主目录，设置登录进程名与终端环境。相同 `TerminalSurface` 处理本机/远端的渲染与输入，`TerminalLayout` 的窗格/焦点逻辑不按连接类型分叉。SSH 认证提示和应用内部测试变量不会传递给本机 Shell，用户的 PATH、locale、SSH Agent 等正常环境仍保留。

0.1.3：`FileBrowserSource` 将文件来源与终端布局分离，Workspace 缓存每个来源的 `FileModel`，`SessionTabs` 同时显示在终端与文件页。`AttachmentUploader` 只负责源→目标复制和实际回读；`TerminalAttachmentDraft` 管理图片暂存、目标确认、身份快照和插入许可。`AttachmentDeliveryIdentity` 把连接、会话、窗口焦点、输入世代纳入比较。tmux 复用同一服务，但本机调用已有二进制，远端走 OpenSSH；定向粘贴使用一次性 tmux buffer，不修改全局配置。

## 关键约束

0.1.4：`TerminalLayout` 用 `TerminalTab` 和递归 `TerminalPaneNode` 表示“标签包含分栏”，布局比例、焦点及最大化归属于各标签。`TerminalWorkspace` 以稳定会话 ID 渲染可见分栏，不通过替换全局左右栏切换标签。`ReleaseUpdate` 提供平台无关的版本与安装包筛选，`GitHubUpdateService` 负责私有 API、下载及校验，`UpdateController` 负责 macOS 菜单和用户确认；凭据由本机 `gh` 管理。

- 不自行实现 SSH 密码学。系统 OpenSSH 负责认证、算法协商、跳板机与 known_hosts。
- 私钥路径是参数，不是拼接到本地 shell 的命令。远端 tmux 名称经过参数引用；文件操作使用 SFTP，不解析 `ls` 文本，也不要求目标安装 Python。
- Python 仅用于隔离验收环境生成测试数据和 HTTP 服务，不是客户端运行依赖。
- 文件工作区、终端和传输队列分别管理生命周期。切换页面不终止已有终端或隧道。
- 传输文件发布前使用独立临时名；源变化、断点损坏、目标冲突时失败，不静默覆盖。
- 目录扫描先构建完整清单再提交，扫描取消不会把部分扫描当作完整任务。
- 操作路径在文件协议中传递；读取数据有长度上限，UI 不在主线程做 SSH 网络 I/O。
- `ViewState` 是系统 `SwiftUI.State` 类型别名，只用于避开当前 CLT 缺失的同名宏插件。

## Windows 预留的实际范围

0.1.5：`TransferJob` 增加等待确认状态、冲突快照和已批准快照，由引擎预检/UI 决策/引擎复核闭环处理。`FilePreviewServer` 是 macOS Network 框架的回环只读 HTTP 适配，绑定固定主机与目录，`PDFKit`/`WKWebView` 渲染保持在 WorkbenchApp，不污染核心平台模型。

`WorkbenchCore` 没有 AppKit、SwiftUI、Keychain 或 Darwin 依赖，领域模型、清单格式、SFTP 编解码可复用。macOS UI、PTY、进程/管道处理、Keychain、本地原子重命名目前明确留在平台模块。

后续 Windows 客户端需要实现 Windows 原生界面、ConPTY、凭据存储、进程与本地文件适配；可以延续 OpenSSH/SFTP 协议边界。当前没有 Windows 构建，也不承诺现有 AppKit 界面直接跨平台。这样不会为尚未开发的平台牺牲本次 Mac 体验。

## 发行

Apple Silicon 与 Intel 分别编译，再用 `lipo` 合并主程序及 askpass helper。SwiftTerm 资源位于应用 `Contents/Resources`，没有运行时 CDN、网络字体或对 `.build` 目录的资源依赖。

本地包使用 ad-hoc 签名。Developer ID 签名、公证及公司设备白名单需要合法的账户/授权，不通过修改安全策略实现。
