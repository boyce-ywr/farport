# Farport：Apple 用户名密码认证的客户端源码证据

核查日期：2026-10-19。范围仅为官方客户端源码、项目文档、许可证和发布记录；不实现代码，不提供绕过认证方案。**本记录不代表已对 macOS 27 做真机验证**，也不证明 Apple 账号授权、会话选择或高性能屏幕共享兼容；这些问题交由 Apple 官方文档调研与后续实机测试确认。

## 结论摘要

三个候选客户端均有 security type 30 实现，不能把“第三方 VNC 客户端”一概等同于“只能使用传统 VNC 共享口令”。其中 TigerVNC 的实现叫 **DH / CSecurityDH**，不是 ARD，单搜 ARD 会漏判。源码证明的是客户端具备发送用户名、密码并处理认证协议的能力，不是某个 macOS 版本必定接受连接。[L1][N1][T1]

## 1. LibVNCClient：明确支持 ARD 30，但有构建条件

- 官方 README 的 Security Types 表把 Apple ARD / 30 标在 **LibVNCClient** 一列，LibVNCServer 一列为空；不能将客户端能力外推成该库服务端也实现了 Apple 认证。[L2]
- `rfbARD` 定义为 30；`case rfbARD` 调用 `HandleARDAuth`。该函数通过 `GetCredential(client, rfbCredentialTypeUser)` 获取用户名、密码，执行 DH 密钥协商、MD5 派生、AES-128-ECB 凭证加密，再检查服务端 `SecurityResult`，不是认证占位符。[L1][L3]
- **集成陷阱**：CMake 的完整密码后端选 Libgcrypt 或 OpenSSL；内置后端只有 SHA1/D3DES，`encrypt_aes128ecb`、`dh_generate_keypair`、`dh_compute_shared_key` 都返回失败。仅仅编译出 LibVNCClient 不等于这个构建能完成 ARD。[L4][L5]
- 对 Farport 的工程判断：C 回调适合原生桥接，但需要维护密码后端、网络事件循环与 UI/帧缓冲适配；这只是集成成本判断，尚未做桥接原型。

## 2. noVNC：真实 ARD 实现与协议测试，代价在 Web 运行时

- `securityTypeARD = 30`；`_negotiateARDAuth()` 缺凭证时发出 `credentialsrequired`，明确请求 `username`、`password`，随后执行 DH/MD5/AES-ECB，发送凭证与公钥并进入 `SecurityResult`。[N1]
- 官方测试有 `ARD authentication (type 30) handler`，覆盖缺失凭证事件与加密凭证、公钥输出。**这是仓库测试内容的静态核对，本次没有运行测试，更不是 macOS 联机测试。**[N2]
- README 明确要求 WebSockets；只接受 TCP 的目标需要 WebSocket→TCP 转接。因此在 Farport 内嵌 WebView 的方案，还需要设计传输适配、页面与原生生命周期，而不能把 noVNC 当成可直接拨 TCP 的 Swift 库。这里未核实 macOS 27 服务端是否另有 WebSocket 接口。[N3]

## 3. TigerVNC：type 30 名为 DH，并依赖 Nettle

- `Security.h` 定义 `secTypeDH = 30`；`SecurityClient::GetCSecurity` 在 `HAVE_NETTLE` 条件下创建 `CSecurityDH`，支持列表也受同一构建条件控制。不能仅看有无 `CSecurityARD` 文件来判断支持情况。[T1][T2]
- `CSecurityDH::writeCredentials()` 调用 `getUserPasswd(..., &username, &password)`，实现 DH、MD5、AES-128，并发送加密后的 128 字节用户名/密码结构与客户端公钥。这与另外两个项目的 type 30 数据流程相符。[T3]
- 对 Farport 的工程判断：可作为独立客户端对照与协议参考；直接内嵌还要处理 C++/Nettle 依赖和客户端组件拆分，不能把完整 viewer 等同于现成的原生 UI SDK。

## 4. ARD 用户名密码与传统 VNC 口令不能混为一谈

