# AT-RUST-011 Windows checkout 身份修复（2026-10-04）

`817b33d` 的 native Windows [CI](https://github.com/ArkDeck/ArkTrace/actions/runs/37184735814)
在新 Viewer facts verifier 校验 `README.md` SHA 时失败，后续 build/native tests 未执行。
Markdown 和两份新冻结 patch 未声明 Git 行尾策略，Windows checkout 转换 CRLF，
使磁盘字节偏离冻结的源身份。

`.gitattributes` 为 Markdown 固定 LF，patch/raw logs 保留原二进制字节。源、oracle、
旧报告和 raw evidence 的内容及 SHA 均不重写。实际 Git `core.autocrlf=true` checkout
复现四处不匹配：两份 README、两份 index logging/export patch；修复后全部 152
source pins 匹配。该复现运行在 macOS，不作为 native Windows 产品通过证据。

新增永久回归实际初始化隔离 Git index、移除工作文件后 checkout，再核对四份
原字节。原 attributes 上同一个新测试实际失败，当前与原 CP1252 全 verifier 共
两项通过；migration verifier 和 CI planner 回归通过，完整四路径 diff 选择全部
五个车道。首次复现未移除文件，Git stat cache 跳过 rewrite，未当成有效 red 证据；
修正的前后结果与失败日志均保留。[机器记录](AT-RUST-011-2026-10-04-checkout-identity.json)
给出实际命令结果、hash 与限制。

修复后需另审计新 head 的 native Windows/macOS CI，既有失败不冒充成功。
本次没有 SDK、App 切换、发行签名或 macOS 整体验收。
