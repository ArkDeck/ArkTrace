# AT-RUST-006 Rust Store 数据库校验（2026-10-03）

Goal 保持 active，006 为 in-progress。这轮将固定 parser 的真实输出接入安全 Rust SQLite
校验器；尚未建立产品 Ready。工具链为 Rust 1.99.0、Xcode 27.0（27A266a）、Swift 6.4，
原生 macOS 27 arm64。[机器证据](AT-RUST-006-2026-10-03-store-validation.json) 保存源码摘要、
96 个 Rust 测试名、Swift 回归/skip 审计、SQLite 编译身份和三份真实解析结果。

## 实现

- 新增 `arktrace-store`，依赖方向为 contract/platform；Engine 开发探针消费 Store。没有公开 SQL
  或 connection 注入口，first-party Store 禁止 unsafe；当前产品入口只支持原生 macOS 快照。
- 固定 rusqlite **0.40.2**，关闭默认 features，选择 bundled/hooks/limits。固定 libsqlite3-sys
  **0.38.2** 的 SQLite **3.53.2**，amalgamation/header SHA、source ID 与 public-domain 声明
  写入 `sqlite-build-lock.json` 并由 verifier 复核。Cargo.lock 的旧 21 项依赖保持版本，新增 11 项；
  32 项原始 crate license texts 均冻结。runner 拒绝可切换 SQLite 来源/语义限制的 ambient build vars。
- Native opener 要求私有 readonly 0400 regular file，保留原 HeldFile。以 `/dev/fd/N` 和
  READONLY/NOFOLLOW/NOMUTEX 打开，前后复核完整文件和父目录绑定。不复制整个 DB 到内存；
  bounded 100-byte header 检查拒绝 WAL，journal/wal/shm sidecar 均拒绝；全文件大小有预算。
- 每连接私有、串行；零 busy wait，query-only、defensive、untrusted schema，关闭 DQS、views、
  triggers 与 mmap。SQLite string/SQL/column/attachment/parameter bounds、4096 schema tables、
  65536 aggregate columns、16 MiB catalog bytes、1024/1025 semantic samples 限制相应工作。
  VM handler 覆盖 prepare/step，100-op interval、relationship 250000-op budget，并检查同一请求的
  cancellation/monotonic deadline；退出和 panic 兜底移除 handler。错误只保留封闭 facts/numeric code。
- 移植 affinity、required schema、fingerprint v2（含 quoted/Unicode/generated columns）、严格
  INTEGER identities、Int64 range/overflow、required relationship 与 sentinel、optional counter
  source 顺序/唯一性/跨 scope 歧义、两张独立表 consensus 的时钟 epoch 修正与全部 structured
  time/storage/stat quality probes。负 duration 保留 open-ended 语义。

## 发现并同步修复的现有缺口

Swift Store 已产生 `schema.counterSource` probeTruncated，但机器 scope 集合漏掉它。两端现在
接受这项封闭事实，共享质量向量覆盖它；诊断文案仍移除，unproven source 仍不读取。scope 集合
从 56 增至 57，Machine JSON 版本不变。

部分可选 `stat` 表只有 stat_type/count 时，旧 specialized probe 仍读取缺失的 source/event_name。
Swift/Rust 改为四列齐备才执行该 probe；独立 storage probes 继续按实际列运行，event counts
保持 unavailable。两端新增回归测试，遵循 AT-DB-004 的 optional schema 规则。parser adapter 1、
schema adapter 2、index schema 3 保持既有兼容版本；这轮不宣称下游已切换。

## 新执行的检查

```sh
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
sh scripts/run-swiftpm.sh test
sh scripts/test_api_baseline.sh --scratch-path /private/tmp/arktrace-migration-api-build -Xswiftc -warnings-as-errors
python3 scripts/test_macos_parser_process.py
```

使用 `/private/tmp/arktrace-migration-cargo` 与 `/private/tmp/arktrace-migration-swiftpm` 的稳定缓存。
初次依赖解析因 restricted DNS 失败，获自动审查允许后下载；SwiftPM 初次 manifest sandbox 无法
启动，获自动审查允许后运行同一稳定 runner。最终检查成功，没有把这些环境失败算作产品通过。

Rust **96 passed / 0 failed / 0 ignored**，其中 Store 20 项；包括类型伪造、range 溢出、坏关系、
filter 歧义、可选 VM 耗尽、active statement 取消/截止时间、readonly/extension 拒绝、Unicode FD
绑定、WAL/sidecars 和 file-byte bound。clippy/fmt/5-crate dependency/unsafe/32-license/verifier
通过；runner 8 tests、34 Machine fixtures/57 scopes、CI planner 29 cases 通过。

Swift **596 executed / 0 failed / 6 skipped**，无编译警告；6 项均为既有 opt-in Integration 性能/
诊断 gate，skip 审计通过。包括新增 partial-stat 回归、共享质量向量与现有 Machine scope 编码
测试。包外 API baseline 编译通过，无 warning。没有新增 App build、GUI、设备或正式分发通过。

| 实际 raw fixture | Rust durationNs | Swift oracle 比较 |
|---|---:|---|
| zlib.htrace | 32210627000 | fingerprint/capabilities/quality/duration canonical subset T0 |
| hiprofiler_data_ability.htrace | 48516841334 | 同上 |
| trace_small_10.systrace | 9127944000 | 同上 |

三份 fingerprint 都为 `cb34d8b668c21d9a5f50949338e0f4777fcd113f1ecfac4446afcb6ddf25bfc3`。
真实固定 C++ parser 经 Rust supervisor 导出，private readonly candidate 被 Rust Store 打开；
原始 Trace/parser 和 DB 摘要不变。独立 Python quick_check、两项实际 parser 输出 budget 负例、
5 个 staging owner 回收与 3 个 published owner 保留仍通过，全部检查后删除探针私有根。
这轮记录实际 **51 个 SQLite compile options** 与 source ID；没有只引用包版本推断运行时身份。

## 尚未完成

006 还需 bootstrap/全部 Ready indexes、private indexing transaction、metadata/provenance/进度、
entry lease 协调及其取消/crash/fault 窗口、正式 Engine parser/open/close 和 CLI inspect 接入。
当前 `inspect_snapshot` 只返回有限校验事实，开发探针保持 `readyAcceptance=false`。schema bounds
与 VM 预算不构成完整 RSS/大型 Trace SLO 或故障磁盘的验收结论。

macOS sandbox 原位 private-path opening policy、Windows native held-file opener、persistent typed
query sessions、其余 CLI/Analysis/Viewer/SDK/App/ArkDeck、production signature/notarization、
medium/large/cold-warm 性能、Capture、切换/回滚与 Swift 清退仍待交付。没有运行 hosted CI；
APFS gate 未重复，沿用其独立历史记录，不能作为这轮 Ready 验收。Goal 不标 complete。
