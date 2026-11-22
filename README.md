---
type: Index
title: rill
description: >
  Dart/Flutter reactive foundation: an alien-signals core port plus a Solid-2-style async and
  task model with explicit publication rights. Entry point for the packages, the docs and the
  verification gate.
timestamp: 2026-11-19
---

# rill

rill 是 Dart/Flutter 的响应式底座。图核心移植 alien-signals（MIT），包括同步 flush，冷 computed 不持有上游边。异步与命令语义取自 Solid 2.0：拆分的 effect、owner、可被取代的异步派生。异步结果的写回由 Slot 的任务存活与调用点写下的前置条件（`Unchanged`）判定，提交两段式、全有或全无。Flutter 绑定会把漏掉的依赖变成错误，等值的派生值不唤醒任何读者。

| 包 | 内容 |
| --- | --- |
| [`packages/rill`](packages/rill/README.md) | 纯 Dart 核心：signal / computed / effect / batch / untracked、Scope（作用的显式所有者）、查询、命令（Slot / Task / `transact` / `Unchanged`）、Events、诊断；核心外的 `package:rill/wire.dart`（`Wire`，按线上形态去重） |
| `packages/rill_flutter` | Element / RenderObject 观察者、帧阶段读写守卫、Reactive* 组件、ReactivePaint、ReactiveTransform / ReactiveOpacity、Pulse、ReactiveState（watch、input）、桥 |
| `packages/rill_test` | 重建预算、唤醒计数、空闲断言（含在途查询、流订阅、查询 Timer）、按 runApp 挂载（`mountApp`）、帧泵、可控异步源 |
| `packages/rill_lint` | `analysis_server_plugin` 规则与 quick fix，带金丝雀 fixture |

## 文档

- API 与用法：各包的 README（从 [`packages/rill`](packages/rill/README.md) 开始）。
- 迁移指南：[`docs/migration.md`](docs/migration.md)，从 v0.2.1 起每个不兼容改动的写法对照、已知限制与非目标。
- 诊断码：[`docs/diagnostics/`](docs/diagnostics/README.md) 中每个 `RILL_*` 一页。
- lint 规则：[`docs/lint.md`](docs/lint.md)，含 `rill_write_after_await` 不跟进 Timer 回调的理由。
- 验证记录：[一致性登记](docs/conformance.md)、[变异测试](docs/mutation.md)、[基准报告](docs/bench.md)。

## 使用

按 git 引用，`ref` 填发布 tag 对应的**完整 commit SHA**，同时注释写上 tag 名：

```yaml
dependencies:
  rill:
    git: {url: https://github.com/celados/rill.git, path: packages/rill, ref: <sha>} # vX.Y.Z
  rill_flutter:
    git: {url: https://github.com/celados/rill.git, path: packages/rill_flutter, ref: <sha>} # vX.Y.Z
dev_dependencies:
  rill_test:
    git: {url: https://github.com/celados/rill.git, path: packages/rill_test, ref: <sha>} # vX.Y.Z
```

`<sha>` 用 `git ls-remote https://github.com/celados/rill.git 'refs/tags/vX.Y.Z^{}'` 取。不能直接写 `ref: vX.Y.Z`，原因是：

- 包之间用 `path:` 互相依赖，例如 `rill_flutter → ../rill`。pub 把 git 包里的相对 path 依赖解析成「同一仓库、`ref` 为解析出的 commit SHA」。
- pub 按字面比较 `ref`。使用方写 `ref: vX.Y.Z`，传递依赖是 `ref: <sha>`，两者会冲突，版本求解失败。

lint 插件写在 `analysis_options.yaml`，analyzer 支持 git 源，填同一个 SHA：

```yaml
plugins:
  rill_lint:
    git: {url: https://github.com/celados/rill.git, path: packages/rill_lint, ref: <sha>} # vX.Y.Z
    diagnostics:
      rill_write_after_await: error
```

