# ArkTrace Trace 采集设计

> 状态：Implemented（App-only）
> 日期：2026-08-24

## 1. 目标

ArkTrace.app 现在可以从已连接的 OpenHarmony 设备完成一条闭环：

```text
选择 HDC → 发现设备 → 选择预设/时长/缓冲区
  → 设备侧 hiprofiler_cmd 采集
  → HDC 拉回本机临时文件
  → 校验并原子保存
  → 自动交给既有 TraceDocumentController 打开
```

入口位于 **File → Capture Trace…**（⌘N）、主工具栏和空状态。采集使用独立窗口，因此当前 Trace 在下一轮采集时仍可查看。

## 2. 能力边界

设备能力只存在于 `ArkTraceCapture` 与 GUI App：

```text
ArkTrace.app ───────→ ArkTraceCapture ───────→ user-selected SDK hdc
     │
     ├──────────────→ AppSupport / Runtime / Parser / Store / Analysis
     │
arktrace CLI ───────→ Runtime / Parser / Store / Analysis
ArkDeck analyzer ───→ arktrace CLI
```

- `ArkTraceCapture` 不依赖 Core、Runtime、Parser、Store 或 CLI；
- CLI 与 ArkDeck analyzer 不链接该模块，继续保持 host-only、无 HDC route；
- App 不捆绑或下载 HDC，只使用用户机器上的 OpenHarmony SDK；
- 不部署 HAP、不控制应用生命周期、不 Flash、不上传 Trace；
- 设备连接可以是 USB 或 HDC 自身支持的网络调试，但没有任意网络客户端。

## 3. 交互与状态

窗口按任务顺序分成三块：Connection、Capture setup、固定底部 action/status 区。最重要的操作始终在底部可达，不会因窗口缩小或错误详情展开而被裁掉。

状态机为：

```text
idle → discovering → ready
ready → preparing → recording → transferring → completed
                         └──────── cancelling → cancelled
任一执行阶段 ───────────────────────────────→ failed
```

- 单设备时自动选中；多设备时必须显式选择；
- 采集进行中禁用配置和窗口关闭，保留 **Cancel capture**；
- `recording` 显示秒数与确定进度，传输阶段使用不确定进度；
- 完成、取消、错误都以图标与文字表达，不依赖颜色；
- 阶段变化通过 VoiceOver announcement 合并播报，不逐秒打断用户；
- 所有操作使用原生 Button、Picker、Stepper、Open/Save panel，支持键盘和系统焦点行为；
- Reduce Motion 开启时不引入额外位移动画。

## 4. 采集预设

| 预设 | 主要数据 | 适用问题 |
|---|---|---|
| App responsiveness（默认） | scheduling + ACE/ArkUI、Binder、graphics、window、RPC 等 Hitrace category | 卡顿、慢交互、跨线程调用 |
| CPU scheduling | scheduling/wakeup + CPU frequency/idle | 调度竞争、CPU 忙碌、频率变化 |
| System overview | 上述两组 + distributed、memory、system category | 尚不确定根因的宽采集 |

时长限制为 5–300 秒；buffer 可选 16/32/64/128/256 MB。两者都是硬边界，避免 UI 或 API 产生无界采集。配置使用 OpenHarmony 官方 `hiprofiler_cmd` protobuf text 形状：`session_config`、`ftrace-plugin`、`sample_duration`、`buffer_size_kb`、`ftrace_events` 与 `hitrace_categories`。

## 5. HDC 发现与调用

HDC 解析顺序：

1. 上次用户明确选择的位置；
2. `HDC_PATH` / `HDC_SDK_PATH` / `OHOS_SDK_HOME`；
3. 当前 App 环境的 `PATH`；
4. DevEco Studio 默认 macOS SDK 位置；
5. Homebrew 常见位置；
6. 若仍未找到，由用户通过 Open panel 选择。

解析结果必须是可读、可执行的 regular file。所有执行都使用 `Process.executableURL` 与 `arguments[]`；不调用宿主 shell，不拼接命令字符串，也不解释设备 ID。设备端只允许固定的 `hiprofiler_cmd` 与 session-owned `rm` 子命令，不提供通用 remote shell。`DYLD_*` 不传给子进程，HDC 端口等 SDK 环境保留。

