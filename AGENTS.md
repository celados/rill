# rill

先读 [README.md](README.md)。

- **不兼容改动在同一提交里追加 [`docs/migration.md`](docs/migration.md)**（消费方从 v0.2.1 一次迁完）。
- **门禁 = `tool/check.sh`，分三档**（`--help` 看全部开关）。静态检查与各包测试并行执行，日志在 `.dart_tool/check/`，失败的会打印全文；mutant 用 `tool/mutate.dart` 的默认 `--jobs`；基准始终最后单独跑。
  - 迭代和分支交付用 `--quick`：跑全部测试，但只跑本分支改过的库文件的 mutant，不跑基准。
  - CI 跑 `--no-bench` 的等价拆分：一个 job 跑 `--no-mutate`，全部 mutant 用 `tool/mutate.dart --shard` 分到 GitHub 托管 runner（见 `.github/workflows/ci.yml`）。
  - 发版前本机跑一次完整门禁（带基准，基准不进 CI，见 [`docs/bench.md`](docs/bench.md)）；改热路径（`graph.dart`、`runtime.dart`）时也要跑。
- **规格与设计 / 评审记录不在本仓库**，私有存放，位置见本地未入库的 `AGENTS.local.md`。语义变更先改那里的规格，再改实现与测试。
- **每个 conformance 用例都要登记**到 [`docs/conformance.md`](docs/conformance.md)，未登记的用例不算覆盖。

@AGENTS.local.md
