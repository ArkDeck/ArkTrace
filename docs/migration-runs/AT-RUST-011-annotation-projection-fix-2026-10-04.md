# AT-RUST-011 annotation projection review correction — 2026-10-04

独立派生 snapshot：`parallel-annotations-review-fix-20261004`；manifest SHA-256 `e460706dfede659b3e56cabb487b292af7df26895e4fdf64174c13da2321fdb9`。858 baseline 中855文件未变，修改仅 annotations.rs 与两份专属 annotation tests；lib、manifest、lock、原交付和 action catalog 均未写入。

## 修复

`AnnotationPersistence` 的 `api_version/flags/marks` 变为私有，包外读 `api_version()`、`flags()`、`marks()`；不返回可变 Vec/String。`retained_bytes()` 按当前 struct、Vec capacity、String capacity 计算，包含保留 mark 子集未使用的 record slots。Clone 不复制容量缓存，序列化保留四个原字段名并输出当前计量。纯 projection 数据和顺序未变。

## 验证

Rust viewer 72 tests + 3 compile-fail doctests passed；4新增回归覆盖filtered-mark spare slots、clone当前容量与序列化、owner替换后projection独立、host同时预算提案。格式、all-targets `-D warnings` clippy、8-crate/35-license workspace verifier通过。实际命令、exit、日志hash见同名JSON。

原Swift 74 cases / 674 actions / 748 states fixture与源码receipts逐项hash一致，原实际Swift成功日志只读复制到本任务缓存；当前Rust重新逐字段比较全部748状态。本次未重跑Swift，不能把继承证据称为新运行。原Swift安全作用域环境消息仍属原报告限制。

## 集成边界

SDK生成方从只读accessors转fixed-width记录与bounded UTF-8。8MiB是每份state/projection上限；host必须合计live state、transaction临时副本、每份projection/clone、encoding和借用排序数组，并在取消/完成后释放。allocator headers不计入。没有App/SDK/FFI/disk/GUI/Windows接通或AT-RUST-011正式验收。