**门禁里要证明插件真的在跑**：analyzer 在某些布局下会静默丢掉插件，不报错、不提示（见
[docs/lint.md#插件静默](docs/lint.md#插件静默)），所以 "analyze 通过" 本身不说明规则生效。在包根运行
`dart run rill_test:lint_canary`：它往 `lib/` 临时放一个违规文件、按门禁的方式分析整个包，插件没报就失败。
插件的 ignore 要带命名空间：`// ignore: rill_lint/rill_write_in_build`。

组件库测根部挂载的组件（toast 区域、全局 overlay 之类）时用 `await tester.mountApp(app)`（rill_test），不要只用 `pumpWidget`：
`pumpWidget` 在帧回调里 build，而 runApp 的首个 build 同步发生在帧外、调度相位为 idle，两者对"首个 build 里发生了什么"给出不同的答案。
生命周期里建 effect 用 `ReactiveState.watch`（首个 apply 在帧后），固定输入用 `Readable.constant`，会随 widget 配置变化的输入用 `ReactiveState.input`（`didUpdateWidget` 里 `sync`，子树同帧更新）。

四个包的 `version` 保持一致。发布时先改版本，再打对应的 `vX.Y.Z` tag。

## 门禁

使用 Flutter stable 自带的 Dart（当前为 Flutter 3.50 / Dart 3.14）。在仓库根运行：

```sh
tool/check.sh             # 完整门禁，含 AOT 基准
tool/check.sh --no-bench  # 日常迭代与 CI：跳过计时
tool/bench.sh             # 只跑基准，更新 docs/bench.md
```

`check.sh` 依次执行以下检查：

1. 校验锁文件。
2. 跑 lint 金丝雀，确认每条规则都报错。
3. 检查格式和诊断文档。
4. 运行 `dart analyze --fatal-infos`。
5. 运行核心、lint、conformance、bench 统计、feed_store 示例和 Flutter 绑定测试。
6. 运行变异测试。
7. 不加 `--no-bench` 时，最后跑基准门禁。

CI（`.github/workflows/ci.yml`）在每次 push 和每周一次时安装**最新** Flutter stable，然后跑 `tool/check.sh --no-bench`。它跟随上游，不钉版本。基准只在本机跑，因为共享 runner 的计时噪声会让性能门禁失去意义。改动热路径时，本机跑 `tool/check.sh` 或 `tool/bench.sh --gate`。

完整 Dart 审计还会运行对照库已登记的失败：

```sh
(cd conformance && dart --enable-asserts run tool/observe.dart)
(cd conformance && dart run tool/fuzz.dart 42 1000)
(cd conformance && dart run tool/fuzz.dart --replay /path/to/sequence.json)
```

Fuzz 在每一步用简单拓扑遍历重算整张图，再对照显式读取和 effect 实际读到的值。它检查 effect 首跑、可见值变化和 dispose，允许等值写入的触发次数不同。失败时输出种子、操作位置，以及可直接重放的最小化 JSON 序列。对 rill，每一步还检查双向链表、悬挂边、已销毁节点和冷 computed。变异测试在临时工作区里确认核心判断确实有测试覆盖。

JS 基线命令接收两个源码目录，分别指向登记表中的 rft 和 alien-signals 提交：

```sh
bun conformance/tool/js_baseline.ts /path/to/rft /path/to/alien-signals
```

`bench.sh` 把结果写到 `.out/bench.json`，同时更新 `docs/bench.md`。`tool/bench.sh --smoke` 缩短计时，JSON 写到 `.out/bench-smoke.json`。

## 布局

```text
packages/            四个包
conformance/         rft 移植（逐条登记）、Solid 派生用例、参考模型、差分 fuzz
bench/               AOT 基准，对照 alien_signals 与 signals_core
examples/feed_store/ 示例 store：载入一轮 sweep 与可选的快照部分，作为端到端场景
baseline_signals/    signals.dart 对照基线（独立包，不在 workspace 内）
tool/                check.sh、bench.sh、mutate.dart、diagnostics.dart
docs/                迁移指南、诊断码、lint、验证记录
```
