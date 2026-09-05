# ArkTrace Agent Guide

帮助用户完成可验证的 ArkTrace 改动：定位实际问题，复用现有实现，完成必要验证，明确结果与剩余限制。
本文件用于仓库开发；产品 CLI 的使用契约见 [docs/CLI.md](docs/CLI.md)。

## 任务执行

- 结合用户请求和已有上下文确定目标、范围与完成条件。已授权的检查、编辑和验证直接推进；普通实现选择作合理假设，不为每一步重复确认。
- 只有缺失信息会改变产品行为、兼容性、授权或不可逆操作时才提出具体问题；继续完成不依赖答案的工作。需要审批时先准备可审查的结果，并说明阻塞动作与依据。
- 先检查 `git status --short`，保留用户已有改动。用 `rg` 定位相关符号、规格和测试，按需读取；独立只读检查可批量执行，有依赖的操作顺序执行。
- 将实现、相关回归验证和必要文档更新作为同一任务完成。不要把普通修复扩展为重做历史 Phase、全仓审计或流程文档工程。
- 完成条件：请求的行为已实现，适用检查通过，剩余限制明确。失败后根据新证据修复或换可行路径；检查通过且没有新风险时停止扩展验证。

## 事实源与按需阅读

遵循运行环境的指令优先级；在其允许范围内，用户明确请求优先于本地流程建议和 skill。
本文件说明执行方式，[SPECIFICATION.md](docs/SPECIFICATION.md) 定义产品行为，[DESIGN.md](docs/DESIGN.md) 解释架构。
以当前代码、配置和实际检查确认实现状态；发现规格与实现冲突时定位差异，不能仅为让测试通过而放宽需求。

| 涉及的工作 | 首选入口 |
|---|---|
| 平台、模块与依赖 | [Package.swift](Package.swift)、`Sources/`、[SPECIFICATION.md](docs/SPECIFICATION.md) §2–4 |
| Parser、SQLite、cache | `Sources/ArkTraceCore/`、`Sources/ArkTraceParser/`、`Sources/ArkTraceStore/`、`Sources/ArkTraceRuntime/`；[TRACE_STREAMER.md](docs/TRACE_STREAMER.md) |
| 包外消费的离线检查与 cache 维护 | `Sources/ArkTraceAppSupport/TraceOfflineInspectionService.swift`、`Sources/ArkTraceRuntime/TraceCache.swift`；`scripts/api-baseline/` |
| CLI、查询、分析 | `Sources/ArkTraceCLI/`、`Sources/arktrace/`、`Sources/ArkTraceAnalysis/`；[CLI.md](docs/CLI.md) |
| Viewer、交互与本地化 | `Apps/ArkTraceApp/`、`Sources/ArkTraceAppSupport/`、`Sources/ArkTraceRendering/`；DESIGN §13–14 |
| GUI 设备采集 | `Sources/ArkTraceCapture/`、`Apps/ArkTraceApp/Capture/`；[CAPTURE.md](docs/CAPTURE.md) |
| ArkDeck 消费或分发 | [ARKDECK_INTEGRATION.md](docs/ARKDECK_INTEGRATION.md)、[CLI_DISTRIBUTION.md](docs/CLI_DISTRIBUTION.md)、[APP_DISTRIBUTION.md](docs/APP_DISTRIBUTION.md) |
| 构建与 CI | [ci.yml](.github/workflows/ci.yml)、[ci_plan.sh](scripts/ci_plan.sh)、对应 `scripts/` 入口 |

`docs/TASKS.md`、`PHASE_*_TASKS.md`、历史验证报告中的排程、旧 pin 和验收状态属于当时的记录。
按需追溯相关证据；新任务不必重走阶段入口、请求已完成的设计裁决或改写历史 Completed 状态。
历史发布通过不证明当前工作树或新分发已通过；留存的未验证项仍需如实报告。
ArkDeck 是独立仓库，其治理流程不自动适用于 ArkTrace；跨仓库修改需要属于用户任务范围。

## 保持的产品边界

- App、CLI 和 ArkDeck 消费方复用共享实现；依赖方向遵守 SPECIFICATION 的 AT-SYS-002/006。产品差异通过 `TraceProductConfiguration` 注入，避免复制模块或硬编码消费方路径。
- Core、Runtime、CLI 和 ArkDeck analyzer 保持 host-only。仅 GUI 明示的 Capture 流程使用独立 `ArkTraceCapture`；SDK HDC 的发现规则见 CAPTURE，不要套用“整个 ArkTrace 禁止设备访问”的旧描述。
- 原始 Trace 不原地修改，解析和分析不自动上传。生产 parser 使用已验证的固定身份，不从 PATH 选择未知二进制；子进程使用 executable URL 与参数数组。
- 时间使用 trace-relative `Int64` 纳秒和半开区间，保留 instant/open-ended 语义；`ipid`/`itid` 是身份，PID/TID 是属性。
- CLI/API 保持 typed、bounded、deterministic、versioned；不暴露 raw SQL，机器输出和产品错误不泄漏用户绝对路径。维护预算、取消、provenance、session-owned staging 与原子 Ready 的既有契约。
- 共享模块的磁盘 IO、hash、解析和数据库工作保持在 MainActor 外。公开 API 改动考虑包外消费方；parser/schema/index 版本改动核对 ArkDeck 的版本耦合，不凭历史文档猜当前下游状态。

