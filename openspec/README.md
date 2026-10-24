# ArkTrace OpenSpec

> 模型：Living Specs + change packages
> 状态：按当前产品能力从 [SPECIFICATION.md](../docs/design/SPECIFICATION.md) 种入
> 日期：2026-10-22

ArkTrace 使用与 ArkDeck 对齐的 OpenSpec 约定，只保留本仓库需要的三块：

- `project.md`：产品上下文，不是行为条款。
- `specs/<capability>/spec.md`：当前能力的 Living Spec。
- `changes/`：尚未合入的 change package，以及 `archive/`。

约定来自 ArkDeck 的 `openspec/README.md`：稳定 Requirement ID、`SHALL` / `SHALL NOT`、至少一个 Given/When/Then 场景、current spec 不直接当草稿改。本仓库不复制 ArkDeck 的 constitution、Core baseline、Catalog、platform profile 或治理树。机器契约仍在 `api/`，由现有 verifier 检查。

`docs/archive/PHASE_6_SCENARIO.md` 是既有离线验收场景，不是这棵树。

## 目录

```text
openspec/
├── project.md
├── specs/
│   └── <capability>/spec.md
├── changes/
│   ├── README.md
│   └── archive/
└── templates/change/
```

## 能力

| Capability | 细则 |
| --- | --- |
| [product-boundaries](specs/product-boundaries/spec.md) | SPECIFICATION §3、§19 |
| [time-and-identity](specs/time-and-identity/spec.md) | SPECIFICATION §4 |
| [parser](specs/parser/spec.md) | SPECIFICATION §5 |
| [trace-store](specs/trace-store/spec.md) | SPECIFICATION §6、§16 |
| [query](specs/query/spec.md) | SPECIFICATION §8 |
| [timeline](specs/timeline/spec.md) | SPECIFICATION §9 |
| [analysis](specs/analysis/spec.md) | SPECIFICATION §10、§11 |
| [cli](specs/cli/spec.md) | SPECIFICATION §12、§13、§19 |
| [viewer](specs/viewer/spec.md) | SPECIFICATION §14 |
| [capture](specs/capture/spec.md) | SPECIFICATION §3、[CAPTURE.md](../docs/design/CAPTURE.md) |
| [arkdeck-integration](specs/arkdeck-integration/spec.md) | SPECIFICATION §18 |

每条 Requirement 用 `细则：AT-…` 指向 SPECIFICATION 的既有编号。Living spec 写可观察行为；AT-* 正文仍是细则。两者冲突时先定位差异，不能为了让实现通过而放宽任一方。把已批准的 delta 合入 current spec 时，同步改正文。

## 需求格式

```markdown
### Requirement: REQ-PARSE-002 Pinned parser identity

细则：AT-PARSE-002。

WHEN a parse runs, THE SYSTEM SHALL record the pinned parser identity,
AND machine output SHALL NOT include the executable absolute path.

#### Scenario: AC-PARSE-002-01 Machine output hides the path

- GIVEN a successful parse
- WHEN the machine result is encoded
- THEN the result records the parser hash and version
- AND the absolute executable path is absent
```

每个独立规范子句都应有场景覆盖。模糊词不能当验收条件。ID 不复用。

## 状态

```text
Spec:   draft → review → accepted → superseded | retired
Change: proposed → approved → implementing → verified → archived
        └→ rejected
```

`accepted` 表示该条款是当前产品目标行为。它不代替测试、真机或发布证据。
