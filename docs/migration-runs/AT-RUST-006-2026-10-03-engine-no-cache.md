# AT-RUST-006 Engine no-cache 纵向实现（2026-10-03）

Goal active，006 in-progress。Rust **1.99.0**、Xcode **27.0 (27A266a)**、原生 macOS 27 arm64。
Engine 已执行固定 parser → 校验/索引 → metadata → ephemeral Ready → 显式 close；产品 CLI/
SDK/App 与完整迁移验收仍未接入。[机器证据](AT-RUST-006-2026-10-03-engine-no-cache.json)
保存当前源码、日志摘要、113 个测试名、三个实际 trace 和十个负例。

## 实现

Engine 接收已验证 helper/parser，复核 binary SHA、adapter、architecture 与实际 `--version`。
原 source 分块 hash/copy 为 session 0400 快照，采用 literal argv、`-e -nm`、固定 64 KiB
stdout/stderr/ohos sidecar 与独立 source/DB/deadline/cancellation 预算。

key lock 覆盖构建。Input owner 分配唯一 no-cache 名称，fresh exclusive ephemeral entry lease
先于 candidate owner 建立。每次打开有独立 Ready 目录，两个同源存活 session 不共享输出。
这个 no-cache lease 并非 persistent cache 的 stable shared-reader lease；ArkDeck 不消费此根。

新 0600 candidate 完成两阶段索引事务、schema/quality 校验、DELETE 恢复、0400 封存和现有
format-1 metadata。exact membership 与全部 index closure 通过后原子 rename；发布后再次
比较原始 file snapshots、metadata、DB SHA/size，复开 SQLite 检查全部索引/语义，清理 input
owner，最终检查身份和取消状态后才返回 NoCacheSession。

Metadata 保留现有 13 个根字段及 parser/key/preparation 的 8/6/5 字段，16 KiB 边界，拒绝
unknown/duplicate，交叉校验 key/hash/version/size，UTC ISO 8601 日期。Owner format 2 独立；
没有改 metadata 字段或 parser/schema/index 的 1/2/3 兼容版本。

显式 close 以独立五秒 cleanup budget 移除该 Ready owner，再移除自己新建的 ephemeral
lease。Lease 只允许 fresh O_EXCL 名称；稳定 cache key lock 不 unlink。Drop 不做 IO，保留
durable proof。失败 cleanup 优先于原错误；stage/failure 只含封闭事实，没有用户路径。

## 真实发现的辅助输出

初次 exact-membership 检查拒绝了 zlib parser 的 `ts_tmp`；失败调用完成清理。检查实际固定
binary 输出发现目录为 0700，唯一 `unzlib_file.txt` 为 0600、849657 bytes。现在只接受这个
exact shape，以 held no-follow/private owner/ACL/links 和 source-byte budget 校验/hash；
input owner 在 Ready 前移除它，没有 wildcard 或任意目录许可。

当前检查发生在进程组完全清理后；**live-growth budget 尚未实现**，现有 private process
protocol 只监督 flat declared outputs。这个已知缺口仍未验收；post-exit bound 不作为执行期
磁盘硬配额或完整压缩输入资源治理的证据。先前编译/成员检查失败的终止探针根已验证所有权后删除。

## 本轮验证

```sh
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
sh scripts/run-swiftpm.sh test --filter MigrationCacheMetadataTests
python3 scripts/test_macos_parser_process.py
git diff --check
```

稳定 caches 在 `/private/tmp/arktrace-migration-cargo` 和 `/private/tmp/arktrace-migration-swiftpm`。
SwiftPM manifest 使用已授权的 sandbox 外编译，没有改变 Xcode pin。

Rust **113 passed / 0 failed / 0 ignored**（Store 30、Engine codec 4），无 warnings。新增 Native
ephemeral lease 的 fresh/exclusion/unlink/replacement 和 exact membership 回归通过。
clippy/fmt、5-crate dependency/unsafe/32-license verifier、34 Machine fixtures/57 scopes/24 indexes/
13 metadata fields、runner 9 tests、CI planner 29 cases 通过。Swift 新增 **2 passed / 0 failed /
0 skipped**，无 warnings；实际 Swift 解码/ISO 8601 重编码后 JSON 与 Rust codec fixture 相等，
unknown 根/嵌套字段仍拒绝。

| 实际 fixture | readonly Ready DB bytes | durationNs | 验证 |
|---|---:|---:|---|
| zlib.htrace | 2351104 | 32210627000 | 24 indexes、metadata、T0 inspection |
| hiprofiler_data_ability.htrace | 2072576 | 48516841334 | 同上 |
| trace_small_10.systrace | 19734528 | 9127944000 | 同上 |

Engine inspection 与先前 Rust Store inspection 相等；后者与冻结 Swift oracle 的 fingerprint/
capabilities/duration/全部 quality facts canonical subset T0 相等。独立 Python 验证实际
0400、SHA/bytes、quick_check、DELETE、24 indexes 和 metadata 文件。两个同源 session 同时
存活，关闭一个后另一个仍可验证；关闭后 owned Ready/owner/ephemeral lease 均无残留。

十个真实负例：source snapshot、parse、index、publish、发布后 validation 五处取消；发布后
monotonic deadline 耗尽；DB chmod 可写；Ready 被外来目录替换；DB 输出预算 1 byte；parser
实际版本与声明不符。全部未返回 Ready。替换场景按 dev/inode 找回并清理被移动的自有目录，
外来 bytes 原样保留；探针随后清理自己注入的 fixture。所有场景验证 owned transient/Ready/
ephemeral lease 清理与原始 trace 不变。

原有 parser 两项输出 budget 负例、5 个 stale staging owners 回收、3 个 published probe owners
保留继续通过。原 parser bytes 不变，完整探针私有根删除。`engineNoCacheReadyPublication=true`
只证明上述 Engine 子项，报告仍为 `readyAcceptance=false`，不是 macOS 产品验收通过。

## 剩余范围

scratch live-growth/aggregate 监督，stale Ready crash recovery/完整故障窗口，persistent cache
hits/shared leases/LRU/维护互操作，产品 progress/error 投影、typed Store queries、CLI/Swift
SDK/App/ArkDeck、正式签名/沙箱/Capture/分发、medium/large SLO、切换/回滚与 Swift 清退。
signed-bundle-in-place parser 路径也未完成。

未重跑 Swift 全套、App/API、APFS 或 hosted CI。本轮 Swift 只新增 codec tests，上一轮完整
Swift/API 基线是历史证据。生产 Developer ID/notarization、Windows native ports 未通过，
当前发布的 Swift 产品尚未选择新 Engine。Goal 不标 complete。