每次采集使用 UUID 生成设备端文件名，并按以下步骤执行：

1. 在本机临时目录生成配置；
2. `hdc -t <device> file send` 传配置；
3. `hdc -t <device> shell hiprofiler_cmd -c <config> ... -s -k`；
4. `hdc -t <device> file recv` 拉到目标目录内的隐藏 `.partial` 文件；
5. 确认结果是非空 regular file；
6. 用独立任务调用 `hiprofiler_cmd -k`，并尝试删除本次 UUID 对应的设备端临时文件；
7. 再次检查取消状态，随后原子 move/replace 到 Save panel 已确认的目标。

stdout/stderr 各自有 64 KiB 上限；错误详情最多保留 4 KiB，避免异常设备输出占满内存或 UI。

## 6. 取消与失败安全

- 取消会终止当前 HDC 子进程，500 ms 后仍未退出则只对该 PID 发送 SIGKILL；
- 随后用独立清理任务执行设备侧 `hiprofiler_cmd -k`，并删除本次生成的两个远端路径；
- `.partial` 永不交给 Parser，也不会进入 Recent；
- 只有非空文件完成原子 promotion 后才触发自动打开；
- 已存在目标只会在 NSSavePanel 已确认覆盖后替换；
- 远端清理是 best-effort：断线时本次 UUID 文件可能暂留在设备的
  `/data/local/tmp`，但 ArkTrace 不会因此删除任何用户原始 Trace，也不会把
  已取消的本机 partial 提升为正式文件。

## 7. 故障恢复

| UI 提示 | 检查项 |
|---|---|
| HDC was not found | 在 OpenHarmony SDK `toolchains` 中选择 `hdc` |
| No devices found | 开启设备 USB/网络调试，确认线缆或 HDC TCP 连接，再 Refresh |
| could not list connected devices | 检查 HDC server/端口，以及 DevEco Studio 是否占用另一套 HDC |
| device could not capture | 确认设备包含 `hiprofiler_cmd`、允许 profiling，预设事件在该系统版本可用 |
| could not be copied | 保持设备在线，检查本机目标目录空间与写权限 |
| empty or unreadable | 延长时长、增大 buffer 或更换预设 |

## 8. 验证

`ArkTraceCaptureTests` 固定以下契约：

- duration/buffer 的输入边界；
- 三种预设生成的官方字段与单位换算；
- HDC target 去重和 USB/network 分类；
- 全流程只使用参数数组；
- send → record → recv → stop → cleanup 的顺序；
- 非空校验与原子 promotion；
- 清理阶段取消不会 promotion，并会删除本机 partial；
- controller 的发现、自动选择、阶段、完成回调和 cancellation。

2026-08-24 已完成一次连接设备的最小真机烟测：App responsiveness、5 秒、
16 MB buffer，经同样的 send → record → recv → stop → cleanup 链路得到
782,367-byte `.htrace`；pinned TraceStreamer 4.3.7 成功解析，ArkTrace
`inspect --no-cache` 识别到有效 trace range，以及 CPU scheduling、thread states、
named slices 三项 capability。本次烟测临时产物已清理，不替代可追溯的发布 evidence。

真机发布验证仍需覆盖 USB 与网络各一次、三种 preset 各一次、采集中断线、用户取消、目标覆盖，以及完成后由 pinned TraceStreamer 成功打开。

## 9. 官方依据

- [OpenHarmony Performance Profiler：hiprofiler_cmd 参数与 ftrace/Hitrace 配置示例](https://gitcode.com/openharmony/developtools_profiler/tree/master)
- [OpenHarmony HDC 指南：`-t`、`list targets`、`file send/recv` 与 macOS SDK 位置](https://gitee.com/openharmony/docs/blob/master/zh-cn/device-dev/subsystems/subsys-toolchain-hdc-guide.md)
- [SmartPerf 在线采集流程与 probe 语义](https://gitee.com/openharmony-sig/smartperf/blob/master/host/ide/src/doc/md/quickstart_web_record.md)