| 项目 | ARD / DH，type 30 | 传统 VNC Auth，type 2 |
| --- | --- | --- |
| 客户端输入 | 用户名与密码 | 只有密码，没有用户名字段 |
| 本次观察到的处理 | DH 共享秘密经 MD5 派生密钥，AES 加密凭证结构 | challenge-response；LibVNCClient 调用 `GetPassword`，截取前 8 字节后加密 challenge |
| 产品含义 | 实现了账号凭证协议路径；账号是否获授权由服务端决定 | 不是在用户名密码协议中省略用户名，而是另一种认证类型 |

依据：[L1][L6][N1][N4][T3]。这里不以客户端代码推断 Apple 当前系统设置开关、账号权限或会话策略。

两个不能遗漏的边界：

- **认证凭证加密不等于后续桌面流量全程加密。** TigerVNC 的 `CSecurityDH::isSecure()` 明确返回 `false`；不得因为认证中出现 AES，就宣称连接具有 TLS 的安全属性。[T4]
- **长度行为并不统一。** noVNC 对 UTF-8 编码后的用户名、密码分别截到 63 字节并补 NUL；TigerVNC 对长度达到 64 字节的字段报错；LibVNCClient 则最多复制每字段 64 字节。产品设计需明确超长、多字节凭证的处理，不能把这些实现差异当作 macOS 27 的账号长度规则。[N1][T3][L1]

## 5. 维护与许可证代价

以下发布信息来自核查时官方 GitHub `releases/latest`；同时核对发布标签内已有认证代码，而不只看未发布 master。提交时间是整个仓库的活跃信号，不是 ARD 功能最近修复时间，更不是维护 SLA。

| 项目 | 官方 latest release / 发布日期 | 本次固定核查的 master 提交 | 许可证与工程决策边界 |
| --- | --- | --- | --- |
| LibVNCServer / LibVNCClient | `LibVNCServer-0.9.15` / 2024-12-22 | `98aaee0560baa0332339b2ef464ea96ed9b9b28c` / 2026-10-07 | 项目声明 GPL-2.0-or-later；官方 FAQ 明确把链接 LibVNCClient 的程序视为衍生作品。不能按宽松许可依赖引入后仍声称整个组合仅受 MIT 约束。[L7][R1] |
| noVNC | `v1.7.0` / 2026-04-28 | `4a2cc175ae8af50fe8cb85a05d40908c01c43f6a` / 2026-10-16 | 核心 JS 为 MPL-2.0；官方随附条款 3.1–3.3 要求遵守 Covered Software 的源码分发义务，允许 Larger Work 使用自己的条款。HTML/CSS/图片另有许可，不能只登记一个 MPL 标签。[N5][N6][R2] |
| TigerVNC | `v1.16.2` / 2026-03-26 | `30df0c7fc228d518149ccc2ad7b918a4639f38de` / 2026-10-16 | 仓库附 GPL v2；本次认证实现文件头明确允许 GPL v2 或更高。复制这段认证实现或直接链接前，都要评估其 GPL 分发要求。[T3][T5][R3] |

Farport 当前根目录 `LICENSE` 为 MIT。这里仅记录项目许可声明与技术选型风险，不替代针对具体分发组合的法务判断；没有评估所有传递依赖许可，也不声称动态链接、进程拆分或改写语言可以自动消除义务。

**建议给主设计的取舍**：若保持原生客户端方向，先评估 LibVNCClient 的 GPL 分发边界与完整密码后端；若接受 WebView，noVNC 的 MPL 组合边界更灵活，但新增 WebSocket 传输适配成本；TigerVNC 可作为另一份 type 30 源码和对照客户端。三者均不是仅因“有 ARD 30”就能宣布完成 Apple 原生屏幕共享兼容。

下一阶段只应在获授权的测试 Mac 上验证：实际协商是否提供 type 30、有效/无效凭证、账号获准/未获准、锁屏与登录状态、超长/Unicode 凭证，以及认证后画面与输入。Apple 高性能模式不在本次证据范围内。

## 官方证据索引

实现与文档链接固定到本次读取的提交，避免后续 master 漂移；发布链接固定到标签。

