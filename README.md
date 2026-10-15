# 栖远 Farport

**把 SSH 终端、tmux 和远程文件放在一个 Mac 应用里。**

[English](README.en.md) · [下载安装](https://github.com/boyce-ywr/farport/releases/latest) · [使用说明](docs/usage.md) · [反馈问题](https://github.com/boyce-ywr/farport/issues)

macOS 14+ · Apple Silicon / Intel · [MIT 开源](LICENSE)

![Farport：同一标签内连接两台主机，左右分栏操作](docs/images/terminal.png)

## 能做什么

- **查看主机状态**：监控页显示 CPU、内存、进程、网卡速度、端口及系统/用户信息；只读、免安装，离开页面停止。Linux/macOS 已实测，Windows/Termux 的验证与权限限制见版本说明。

- **管理终端**：连接 SSH 或打开本机 Shell，使用多标签、左右/上下分栏；拖动标签排序，折叠侧栏留出更多工作空间。
- **接着上次的工作**：查看、创建和进入本机或远端 tmux 会话。关闭标签只断开连接，不结束 tmux 中的任务。
- **在主机之间传文件**：本机与 SSH 主机、两台 SSH 主机之间，都能复制文件和文件夹，支持多选、断点续传和同名覆盖确认。
- **直接查看远端文件**：预览文本、图片、Markdown、HTML、PDF 和音视频；Java、Python、JSON/XML 等常见文件有语法高亮。编辑保存前检查文件是否被其他程序修改。
- **把图片交给远端 Agent**：在终端粘贴剪贴板图片，或拖入文件。Farport 会先上传并校验，再插入目标机器能读取的路径，不自动回车。

还有主机分组和颜色标记、SSH 配置导入、跳板机、端口转发、终端搜索、双指缩放字体，以及深浅色外观。

支持简体中文和英文，可在设置中选择，下次启动生效。文件工具栏的返回按钮按访问历史回退，各个来源分别记住路径。

### tmux 会话

长时间运行的任务放在 tmux 中，断开后再进入。会话列表能看到窗口、进程和工作目录。

![tmux 会话列表，显示窗口和工作目录](docs/images/tmux.png)

### 文件传输

选中文件，复制到另一个来源，或使用“传输到”。遇到同名目标会先询问；目录合并时保留目标中额外的文件。

![两台 SSH 主机之间的传输记录与覆盖确认](docs/images/transfers.png)

### 文件预览与编辑

不必先下载再打开。Markdown 可切换格式预览和源码，编辑器支持并排预览；PDF 可以翻页和缩放。

![远端文件列表与 Markdown 格式预览](docs/images/markdown.png)

HTML 报告也能在浏览器打开。Farport 在 Mac 本机提供临时访问地址，通过 SFTP 读取报告和相对资源，不需要在远端部署 Web 服务。默认不执行脚本，可信报告可手动允许。

![远端 HTML 报告在文件预览区打开](docs/images/html.png)

<sub>以上为真实应用截图，使用隔离主机和演示文件。</sub>

## 安装

从 [GitHub Releases](https://github.com/boyce-ywr/farport/releases/latest) 下载 DMG。当前版本 **0.1.8**：

| 你的 Mac | 下载 |
| --- | --- |
| Apple Silicon（M 系列） | [Apple Silicon 版](https://github.com/boyce-ywr/farport/releases/download/v0.1.8/Farport-0.1.8-arm64.dmg) |
| Intel 芯片 | [Intel 版](https://github.com/boyce-ywr/farport/releases/download/v0.1.8/Farport-0.1.8-x86_64.dmg) |
| 不确定芯片，或需要两种架构 | [Universal 通用版](https://github.com/boyce-ywr/farport/releases/download/v0.1.8/Farport-0.1.8-universal.dmg) |

1. 打开 DMG，将 **Farport.app** 拖入 **Applications（应用程序）**。
2. 从“应用程序”打开 Farport。升级前请先保存工作并退出旧版。
3. 不确定芯片类型时，可以在苹果菜单的“关于本机”中查看。Release 也提供 ZIP 和 SHA-256 校验清单。

安装包自带所需组件，普通 SSH 使用不需要安装 Swift、Docker 或 GitHub CLI。要管理某台机器的 tmux 会话，该机器需要已有 tmux。

> **首次打开请注意**：当前安装包尚未完成 Apple Developer ID 签名和公证，macOS 可能拦截。确认来源和校验和后，可按 [Apple 官方说明](https://support.apple.com/102445)，在“系统设置 → 隐私与安全性”中检查是否允许打开。不要关闭系统防护；若提示恶意软件或受公司策略限制，请停止并联系管理员。
>
> Apple Silicon 已运行验证；Intel 已构建并检查安装包，但尚未进行 Intel 真机运行测试。项目仍在早期迭代。

## 第一次使用

1. 点击侧栏“我的主机”旁的 **+**，填写地址、用户名和认证信息，也可以导入已有 SSH 配置。
2. 点击 **测试连接**，检查 SSH 和 SFTP；保存后连接。首次连接请核对服务器指纹。
3. 需要保留工作现场时，切到 **tmux 会话**；需要文件操作时，切到 **文件**。本机终端可直接从侧栏打开。

| 常用操作 | 快捷键 |
| --- | --- |
| 新建终端 / 本机终端 | ⌘T / ⌘⇧T |
| 左右分栏 / 上下分栏 | ⌘D / ⌘⇧D |
| 切换分栏 | ⌘[ / ⌘] |
| 最大化或还原当前分栏 | ⌘⇧Enter |
| 折叠或展开侧栏 | ⌘⌥S |
| 搜索终端内容 | ⌘F |

## 几个常见问题

**终端右键和附件怎么设置？** 默认右键有复制、粘贴和选择操作；设置中可选 tmux 菜单，Shift＋右键临时返回普通菜单。附件默认安全自动插入，可全局关闭或对单个主机覆盖；目标发生变化时仍需确认，不自动回车。

**怎么更新？** 重新下载 Release 安装包即可，不需要 GitHub CLI。0.1.8 的应用内“检查更新”目前依赖已登录的 GitHub CLI；下载后会校验安装包，再由你确认安装，不会自动关闭终端。

**可以配合 Codex、Claude Code 使用吗？** 可以把图片和文件发送到它们所在的机器。远端 Codex + tmux 的图片流程已验证；Claude Code 的完整图片识别流程尚未单独验证。二次 SSH、容器或不同用户可能隔离文件系统，需要确认接收程序能访问上传位置。

**数据会不会上传到其他服务？** 主机配置和任务记录保存在本机，凭据使用 macOS 钥匙串；文件只发送到你选择的目标。HTML 预览地址仅监听本机，但包含临时访问令牌，请勿分享。详见 [安全与使用边界](docs/usage.md)。

**支持 Windows 吗？** 当前只有 macOS 客户端。Windows 尚未实现。

## 反馈与开发

遇到问题或有建议，欢迎提交 [Issue](https://github.com/boyce-ywr/farport/issues)。请附上应用版本、macOS 版本、芯片类型和复现步骤，截图中不要包含密码、私钥、访问令牌或私人主机信息。

- [完整使用说明](docs/usage.md)
- [构建、测试与截图](docs/development.md)
- [已验证范围与已知限制](docs/validation.md)
- [更新记录](https://github.com/boyce-ywr/farport/releases)

## 许可证与致谢

Farport 使用 [MIT 许可证](LICENSE)，允许使用、修改、分发和商用，需保留版权与许可声明。

终端使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)，SSH 使用 macOS 自带 OpenSSH。Haven 为功能和交互设计提供了参考，Farport 未复制其源码。第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
