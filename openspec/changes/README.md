# Change Package Workflow

Current specs 不直接当草稿改。改变可观察行为时，先在本目录提交 change package，经维护者 review 的 PR 合并后，再把批准的 delta 合入 `openspec/specs/` 和 SPECIFICATION 的对应 AT-* 条文。

ArkTrace 没有单独的 Core baseline 文件。当前行为就是已接受的 living spec 加上 `docs/design/SPECIFICATION.md`。不复制 ArkDeck 的 baseline 或 Catalog 治理。

## 命名与状态

```text
folder: chg-yyyy-nnn-short-name
display ID: CHG-YYYY-NNN
proposed → approved → implementing → verified → archived
        └→ rejected
```

- 状态写在 `proposal.md` front matter 的 `status:`。维护者合并修改该字段的 PR，即构成这次状态转换的批准。
- `approved`：范围、delta 和验证计划已被认可，可以开始实现。
- `verified`：`verification.md` 里适用的验收都有可复查证据，且维护者在 PR 中确认。
- `archived`：delta 已合入 current specs，目录移入 `changes/archive/YYYY-MM-DD-<id>/`。已归档的 change 不改写。

## 必需 artifacts

```text
openspec/changes/<change-id>/
├── proposal.md
├── tasks.md
├── verification.md
└── evidence/
```

按需增加：

```text
├── design.md
├── specs/<capability>/spec.md    # ADDED / MODIFIED / REMOVED / RENAMED
└── spec-impact.md                # 不改变行为时用来说明没有 delta
```

模板在 `openspec/templates/change/`。目录名用小写 kebab-case。审计 ID 写在 proposal front matter。

## Change classes

- `core`：改变 AT-* 规范句、安全不变量，或 `api/` 里的机器契约。
- `capability`：在既有边界内新增用户可观察能力。
- `integration`：ArkDeck、FFI 或下游消费边界。不得放宽本仓库的 host-only 规则。
- `platform`：macOS App 或 Windows CLI 的工程、权限、打包。不得改验收条件的 pass/fail。
- `implementation-only`：不改变可观察行为和 pass/fail 的重构、测试或基础设施。

## Delta 格式

```text
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

- MODIFIED 必须给出该 Requirement 的完整新文本和全部既有 Scenario ID。可以新增 Scenario。
- REMOVED 和 RENAMED 要在 proposal 里说明迁移。ID 不复用。
- 行为变更同时说明受影响的 AT-* 编号。合入时 living spec 与 SPECIFICATION 一起改。

## Archive

change 达到 verified 之后，用一个 archive PR：

1. 按批准的 delta 更新 `openspec/specs/**` 和 SPECIFICATION 的对应条文。
2. 把 change 目录移到 `changes/archive/YYYY-MM-DD-<id>/`。
3. 维护者 review 该 PR，确认 delta 与 spec 改动一致。

Current specs 只保留“系统现在应如何行为”。proposal、tasks 和 evidence 留在 archive 里说明“为什么改变”。