- [L1] [LibVNCClient：HandleARDAuth 与分派，807–919、1083–1085 行](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/src/libvncclient/rfbclient.c#L807)
- [L2] [LibVNCServer README：Security Types 表](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/README.md#L31)
- [L3] [rfbproto.h：rfbARD = 30](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/include/rfb/rfbproto.h#L303)
- [L4] [CMake：密码后端选择](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/CMakeLists.txt#L251)
- [L5] [crypto_included.c：AES/DH 未实现](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/src/common/crypto_included.c#L82)
- [L6] [HandleVncAuth：密码回调与 8 字节截断](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/src/libvncclient/rfbclient.c#L568)
- [L7] [官方链接许可 FAQ 与 GPL-2.0-or-later 声明](https://github.com/LibVNC/libvncserver/blob/98aaee0560baa0332339b2ef464ea96ed9b9b28c/README.md#L276)
- [N1] [noVNC：ARD 凭证处理，1801–1868 行；同文件第 66 行定义类型 30](https://github.com/novnc/noVNC/blob/4a2cc175ae8af50fe8cb85a05d40908c01c43f6a/core/rfb.js#L1801)
- [N2] [noVNC：ARD 协议测试](https://github.com/novnc/noVNC/blob/4a2cc175ae8af50fe8cb85a05d40908c01c43f6a/tests/test.rfb.js#L2096)
- [N3] [noVNC：WebSockets 服务端要求](https://github.com/novnc/noVNC/blob/4a2cc175ae8af50fe8cb85a05d40908c01c43f6a/README.md#L99)
- [N4] [noVNC：传统 VNC Auth 仅请求 password](https://github.com/novnc/noVNC/blob/4a2cc175ae8af50fe8cb85a05d40908c01c43f6a/core/rfb.js#L1785)
- [N5] [noVNC 许可组成](https://github.com/novnc/noVNC/blob/4a2cc175ae8af50fe8cb85a05d40908c01c43f6a/LICENSE.txt)
- [N6] [noVNC 随附 MPL-2.0，第 3.1–3.3 节](https://github.com/novnc/noVNC/blob/4a2cc175ae8af50fe8cb85a05d40908c01c43f6a/docs/LICENSE.MPL-2.0#L157)
- [T1] [TigerVNC：secTypeDH = 30](https://github.com/TigerVNC/tigervnc/blob/30df0c7fc228d518149ccc2ad7b918a4639f38de/common/rfb/Security.h#L51)
- [T2] [TigerVNC：HAVE_NETTLE 支持列表与分派，50–78、114–128 行](https://github.com/TigerVNC/tigervnc/blob/30df0c7fc228d518149ccc2ad7b918a4639f38de/common/rfb/SecurityClient.cxx#L50)
- [T3] [TigerVNC：CSecurityDH 凭证实现与文件头许可](https://github.com/TigerVNC/tigervnc/blob/30df0c7fc228d518149ccc2ad7b918a4639f38de/common/rfb/CSecurityDH.cxx#L111)
- [T4] [TigerVNC：DH isSecure() 返回 false](https://github.com/TigerVNC/tigervnc/blob/30df0c7fc228d518149ccc2ad7b918a4639f38de/common/rfb/CSecurityDH.h#L38)
- [T5] [TigerVNC 仓库 GPL v2 许可正文](https://github.com/TigerVNC/tigervnc/blob/30df0c7fc228d518149ccc2ad7b918a4639f38de/LICENCE.TXT)
- [R1] [LibVNCServer 0.9.15 官方发布](https://github.com/LibVNC/libvncserver/releases/tag/LibVNCServer-0.9.15)；[发布标签内 ARD 实现](https://github.com/LibVNC/libvncserver/blob/LibVNCServer-0.9.15/src/libvncclient/rfbclient.c#L807)
- [R2] [noVNC 1.7.0 官方发布](https://github.com/novnc/noVNC/releases/tag/v1.7.0)；[发布标签内 ARD 实现](https://github.com/novnc/noVNC/blob/v1.7.0/core/rfb.js#L1794)
- [R3] [TigerVNC 1.16.2 官方发布](https://github.com/TigerVNC/tigervnc/releases/tag/v1.16.2)；[发布标签内 DH 实现](https://github.com/TigerVNC/tigervnc/blob/v1.16.2/common/rfb/CSecurityDH.cxx#L104)

核查方式：经 `127.0.0.1:7897` 代理读取官方 GitHub API、固定提交源码归档和发布标签源码。未安装依赖、编译客户端或发起屏幕共享连接。仅新增本笔记；未修改其他项目文件，未 commit/push。
