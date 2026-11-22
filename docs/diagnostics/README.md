---
type: Index
title: rill diagnostic codes
description: >
  Every RILL_* code raised by rill, rill_flutter and rill_test, one page each: cause, trigger,
  fix and the spec rules involved; plus where names, sites and causal records come from.
when: An error or diagnostic mentions a RILL_* code, or a new code is added.
timestamp: 2026-11-20
---

# rill 诊断代码

每个 `RILL_*` 代码一页。`dart run tool/diagnostics.dart`（`tool/check.sh` 调用）检查代码里出现的每个代码都有一页、
每一页都对应代码里仍存在的代码，并检查每页的 frontmatter 与章节。新增代码时同时加页并登记到下表。

| 代码 | 级别 | 包 | 一句话 |
| --- | --- | --- | --- |
| [RILL_CLOSED_PUBLICATION](RILL_CLOSED_PUBLICATION.md) | error | `rill` | 暂存函数返回之后仍调用了 `Tx` 句柄，或 body 已结束的任务句柄仍调用 `publish`：暂存或发布权已经结束。 |
| [RILL_COLD_QUERY_READ](RILL_COLD_QUERY_READ.md) | info | `rill` | 在观察者之外读了一个从未开工的查询的 `.value`：查询只在被观察时工作，读取得到的是当前状态。 |
| [RILL_CYCLE](RILL_CYCLE.md) | error | `rill` | 一个 computed 在求值时（直接或经由其它 computed）读到了它自己。 |
| [RILL_DISPOSED](RILL_DISPOSED.md) | error | `rill` | 对已销毁的 Scope 登记子 Scope、effect、Slot、`onDispose`，或把它作查询的 `keepAlive` 租约。 |
| [RILL_DROPPED_EVENT](RILL_DROPPED_EVENT.md) | warning | `rill` | `Events(hold: true)` 在没有监听者期间积压的事件超过 `holdLimit`，最旧的一条被丢弃。 |
| [RILL_EMPTY_QUERY](RILL_EMPTY_QUERY.md) | error | `rill` | `computedStream` 的流在发出任何值之前就结束了，这个问题没有答案。 |
| [RILL_INFINITE_LOOP](RILL_INFINITE_LOOP.md) | error | `rill` | 一次刷新超过 100 轮仍未稳定：effect 的 apply 不断写入会再次唤醒自己的值。 |
| [RILL_INVALID_SUBSCRIBER](RILL_INVALID_SUBSCRIBER.md) | error | `rill` | 绑定层对一个已释放或正在追踪中的订阅者调用了 `track`。 |
| [RILL_LATE_WRITE](RILL_LATE_WRITE.md) | warning | `rill` | 任务已被作废（被取代、所有者销毁）后，它的 Zone 里仍然发生了裸写入。 |
| [RILL_NO_VALUE](RILL_NO_VALUE.md) | error | `rill` | `AsyncState.requireValue` 读到了 `AsyncLoading`：门控与叶子的前提被打破。 |
| [RILL_OPEN_REFRESH_BOUNDARY](RILL_OPEN_REFRESH_BOUNDARY.md) | error | `rill_test` | `wakes()` 在一个打开的刷新边界（batch、flush 或求值）里被调用，无法观察完整的一次刷新。 |
| [RILL_READ_AFTER_AWAIT](RILL_READ_AFTER_AWAIT.md) | warning | `rill` | 查询在第一个 await 之后（或 `computedStream` 的 `async*` 体里）读取或 `q.wait`；这次读取不会成为依赖。 |
| [RILL_REBUILD](RILL_REBUILD.md) | info | `rill_flutter` | 一个响应式 Element 确认依赖变化并标脏；载荷是 `写入 → 经过的 computed → reader` 路径。 |
| [RILL_UNTRACKED_READ](RILL_UNTRACKED_READ.md) | error | `rill_flutter` | 在帧阶段（build / layout / paint）读了 `.value`，但没有读者追踪它：值变化时界面不会更新。 |
| [RILL_WIDGET_INPUT_ESCAPED](RILL_WIDGET_INPUT_ESCAPED.md) | error | `rill_flutter` | WidgetInput 离开了它的属主：在属主子树之外被读，或在属主的 `didUpdateWidget` / `didChangeDependencies` 之外被 `sync`。 |
| [RILL_WRITE_DURING_FRAME](RILL_WRITE_DURING_FRAME.md) | error | `rill_flutter` | build、layout 或 paint 期间写入了 signal。 |
| [RILL_WRITE_IN_COMPUTATION](RILL_WRITE_IN_COMPUTATION.md) | error | `rill` | computed、effect 的 compute 或提交的暂存函数运行期间写入了 signal（或发起了提交、让查询到期、启动了任务）。 |

## 消息里的名字与位置（D1）

debug 下每个节点（signal、computed、effect、AsyncComputed、Scope、Slot、Task）创建时取一次 `StackTrace.current`，
在需要时解析出第一个不属于 `package:rill*`、SDK 与 Flutter 框架的帧。消息里有名字的节点写成 `count (signal at lib/store.dart:42)`，
未命名的写成 `signal@lib/store.dart:42`；Slot 的 busy、AsyncComputed 的问题节点等内部节点按所有者命名（`sweep.busy`、`user.question`、`user.retry`、`user.landed`、`user.answer`、`sweep.task`）。
Flutter 观察者按它的 reader（Element 或 painter）命名。release 下不取栈，消息退回名字或 `<unnamed kind>`。

## 级别与通道

- **error**：抛 `StateError` / `FlutterError`，或成为 AsyncComputed 的错误状态。
- **warning / info**：设置了 `package:rill/internal.dart` 的 `diagnosticHook(code, label)` 时只交给 hook。
  未设置时，核心包（`package:rill`）在 debug 下按代码与调用位置去重，经 `Zone.current.print` 输出一次，
  格式为 `RILL_X at <调用位置>: <节点> <原因与修法> (rill docs/diagnostics/RILL_X.md)`；`RillDebug.clear()` 重置去重。
  `rill_flutter` 的 warning 未设置 hook 时 `debugPrint`。release 下都不执行。

## 为什么重建 / 谁写的 / 什么还在跑

- `package:rill/debug.dart`：`RillDebug.why(target)` / `lastWhy(target)` 返回最近的 effect 重跑、Element 重建、查询重问及其因果链；
  `RillDebug.describe(node)` 给出名字与创建位置；`graph()` 与 `active()` 是 VM service 扩展的同一份数据。
- `package:rill_test`：`recordWhy(during)`、`causedBy(source, via: [...])`、`tester.whyRebuilt(finder, during: ...)`。
- VM service：`ext.rill.graph`、`ext.rill.why`、`ext.rill.active`，结构见 [vm-service.md](vm-service.md)。
