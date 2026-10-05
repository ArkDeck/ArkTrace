# AT-RUST-012/013：统一实际快照格式与生成契约

日期：2026-10-06；基线 `d6965ec8d7f83b3e3739a53106a0fd31136522b0`。

## 修正

`contracts/ffi-v1.json` 仍声明 `snapshotFormatVersion: 1`，实际 Rust C ABI
producer 输出 `format_version: 2`，Swift `RustSnapshot` 也只接受 2。此前 verifier
没有核对该属性，生成的 contract digest 因此包含错误声明。

本轮将声明修为 2，并从这一属性生成 C、Rust、C# 的 snapshot-format 常量。
Rust producer 与 Swift admission 使用生成常量；实际 Swift C-import smoke、C# smoke
源码和 macOS native owner harness 明确核对格式 2 与当前契约一致。ABI 仍为 2，
10 records、122 fields、26 exports 和所有 record layout 不变；没有新增 FFI 入口。

当前契约 SHA-256：
`bf21cbfb22e4afc34b8169f9961c27119ffa789154e441a838de4240ad3b8617`。
历史 `76202167…` 和其 SDK 的证据保持原样，不能覆盖本轮改动。

## 新执行的检查

- generator check、Rust fmt、workspace verifier、migration verifier、strict
  workspace/all-targets/all-features clippy、workspace build、migration smoke 通过。
- Rust workspace/all-features 本轮 567 tests 通过（含 6 doc tests）。独立生产依赖
  JSON consumer 实际执行两组各 10,000 个 Viewport roundtrips。
- 实际 native FFI layout/Swift C-import smoke 通过，核对当前 digest 和 snapshot format 2；
  1,000 个合法分配内的 arbitrary-byte fuzz cases 通过。C# 源码已同步，未执行 Windows/.NET。
- 三份真实 small corpus 的 native C ABI owner harness 与 fresh Swift oracle 对照通过，
  包含实际非空 snapshots、跨 Engine/wrong-domain/stale-generation 拒绝、close/drain 后保留读取。
  第一份 corpus 观察到最后 owner refund；其余两份在 Engine release 后保留 owner，
  harness 未观察其最终 refund，不能声称三份均有最终额度归零证据。
- 包外 fixture SDK consumer 编译通过，94 SDK unit tests 无 skip，4 个 borrowed
  Span/text 逃逸编译拒绝通过。该 harness 的 `--build-only` 不算 SDK lifecycle 执行。
  五个独立当前原 Swift event/density/batch/deadline/repository reference 编译通过。
- 完整默认 Swift 638 passed、fixture-native Swift 749 passed；两者只有同 6 个既有
  opt-in skips。正常 SDK Swift build 和包外 API baseline 编译通过。
- 对应 CI contracts 的 15 项离线 gates 全部通过。Debug 与优化 Release App 新构建、
  本地签名、strict signature、runtime/helper/parser resources、arm64、最低 macOS 26、
  document types 和 Release DeveloperID hardened-runtime 核对通过。未公证或发布。

Swift 编译日志无 warning；两个成功 App 构建各有一条既有 AppIntents metadata
extraction 提示。完整 diff 的 CI planner 选五车道，Windows native 车道未在本机执行。

新正常 SDK library SHA-256：
`d3b71b90d2963f48f33a1a4d51dfd19644b0614d5911317855590002d19c3dd7`；
fixture SDK library SHA-256：
`5d5b51fed79a8dc033d9e42c47d0ce4f38335314099cf28add3d15a4e0816ea9`。
两份不可变 xcframework、receipt 与最终 App 均冻结在本轮 packet 中。SDK stage identity
与 library digest 不同，不将二者混用。

## 实际 medium Controller 检查

重新编译当前正常 SDK 的包外 Controller caller，在全新私有根打开原始 265,032,803-byte
`pbreader.htrace`（SHA-256 `695a160f3c99472cc746a09c75ae70c2dcef2d0323028fdb39e02196e1e6a7f9`），
再缓存重开。分别观察 `cacheHit: false/true`。同一 callstack event 的全部 typed 字段、
实际 rendered Inspector 和 12 条有序参数，与系统 sqlite3 只读 immutable URI 读取的
原始行精确一致；truncation、close 后 active leases 0 与 native shutdown 通过。

本轮 Ready DB 为 256,651,264 bytes，SHA-256
`7132fe067efa94cfdfb675a2cd1b2637e81aa3416a1ee03babf939aeb58b60d7`，index schema 4。
独立比对前后 DB 和原始 Trace digest 不变。这是实际 Controller/SDK/DB 检查，
没有执行 App window GUI，也未观察独立 deadline calls 或完整 process forest。

## 失败保留与剩余范围

本轮三个初始失败完整保留。Root 在 direct API/Release xcodebuild 命令中误用了
绝对 binaryTarget path，改成已验证的 package-relative staged SDK 后分别通过；
Controller probe 首次编译因 Root 在既有缓存中加入重复 `@main` source 失败，移除
仅本轮加入的重复文件后通过。三次修正只改验证命令或缓存 source set，没有修改
生产实现、放宽预算或断言。每次重试使用独立 receipt，原失败没有覆盖。封包自检第一次误将自身的 running
receipt 当成 ended receipt 而失败；重试只排除当时正在运行的自身 receipt，随后
sealer 再独立核对包括该 receipt 在内的全部结束状态和日志 hashes。

packet：`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-snapshot-format-contract-20261006/`。
包含实际 argv/cwd/env/start/end/exit/log hashes、原不一致声明、最终 source、
新 SDK/App、实际 FFI producer 与 fresh Controller/SQLite 结果。此前 sealed packets 未改。
本轮不证明完整 compiler input closure。

工具链为 exact Rust 1.99.0/edition 2024、Xcode 27.0/Swift 6.4/language mode 6。
最近一次桌面工具检查仍返回 Mac locked；真实 GUI、>500 MiB reviewed input、性能/RSS、
完整进程树、真实 Capture、ArkDeck schema-4 消费及适用发行/安装/回滚仍未通过。
Rust 共享 hit 查询尚未暴露到 C ABI/SDK，当前 macOS hit/interaction 仍有 Swift 实现。
011/012/013 与 macOS 总验收不标完成，goal 管理器仍 blocked；未修改 ArkDeck。
