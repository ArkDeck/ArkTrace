# Capture

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §2.3, §3；docs/design/CAPTURE.md
> Applicability: ArkTrace.app Capture window only

## Purpose

用户可以在 App 里从已选择的 OpenHarmony 设备采集一份 trace。采集结果是本机文件，之后与任何其他输入走同一条解析路径。CLI 和 ArkDeck 不获得这条能力。

## Requirements

### Requirement: REQ-CAP-001 Capture is an explicit GUI action

细则：AT-SYS-003，CAPTURE.md §1–§2。

采集 SHALL 只从 App 的 Capture 窗口启动，入口包括 File → Capture Trace…、主工具栏和空状态。`ArkTraceCapture` SHALL NOT 依赖 Core、Runtime、Parser、Store 或 CLI。App SHALL NOT 捆绑或下载 HDC，SHALL 使用用户机器上的 OpenHarmony SDK 工具。

#### Scenario: AC-CAP-001-01 采集不会在打开文件时启动

- GIVEN 用户只通过 Open 面板打开一个已有 trace
- WHEN 文档完成加载
- THEN 没有 HDC 发现或采集进程被启动

### Requirement: REQ-CAP-002 A capture becomes a normal host file

细则：SPECIFICATION §2.3，CAPTURE.md §1。

设备侧 `hiprofiler_cmd` 的结果 SHALL 先物化为本机文件，并在校验后原子保存。该文件随后 SHALL 进入与离线文件相同的 parser 和 schema 校验。采集 SHALL NOT 构成第二种输入语义。

#### Scenario: AC-CAP-002-01 保存后的文件可被 CLI 打开

- GIVEN 一次成功采集并原子保存的本机文件
- WHEN `arktrace inspect` 打开该文件
- THEN 它走离线 parser 路径
- AND 不需要设备仍然连接

### Requirement: REQ-CAP-003 Capture does not deploy or upload

细则：AT-SYS-003、AT-SEC-004，CAPTURE.md §2。

采集 SHALL NOT 部署 HAP、控制应用生命周期、刷机或上传 trace。传输 SHALL 限于用户发起的 HDC USB 或 HDC 自身的网络调试，SHALL NOT 扩展为任意网络客户端。

#### Scenario: AC-CAP-003-01 失败的采集没有上传

- GIVEN 采集在传输阶段失败
- WHEN 会话进入 failed
- THEN 没有云端上传
- AND 没有应用安装或刷写步骤

### Requirement: REQ-CAP-004 Cancellation stops the owned capture

细则：CAPTURE.md §3。

采集进行中 SHALL 保留 Cancel。取消 SHALL 使会话进入 cancelled，并停止这一次拥有的设备侧采集与传输。取消 SHALL NOT 修改用户已经另行保存的原始文件。

#### Scenario: AC-CAP-004-01 录制中取消

- GIVEN 会话处于 recording
- WHEN 用户按下 Cancel capture
- THEN 会话进入 cancelled
- AND 不把未完成的传输发布为已打开的 trace
