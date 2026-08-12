# Trace Fixtures

| 文件 | 来源 | SHA-256 |
|---|---|---|
| `hiprofiler_data_ability.htrace` | [openharmony/developtools_smartperf_host](https://gitcode.com/openharmony/developtools_smartperf_host) @ `447a0a49`，路径 `smartperf_host/trace_streamer/test/resource/hiprofiler_data_ability.htrace` | `226842aa4456050d86578e38e649f1a51a4d51b992e42128e3dcd40edeb5333b` |
| `trace_small_10.systrace` | 同一仓库与 revision，路径 `smartperf_host/trace_streamer/test/resource/trace_small_10.systrace`，Git blob `0c9acff0ca12c3501d4a4235a6dc4efbd95475d4` | `350c9fa59e887a41dab0fc3078d81688aabbb72e3a7e3ea671b620e57a76caef` |
| `zlib.htrace` | 同一仓库与 revision，路径 `smartperf_host/trace_streamer/test/resource/zlib.htrace`，Git blob `42775ede9bc79cea920760e8f6e3904b86fb711d` | `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe` |

来源仓库根 `LICENSE` 在 pinned revision 为 Apache License 2.0，许可证原文随 fixture 保存为 `LICENSE.Apache-2.0.txt`；本目录 trace 保持上游原始字节，仅用于 ArkTrace 测试（SPEC §21.3、项目书 §44）。生成数据库的锁定 hash、range、row counts 与 schema fingerprint 见 `Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json`。
