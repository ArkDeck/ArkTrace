# AT-RUST-007：共享 Viewer search

本轮完成现有搜索组合逻辑的 Rust 迁移，接入同一 immutable Ready/NoCacheSession。
007 与 macOS 完整验收保持 In Progress。同名 JSON 保存当前源身份、完整输出、
实际调用序列、工具链、日志和保留的运行产物；没有覆盖此前 immutable 记录。

## 实现与边界

Contract 保存 text、limit、domains 与完整 SearchResults。请求 text 为 1...256
UTF-8 bytes、limit 为 1...1,000；deadline/cancellation 来自请求预算，Engine 将
search deadline 限制在最多 30 秒。可识别的 domain 位沿用 Swift OptionSet：
process=1、thread=2、slice=4；Toolbar 为 6。原有非零未知位与 signed OptionSet
行为保留；这些位未选择的目录不会被查询。

Analysis 的 `SearchRepository` 只接受既有 typed process/thread/slice query，没有
SQL、DB path 或文件 IO。NoCacheSession adapter 复用 raw query 的 held snapshot、
metadata、entry lease、预算及 connection progress handler，完成时再次检查 session。
Store 取消在共享搜索边界映射到 analyzing cancellation；查询本身的失败保留来源。

每个 name、numeric PID/TID 或 `ipid:`/`itid:` source query 只取 limit+1；按内部身份
first-seen 合并，保留任一 source 的 truncated。明确 identity 会修剪 Foundation 的
whitespace/newline（含 U+200B），普通名称与数字查询继续使用原始 text，不能把
`" 42"` 悄悄解释成 PID。实际 Swift 对照包含大小写、signed Int64 两端、超界数值、
Unicode、U+200B/U+FEFF、256/257-byte 界限、字面 `%_\` 与引号。

最终排序为 process/thread/slice，再按标题的 UTF-8 bytes、process/thread/EventKey
排序；缺失身份先于已定义身份，合法 Int64.min 不作缺失哨兵。标题、subtitle、生命周期、可选字段
编码省略、真实 slice range/EventKey 均保持 Swift。结果仍只有 items/truncated，
没有自行发明质量字段。纯组合过程检查 source 行预算及 unavailable 证据；合并、
投影和稳定排序可取消，取消不会返回部分结果。

## 验证

实际工具链继续为 Rust/Cargo 1.99.0、Xcode 27.0 (27A266a)、Swift 6.4、macOS 27
arm64；部署下限保持 26。固定 parser 身份及三份 small 原始文件 SHA 未变。

| 检查 | 结果 |
| --- | --- |
| 独立实际 Swift controlled oracle | 3 个 DB、138 请求：123 结果、15 closed INVALID_ARGUMENT；35 非空结果；570 次实际 typed source 调用及完整结果逐一匹配 |
| domain 排除 | 逐一核对实际 source 调用顺序及全部 typed 参数，Toolbar 不发 process 查询；unknown-only domain 仅 metadata；非零 signed 位保持既有行为 |
| 真实 parser/Ready | 67 个完整 SearchResults T0；三份均有 process/thread 正向，zlib 有 named slice 正向；实际非空搜索 13/15/15 次 |
| 失败隔离 | 21 个 cancel/deadline/DB budget/limit/domain/text 检查及失败后下一请求一致；显式 close 清空自有 Ready、owner、lease；raw/parser 字节未变 |
| Rust | 全 workspace/all targets/all features 256 passed、0 failed/ignored/warnings；7 个新增 contract/组合回归；fmt 与 clippy -D warnings 通过 |
| Swift/App | 3 个 search 回归通过；正常本机全量 604 tests：598 passed、6 既有 opt-in skipped、0 failed/warnings；Xcode App build/document types 通过，0 项项目源警告、3 项工具诊断 |
| 契约与 CI | 当前 62 frame/raw/Agent、84 argument、138 search 与 33 analysis oracle 来源检查通过；34 Machine fixtures/60 scopes/24 indexes/13 Ready fields 不变；planner 40 cases；完整 dirty diff 选五车道 |

Controlled oracle 调用实际 Swift `TraceViewerSearchEngine` 和
`SQLiteTraceRepository`，wrapper 只记录调用与返回。纯 Rust 回归重放这些真实源页，
同时严格检查每次请求的 typed 参数和顺序；它不是受控 DB 的第二个 Rust Store
执行器。真实 Native 对照则由 Rust 原生 Store/Engine 与实际 Swift 在同一 held Ready
DB 上执行，因此能覆盖实际 Rust 查询、预算和 cleanup。

真实正向 case 从最多 16 项的目录/slice seed 发现，保留 seed 的截断事实。
这不是全 corpus 枚举或性能统计。运行后将实际执行的 helper、Rust probe 和 Swift
oracle 复制到独立 0500 产物，保存其 SHA；后续 Cargo build 可改变顶层缓存输出，
不会把新二进制身份归给旧运行。开发 trust、unsigned 候选不构成生产签名通过。

新 native example 首次构建的错误为 `ContractError` 不实现 `std::error::Error`；
测试 harness 改用静态错误映射后全 workspace/clippy/native 通过。保留失败日志。

排序极值回归证明原 Swift 把 nil 与 Int64.min 当作相同 sentinel，三项输入返回
`[10,20,30]`；明确 optional 身份排序后为 `[20,30,10]`。真实受控 DB 的
`search-full/search/45` 在两端修复前为 `[51,50]`、修复后为 `[50,51]`；
138 个同输入结果仅这一项改变，570 个 source 调用完全不变。before-fix 输出及
两端失败回归保留。公开 Swift API、parser/schema/index/metadata 版本未变。

Swift 搜索回归、全量测试及受影响 App 构建随这一私有排序修复执行；
Windows/hosted CI、medium/large 语料、
新性能、正式签名、真机/Capture 验收没有执行。
三项 App 工具诊断为 Analysis/AppSupport 的 SDK `_LIBCPP_HARDENING_MODE`
conditional-compilation 提示与 AppIntents metadata extraction 提示。
当前 App 仍是 Swift/debug 消费方，strict codesign 验证因缺失资源封套退出 1；
它不构成 Rust SDK 接入或正式签名通过。没有公开 Swift API/依赖边修改，未重复
包外 API baseline；上轮 API baseline 是其当时源码/产物的记录。

## 剩余范围

详情、邻接导航、density、read pool、persistent Session/cache/annotations、完整
summary/context/analysis/CLI、Viewer、ABI/Swift SDK、macOS App 切换、Capture、
分发、ArkDeck、故障/性能、切换/回滚及 Swift 清退尚未完成。
Sidebar 的 `name [pid]` 可见行过滤和真实 GUI 搜索→跳转/高亮仍待 Viewer/App 接入。
goal 保持 active，不能以这一搜索切片宣布 macOS 端验收完成。

复现：先 `python3 rust/crates/arktrace-store/oracle/run_search_oracle.py`，再设置
仓库外 `ARKTRACE_CARGO_CACHE_ROOT` 执行 `python3 scripts/test_macos_search.py`。
