## MODIFIED Requirements

### Requirement: REQ-SYS-002 Shared implementation

细则：AT-SYS-002、AT-SYS-006。

App、CLI 与 ArkDeck 消费方 SHALL 共享 Core、Runtime、Store 与 Analysis。任一产品面 SHALL NOT 另行实现 parser、SQL 语义或 analysis formula。共享模块 SHALL NOT 硬编码消费方的 bundle identity、cache root、preferences key 或 bundle 内 parser 位置；这些值 SHALL 由产品组合根注入，且 SHALL NOT 由一次 trace 请求覆盖。

#### Scenario: AC-SYS-002-01 产品面不复制解析

- GIVEN 同一个 trace 分别由 App 与 CLI 打开
- WHEN 两者都完成解析并查询 summary
- THEN 两者使用同一 parser、schema 与 analysis 实现
- AND 共享模块没有读取某一种产品的 bundle 路径

#### Scenario: AC-SYS-002-02 Native consumer keeps its fixed product identity

- GIVEN a consuming App supplies its fixed product configuration and publisher prefix
- WHEN it starts the shared native runtime from bundled tools
- THEN the runtime validates that publisher and the signed in-place parser before publishing its owner
- AND the standalone product's publisher, storage roots and parser location cannot replace the consumer's configuration

#### Scenario: AC-SYS-002-03 Consumer SDK staging stays outside its source repository

- GIVEN a resolved dependency checkout and a verified matching native SDK
- WHEN the build stages the SDK for a consuming repository
- THEN staging rejects the consuming repository and any directory inside it
- AND an external dependency checkout can reuse the verified content-addressed SDK
