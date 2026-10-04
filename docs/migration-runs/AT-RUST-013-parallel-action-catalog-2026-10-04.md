# AT-RUST-013 parallel action catalog — 2026-10-04

本交付实现共享语义目录和macOS timeline纯路由，待main接SDK/FFI/App；没有完成AT-RUST-013或macOS验收。

## 内容和边界

870-file snapshot `ff496514f20d728a8e1f62d62552ae9c38912388`，manifest SHA-256 `14cceffe02599e4bb855a06b889b818b02aff47b4b4bec7a4f2cf7b35a7f0ccc`。869 baseline未变；lib仅追加两行mod/export（含前导空行），不得整文件覆盖main。新增源码/测试/fixture/报告均在owned范围。原两个交付、标注review-fix和其它缓存未写入。

29个v1闭集action ID、4个domain、3个section、19个row；旧Swift title/key-markup identity单独保留。Typed input仅normalized key、四个modifier bool、scope、text/IME ownership。constant-work零分配router返回Dispatch或Forward加focus-visible intent，不计算已有handler能否成功。Markdown每表<=16KiB，逐row取消检查，精确保留中文和末尾无换行。

当前Swift physical arrow分支在Command/Control guard之前，Option只改水平箭头为pan；Command字母forward，Ctrl标注cluster和裸方括号selection别名保留。TextInput/IME guard是新共享安全契约，native判断由host提供，不能以纯guard单测声称原生focus等价。SearchResults返回Forward(SearchResultsHost)，其语义/display目录已共享；SwiftUI结果步进/Return焦点和pointer gesture仍由native adapter接通。

## 实际验证

真实Swift目录生成19行、6张双语表；真实NSEvent/keyDown执行664输入，nextResponder实际观察forward，14个直接command调用记录入口并继续执行原handler。只有一行cache-only命令入口probe，无expected routing algorithm副本。Rust逐字段比较这些输出。

Rust viewer 83 tests（11新增）+ 1个compile-fail目录immutability doctest；Swift oracle 2 tests与既有19 tests（Rendering13 + ShortcutCatalog6）；fmt、all-targets strict clippy、8-crate/35-license workspace verifier通过。最终compiler warning/error为0。命令、exit、时间、日志和source/input/output hash在同名JSON，独立cache保存冻结日志。Owned Python 5份/30个text access全部显式UTF-8，非ASCII内容按源码实际bytes生成。

## main接线提案

SDK生成versioned fixed-width action/domain/section/row/key/scope/route字段与bounded UTF-8 offset-length，不导出Rust布局。Host在路由前确定first-responder、text field、marked-text/IME ownership；先识别physical arrows，再lowercase整个charactersIgnoringModifiers，unknown/nil/multichar归Unknown；Forward传回原native event。Dispatch按domain连接已有keyboard/annotation handler，保留state eligibility和accessibility command入口。

Help/README改为generated records消费时保留顺序、legacy IDs、English display keys、localized gesture cells与六张表，继续跑两语言README/Help契约。本snapshot未改README。Search/pointer native行为和Windows键位不凭目录推断。

接线后还需SDK/ABI/API gates、实际adapter同664输入比较、text/IME/menu/window focus、search activation、pointer normalization、accessibility、App build及real medium trace GUI证据。当前合成事件/source-contract测试不替代这些验收。