## 构建与验证

当前基线为 macOS 26+、Apple silicon、Swift 6.3 / Swift language mode 6；CI 固定 Xcode 26.6。
以 `Package.swift` 和 workflow 为准，不为通过检查擅自降低平台或工具链要求。
日常迭代使用稳定缓存入口（在仓库根目录执行）：

```sh
sh scripts/run-swiftpm.sh build
sh scripts/run-swiftpm.sh test --filter '<相关测试套件>'
sh scripts/run-xcodebuild.sh
```

按改动选择命令，不要求每次全部运行。runner 管理稳定 source mirror 与缓存；不要给 SwiftPM runner 传它禁止的 `--package-path`、`--scratch-path` 或 `--cache-path`。
受限环境可使用 runner 文档中的 `ARKTRACE_SWIFTPM_CACHE_ROOT` / `ARKTRACE_XCODE_CACHE_ROOT` 指定仓库外可写缓存，或按环境流程申请访问。

| 改动 | 适用验证 |
|---|---|
| 纯文档、Agent 指令 | 检查 diff、路径、链接、指令冲突；通常不编译 Swift |
| 行为修复 | 运行相关既有测试；补能捕获该故障的回归测试，避免只复述实现的断言 |
| 公开 Swift API 或依赖边 | 相关测试 + `sh scripts/test_api_baseline.sh`；影响 App 时再构建 App |
| UI、输入与可访问性 | 相关 AppSupport/Rendering 测试 + App 构建；交互或呈现变化补对应实际检查，说明未验证项 |
| README 快捷键表 | 以 `TraceShortcutCatalog` 为源，同步两种语言，运行 `ShortcutCatalogTests` |
| 配色、license、parser lock、脚本或 CI | 使用对应 verifier/contract tests；检查 CI planner 是否覆盖完整 diff |
| 发布、签名、性能或真实设备验收 | 读取对应分发/Phase 文档，执行其要求的 gate 与真实证据验证 |

最终 CI 车道按完整 diff 由 `scripts/ci_plan.sh` 选择；未知路径或无法确定 diff 时会选择全部车道。
过滤测试用于开发反馈，不替代所选 CI 车道；提交前核对 `.github/workflows/ci.yml` 的适用检查（包括 warning 和 skip 审计）。
TraceStreamer binary 不随 Git 提交。需要真实解析时按 TRACE_STREAMER 构建并校验；不要把整个测试类的失败一概归为缺 parser，CI 仅允许 workflow 明列的排除或 skip。
正式验收缺少必需 binary、fixture、设备或签名证据时，该项未通过；普通任务继续完成可运行检查并报告缺口。单测、模拟结果和离线历史 evidence 校验不能冒充新一轮真机、性能或发布通过。

## Git 与交付

- 本地修改请求本身不要求发布。用户要求提交 PR 时，遵循 [agent-pr.yml](.github/workflows/agent-pr.yml)：推送 `agent/**` 分支，由 GitHub Actions 创建 bot-authored、ready-for-review PR，保留维护者独立 review 路径。
- PR 补充实际改动、原因、验证与未验证项；发布后读回作者、head、标题、正文和 draft 状态，不能把 workflow 的通用占位正文当成完整说明。
- 回复沿用用户语言，先说结果，再说明必要证据或限制。区分已执行、失败、未执行；只有确认完成才声称完成。

## Skill 与指令维护

- 只使用当前任务需要且环境可用的 skill，先读其 `SKILL.md`，按需加载引用；不要求预读全部技能，也不因缺少可选技能停止已有工具能完成的工作。
- 项目专用的重复工作流可放在 `.agents/skills/<name>/SKILL.md`，使用明确的 `name`、`description` 和触发边界。通用规则留在本文件，长参考留在 `docs/`；不复制用户级或插件级 skill，不保留同名重复入口。
- skill 导致暂停或请求确认时，指出准确文件与相关原文，并判断当前用户授权是否已经覆盖；不能把建议解读为新增审批要求。
- 指令保持精简、可验证，不固定模型名称、不复制工具 schema、不加入已完成任务的临时排程。

维护依据：[OpenAI 模型指南](https://developers.openai.com/api/docs/guides/latest-model)、[AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)、[Skills](https://learn.chatgpt.com/docs/build-skills)。
