# AT-RUST-006/013：只读进程采样工具接入

2026-10-06，基线 `4c901b1`；Rust 1.99.0、Xcode 27.0、Swift 6.4。已审查 A41R1 的 Python、C bridge 和必要 README 三个源文件原字节接入 `scripts/native-process-forest/`，没有导入候选二进制或改变生产模块、ABI、SDK。当前 Clang 按 macOS 26+ / arm64 独立编译 bridge，SHA `731187d0…a19dda`；当前 SDK 四个 libproc/进程头文件完整 hash 已登记。ABI getter、AST 和 CLI help 实际通过，未执行 PID/进程枚举/RSS 查询。

本增量八项实际命令结束 exit 0：编译、ABI、help、许可证、parser lock、CI planner contract，以及对本轮已改变 facts receipt 的 migration verifier 和编码回归。其余十项离线契约复用既有实际原始命令证据；688 项编译相关源码和 1,125 项 tracked 检查输入读回，除已实际重新生成并验证的 facts receipt 外没有相关源码变化。两个许可证物理 CRLF 与 Git LF 差异按实际 `.gitattributes` 分别记录；最初预检假设失败保留，未改文件或放宽产品检查。

原 A41 一次受控进程树和三组 synthetic 决策测试仅作为明确标注的历史工具证据复用；A41R1 与本次集成均没有新增功能采样组。73,891,840-byte RSS 是已识别 live 集合的采样下界，不能证明完整进程树、当前产品峰值、p95 或取消验收。实际产品测量须另行绑定当前 App/helper/parser/SDK、源文件、工具、精确 PID/内核 start identity 和独立 open/cancel 单调时钟事件。编译后的本地工具位于本次 owner 的 ignored `build/agent-tools/`，Git 保留源文件。

完整 diff 的 CI planner 选择 SwiftPM、contracts、Rust macOS 和 Rust Windows，App 不选；这是车道选择。当前完整 default/native 测试仍保留原窗口失败，native 另有一次 SQLite14，根因未证明；既有 Rust 577、正常 API/App 等通过记录明确复用，没有声称重新全量通过。没有新增 skip、修改断言或提高预算。独立正常 Ready 缓存继续由 N34R2 独占，MAIN 未访问。

八项命令、原始 stdout/stderr、输入和历史 gate 复用声明收录在本记录 JSON 与独立只读证据 packet。真实 GUI、进程采样/性能/取消、范围恢复、设备、ArkDeck 和适用分发验收仍未完成；整个 macOS goal 仍 blocked。
