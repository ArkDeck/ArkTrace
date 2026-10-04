# AT-RUST-011 parallel Inspector projection — 2026-10-04

完整Inspector共享纯投影已验证，production wire/SDK/App接线待main；不声明AT-RUST-011/012/013或macOS验收。

## 精确范围

870-file snapshot `ff496514f20d728a8e1f62d62552ae9c38912388`，manifest SHA-256 `97797d83b0b0be04112bc51eb405f9f6bdeade6de83179f88cac358944169213`。869 baseline未改，lib仅追加mod/pub-use；移除该hunk后全部870原字节一致。owned新文件清单/hash在同名JSON和sha256。主工作树、既有目录/配色/标注/projection修正、manifest/lock/CI/Swift生产源未写入。

## API和语义

`project_inspectors(version, borrowed DTO inputs, budget, check)` 返回私有buffer的immutable `InspectorProjectionBatch`，只读strings/records/text/accessors；facts覆盖key/kind/name/range/semanticDurationNs/isOpenEnded/isInstant/processKey/threadKey/pid/tid/cpu/processName/threadName/category/state/value/unit/priority。字符串是nullable index，nil/empty不同；isInstant由semantic duration和open-ended计算。PID/TID不替代ipid/itid，EventKey保留table+rowID。

CPU priority完整保留，其它kind为nil。Thread normalizedState=nil时Inspector category=nil，不能使用primitive的unknown显示fallback。Frame name/state调用既有frame_label/jank_state_text。Counter正duration range保留timestamp+duration，可能超出viewport；nil duration才用max(timestamp,queryEnd)，不改变semanticDuration。Density显式None，不伪造Inspector或EventKey。

4096 rows、每文本4096 UTF-8 bytes、4MiB输入文本、4MiB retained string capacity、8MiB每输出。retained getter计算当前struct、Vec spare capacity、String capacity，Clone重新计自己的capacity。私有buffers/read-onlyslice阻止调用方扩容。字符串index BTreeMap节点是临时scratch，key文本最终move到输出，node/allocator overhead、输入DTO、其它模块output、每份clone及encoding必须由host aggregate预算。大native snapshot需要owner-admitted chunks，不能静默截断。

## 实际验证

实际Swift loader private-call wrapper，没有复制Inspector构造switch。362 cases / 393 positions，其中392份detail均逐字段比较19项facts，1份density为无detail。覆盖CPU priority/Int64极值、nullable identity/text、instant/open/duration、frame expected/actual+vsync/jank、CPU/process counters、viewport边界、Unicode/空值/NUL与重复文本。source/seam/input/output/log hash及命令exit在JSON。

81 Rust viewer tests（9新增）+2 compile-fail doctests；Swift实际oracle1 + 既有20（Rendering7/Core13）tests；fmt、strict all-targets clippy、8-crate/35-license verifier通过，最终warning/error0。保留三次已解决尝试：oracle标量读取fragmentsAllowed、输入生成器移除未消费且不在已提交DTO decoding中的argSetID（actual输出不变）、clippy测试size_of_val；未放宽gate、未改baseline。

## main交接

只追加lib hunk；SDK生成versioned fixed-width optional scalar/key/kind及bounded UTF-8 descriptor，使用只读getters，不导出Rust布局。接在现有query normalization/dedup/limit/quality之后，counter借用descriptor+sample而不扫描series全量samples；保留session/generation owner的whole-batch发布和取消预算。重放393 canonical positions到实际wire/SDK，验证aggregate/ABI/API，再执行App/native Inspector显示、复制、accessibility、formatting及real-medium-trace证据。当前oracle是实际纯构造方法证据，不能替代Repository/SDK/GUI验收。
