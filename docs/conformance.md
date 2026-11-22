---
type: Reference
title: rft conformance baseline
description: Per-ID Dart and JavaScript results for the rft reactive adapter baseline, and the registry of rill's own rule cases.
timestamp: 2026-11-21
---

# rft 一致性登记

同一套 [rft 0.2.0 @ 745e6eb](https://github.com/johnsoncodehk/reactive-framework-test-suite/tree/745e6eb) 在 Bun 1.4.4 和 Dart 3.14.0 上实跑。JS 使用 [alien-signals 3.2.1 @ 8734d38](https://github.com/stackblitz/alien-signals/commit/8734d386d925025d0e99419bd9161c17b112c5ee)，对应 Dart alien_signals 2.4.0 changelog 记录的上游提交。第二个 Dart 对照是 signals_core 7.0.0。

| 被测对象 | 正确性通过 | 失败 | 探针有结果 |
| --- | ---: | ---: | ---: |
| JS alien-signals | 161/161 | 0 | 29/29 |
| Dart alien_signals | 161/161 | 0 | 29/29 |
| Dart signals_core | 158/161 | 3 | 29/29 |
| Dart rill | 136/136 必过 | 0 必过失败 | 29/29 已登记 |

**rill 必过子集为以下 25 条之外的全部 136 条正确性断言**。排除项要求单回调 compute 内写入，或要求在下一轮 compute 之前清理；表中逐条登记，另由正式 API 测试验证分相及反馈。

正确性改写项为 #38、#47、#50、#54、#61、#63、#64、#113、#114、#130、#133、#134、#156、#163、#180、#200、#212、#213、#221、#223、#224、#225、#235、#237、#243。其中通过原断言的循环用例只证明计算期间的写被拦截；实际循环由正式 API 测试触发。29 条探针全部运行；#49/#175 的原回调无法表达分相，表中保留实测失败。

编号沿用上游，所有用例均可在 Dart 表达。`VAR` 后是探针实际观察到的 variant。`原样符合` 表示断言直接通过或探针结果与 JS 一致。`有意偏离` 记录库或 adapter 的行为差异，不代表 rill 已采纳这些语义。本轮无需显式 drain，也没有不支持的条目。signals_core 的 `run` 由 adapter 管理测试用 effect 句柄，#246 的结果包含这一层的清理行为。#176 测 adapter 的 batch 返回值，alien 的 start/endBatch 包装返回空值，signals_core 传递原生 batch 的返回值。

Dart 门禁运行并核对全部 rill 条目，包括已登记的改写项。对照库已知失败继续按原规则跳过。完整审计命令为 `cd conformance && dart --enable-asserts run tool/observe.dart`。

| rft | 用例 | JS alien-signals | Dart alien_signals | 状态 | Dart signals_core | 状态 | rill | 状态 | rill 语义说明 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| #1 | diamond | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #2 | diamond + tail | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #3 | jagged diamond + tails | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #5 | drop A→B→A updates | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #6 | one unchanged dep does not block update from changed dep | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #7 | unchanged computed values stop propagation to downstream | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #8 | topological order | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #9 | linear convergence | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #10 | exponential convergence | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #12 | active dep triggers, inactive dep does not | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #13 | switching branches deactivates old deps | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #14 | new deps updated before dependee | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #15 | unread computed subscription | VAR: no subscription | VAR: no subscription | 原样符合 | VAR: no subscription | 原样符合 | VAR: no subscription | 原样符合 |  |
| #16 | lazy branch | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #17 | computed evaluation timing | VAR: lazy | VAR: lazy | 原样符合 | VAR: lazy | 原样符合 | VAR: lazy | 原样符合 |  |
| #18 | cached — not re-evaluated if deps unchanged | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #19 | returns updated value after dep change | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #21 | chained computed dirty reallocation after trigger | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #22 | chained computed avoids redundant re-compute | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #23 | sync access of invalidated chained computed runs effect | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #24 | dependency evaluation order consistent with last access | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #25 | no re-compute if zero dependencies | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #26 | computed remains live after losing all subscribers | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #27 | downstream not re-evaluated unless value changed | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #28 | same primitive value — no propagation | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #29 | NaN equality semantics | VAR: === | VAR: Object.is | 有意偏离 | VAR: === | 原样符合 | VAR: Object.is | 有意偏离 | Dart 运行时的 NaN 命中默认相等的 identical 短路。 |
| #30 | same-reference signal write | VAR: skips | VAR: skips | 原样符合 | VAR: skips | 原样符合 | VAR: skips | 原样符合 |  |
| #34 | pruning stops at first unchanged node | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #35 | effect runs callback immediately on creation | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #36 | effect re-runs when dependency changes | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #38 | effect cleanup fn called before each re-run | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Expected deep equal [run:0, cleanup:0, run:1] but got [run:0, run:1, cleanup:0] | 改写后符合 | R4 在所有 compute 完成后才清理前一次 apply 的资源。 |
| #39 | effect cleanup fn called on disposal | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #40 | effect cleanup runs outside reactive evaluation context | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #42 | effect not executed if disposed during pending batch | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #43 | outer effect runs before inner effect | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #45 | untracked inner effect does not subscribe to deps | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #46 | duplicate subscribers don't cause duplicate notifications | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #47 | effect recursion handled on first execution | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #48 | nested effects depend on state of outer effects | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #49 | inner write re-run through computed chain | VAR: runs once per write | VAR: runs once per write | 原样符合 | VAR: runs twice per write | 有意偏离 | FAIL: self-correcting write did not settle (see #212) | 改写后符合 | 原回调在 compute 内写入；正式 API 的 apply 反馈在下一轮重跑。 |
| #50 | effect writes back to signal | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | R4/R5 将读取移入 compute，将回写移入 apply；正式 API 断言同步写回。 |
| #51 | effect cleanup modifying dependency does not retrigger | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #52 | computed writing to signal | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #53 | inner write: only final value observed | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #54 | inner mutations propagate until changes settle | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #56 | effect re-scheduled after reading from derived then writing | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #57 | computed side effect triggers downstream | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #61 | indirect cycle through effects | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 改写后符合 | 原回调的写入在 R5 被拦截；正式 API 测试在 apply 内形成真实反馈回路。 |
| #62 | infinite loop in effect | VAR: no throw | VAR: no throw | 原样符合 | VAR: cycle detected | 有意偏离 | VAR: cycle detected | 改写后符合 | 上游探针把 R5 禁写也归为 cycle detected；正式 API 另断言第 100 轮后的 RILL_INFINITE_LOOP。 |
| #63 | cycle from modifying a branch (dynamic cycle creation) | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 改写后符合 | 原回调的写入在 R5 被拦截；正式 API 测试在 apply 内形成真实反馈回路。 |
| #64 | max iteration limit reached | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 改写后符合 | 原回调的写入在 R5 被拦截；正式 API 测试在 apply 内形成真实反馈回路。 |
| #66 | nested batches: outer completion triggers propagation | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #67 | signals readable with updated value inside batch | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #69 | throwing batch leaves a consistent state | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #70 | effect first run is immediate even inside batch | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #72 | intermediate values skipped (only final value observed) | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #74 | multiple signals grouped in single update | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #75 | untracked read in effect does not create dependency | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #76 | untracked read in computed does not create dependency | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #84 | graph stays consistent after error in initial computed | PASS | PASS | 原样符合 | FAIL: Expected error containing "initial error" but got "Instance of 'SignalEffectException'" | 有意偏离 | PASS | 原样符合 |  |
| #86 | computed error caching | VAR: returns stale | VAR: caches error | 有意偏离 | VAR: caches error | 有意偏离 | VAR: caches error | 有意偏离 | R6 缓存并重抛同一异常和栈。 |
| #88 | effect subscription after first-run throw | VAR: keeps subscribed | VAR: keeps subscribed | 原样符合 | VAR: unsubscribes | 有意偏离 | VAR: keeps subscribed | 原样符合 |  |
| #89 | effect cleanup reset when effect throws | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #90 | effect disposed when cleanup throws | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #91 | exception halts propagation but other branches remain intact | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #92 | no stale scheduled updates left after exception | PASS | PASS | 原样符合 | FAIL: Expected error containing "stale error" but got "Instance of 'SignalEffectException'" | 有意偏离 | PASS | 原样符合 |  |
| #93 | exception recovery in computed | PASS | PASS | 原样符合 | FAIL: Expected error containing "fail" but got "Instance of 'SignalEffectException'" | 有意偏离 | PASS | 原样符合 |  |
| #94 | stale invocation does not trigger pending computations | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #95 | stale computations evaluated before their dependees | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #97 | flags indirectly updated during dirty-checking | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #106 | effect throw isolation in flush | VAR: halts flush | VAR: halts flush | 原样符合 | VAR: continues | 有意偏离 | VAR: continues | 有意偏离 | R6 先完成其余 effect 的 apply，再上报错误。 |
| #107 | non-Error throw caching | VAR: returns stale | VAR: caches error | 有意偏离 | VAR: caches error | 有意偏离 | VAR: caches error | 有意偏离 | R6 同样保留 Dart 抛出的普通对象。 |
| #108 | effect self-dispose during execution is safe | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #110 | double-dispose is safe | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #111 | cleanup-triggered dispose prevents re-run | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #112 | computed side-effect doesn't affect sibling computeds | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #113 | inner write convergence: converges or cycle-detects | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 改写后符合 | 原回调的写入在 R5 被拦截；正式 API 测试在 apply 内形成真实反馈回路。 |
| #114 | inner write final value unchanged: no downstream notification | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #115 | signal creation inside computed is allowed | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #116 | other listeners still notified after one disposes | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #117 | untracked read of stale computed returns fresh value | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #118 | untracked transitively doesn't track through nested deps | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #119 | batch: computed same result despite source change — no effect run | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #120 | cleanup writes inside effect: downstream settles on final value | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #121 | pending effects run even if some effects throw during batch | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #122 | post-batch writes work normally | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #123 | repeated no-op batches don't re-trigger effects | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #124 | trigger+dispose+retrigger in batch = no run | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #125 | batch: source reverts → computed not notified | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #126 | new effect inside batch after write sees updated value | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #128 | reading computed in batch forces upstream evaluation | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #129 | reading one computed doesn't notify sibling effect early | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #130 | effect inner writes: downstream settles on final values | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #131 | derived-of-derived: source reverts in batch | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #132 | batch revert: subscribed computed | VAR: skipped | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 |  |
| #133 | listener writes back: second listener settles on final value | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #134 | listener writes back: second listener gets final value | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #135 | chained computed inner write: downstream only sees settled | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #136 | computed inner write unchanged: no downstream notification | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #137 | computed inner write changed: downstream notified | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #138 | independent computeds sharing source, one inner-writes | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #141 | dispose during execution then continue: no re-run | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #143 | destroyed effect not re-scheduled on later updates | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #145 | undefined is a valid computed value (not uninitialized) | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #146 | recompute count on multiple dep changes | VAR: single recompute | VAR: single recompute | 原样符合 | VAR: single recompute | 原样符合 | VAR: single recompute | 原样符合 |  |
| #147 | batch revert: unsubscribed computed | VAR: skipped | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 |  |
| #149 | batch preserves correct evaluation order | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #153 | computed self-dep recovery after catching cycle error | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #154 | batch throw: effects survive, graph consistent | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #155 | errors cached when watched by effect (live caching) | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #156 | untracked write inside effect doesn't throw | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #157 | three-way diamond: sub updates when two of three deps unmark | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #158 | stale chained computed accessed after update: values fresh | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #159 | pending computation created after dirty signal still updates | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #160 | computed after losing all listeners: disposed effects stop, value stays correct | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #161 | multi-level computed after all listeners removed: disposed effect stops, value stays correct | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #163 | parent effect not triggered by child's own signal | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #164 | inner autorun created inside outer tracks own deps | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #165 | computed dep cleanup doesn't delete sibling subscription | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #166 | after dep removed via branch switch, re-subscribing works | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #167 | computed NaN downstream propagation | VAR: === | VAR: Object.is | 有意偏离 | VAR: === | 原样符合 | VAR: Object.is | 有意偏离 | computed 同样以 identical 短路判相等，重复 NaN 不触发下游。 |
| #169 | live pruning: effect not re-run when intermediate computed returns same | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #170 | inner effect not triggered when computed dep resolves unchanged | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #172 | computed writing to own dep: next read | VAR: re-evaluates | VAR: re-evaluates | 原样符合 | VAR: re-evaluates | 原样符合 | VAR: throws | 有意偏离 | R5 把原自写计算记为失败状态。 |
| #173 | mid-propagation read isolation | VAR: post-write | VAR: post-write | 原样符合 | VAR: post-write | 原样符合 | VAR: throws | 有意偏离 | R5 拒绝 compute 对正在被观察的 signal 写入。 |
| #174 | intra-run read-after-write | VAR: post-write | VAR: post-write | 原样符合 | VAR: post-write | 原样符合 | VAR: throws | 有意偏离 | R5 在读回新值之前拒绝计算期间的写入。 |
| #175 | effect multi-signal write batching | VAR: unbatched | VAR: unbatched | 原样符合 | VAR: batched | 有意偏离 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调的首次 compute 被 R5 拒绝；正式 API 另断言同一 apply 的两次写入在下一轮合并。 |
| #176 | batch return value | VAR: returns void | VAR: returns void | 原样符合 | VAR: returns value | 有意偏离 | VAR: returns value | 有意偏离 | R3 的泛型 batch 返回回调的结果。 |
| #177 | skipped effects from failed flush not re-triggered by unrelated signal | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #178 | dispose cleanup reads don't leak to parent tracking context | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #179 | computed self-increment: intra-run read-after-write values correct | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #180 | inner write through computed chain resets signal | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #181 | computed writes multiple signals: downstream sees consistent pair | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #182 | computed side effect + batch: writes visible after flush | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #184 | nested computeds: outer reads inner, both have side effects | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #185 | computed side effect write visible despite later throw | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #186 | effect observes computed side-channel write during propagation | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #187 | unsubscribed computed after write | VAR: not evaluated | VAR: not evaluated | 原样符合 | VAR: not evaluated | 原样符合 | VAR: not evaluated | 原样符合 |  |
| #188 | batch + dynamic deps: stale unreachable computed | VAR: skipped | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 |  |
| #189 | multi-signal change: reachable computed evaluated once | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #190 | computed notifies newly-subscribed effect after prior read | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #191 | effect sees latest computed value when subscribing after source change | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #192 | effect not re-run when computed dep value unchanged | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #193 | branch switch: stale unreachable computed | VAR: skipped | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 |  |
| #194 | chained computed dirty reallocation via effect | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #195 | chained computed dirty reallocation via manual read | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #196 | maybe-dirty diamond: first dep unmarked, second still triggers | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #197 | chained value-equality stops propagation across multiple writes | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #198 | effect discovers new branch deps | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #199 | effect ignores inactive branch dep | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #200 | independent dep tracking across effects with dynamic deps | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #204 | multi-source fan-in | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #205 | multi-source cross-diamond | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #206 | stacked diamonds | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #207 | wide fan-out: all effects fire once | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #208 | deep asymmetric join (depth 3 vs 1) | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #209 | three-level nested effect: disposal | VAR: cascades | VAR: cascades | 原样符合 | VAR: no cascade | 有意偏离 | VAR: no cascade | 有意偏离 | 嵌套调用本身不建立 effect 所有权；Scope 负责释放。 |
| #210 | inner effects on outer re-run | VAR: replaced | VAR: replaced | 原样符合 | VAR: accumulates | 有意偏离 | VAR: accumulates | 有意偏离 | 重跑外部 effect 不隐式替换此前在同 Scope 创建的 effect。 |
| #211 | computed error chain: downstream computed also throws | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #212 | inner write through computed doesn't block future propagation | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #213 | inner write during initial effect execution doesn't block future propagation | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #214 | effect recreates inner computed each run: new child sees latest value | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #215 | partial dispose: sibling effect still notified | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #216 | sibling effect order on shared signal | VAR: creation order | VAR: creation order | 原样符合 | VAR: creation order | 原样符合 | VAR: creation order | 原样符合 |  |
| #217 | new effect after dispose works normally | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #218 | untracked read survives across batched writes | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #219 | batch inside untracked still coalesces writes | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #220 | computed same object reference — no downstream propagation | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #221 | three-effect cycle stays bounded | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 改写后符合 | 原回调的写入在 R5 被拦截；正式 API 测试在 apply 内形成真实反馈回路。 |
| #222 | effect created inside cleanup tracks its own deps | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #223 | cycle through computed stays bounded | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 改写后符合 | 原回调的写入在 R5 被拦截；正式 API 测试在 apply 内形成真实反馈回路。 |
| #224 | effect sees fresh computed after sibling's mid-flush inner write | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #225 | mid-flush fan-in: e3 sees both sibling effects' inner writes | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #226 | outer keeps responding to own deps after inner re-runs | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #227 | outer responds after one of multiple sibling inners re-runs | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #228 | outer responds after inner re-runs multiple times | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #229 | cleanup reads computed: sees fresh value | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #230 | cleanup writes signal inside batch propagates after flush | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #231 | untracked inside cleanup: still no tracking | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #233 | cleanup write then read of dependent computed: sees new value | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #235 | batch inside effect body coalesces writes | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Bad state: RILL_WRITE_IN_COMPUTATION: Cannot write signal@package:rill_conformance/adapter.dart:127 during effect@package:rill_conformance/adapter.dart:162. | 改写后符合 | 原回调在 compute 内写入；R4/R5 要求把写入移入 apply。 |
| #236 | cleanup write to own dep: bounded recursion completes | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #237 | cleanup ordering on outer re-run: outer cleanup before re-run | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Expected 0 > 1 | 改写后符合 | R4 在所有 compute 完成后才清理前一次 apply 的资源。 |
| #238 | dispose runs outer cleanup with nested effects | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #241 | nested cleanup order on dispose | VAR: deepest first | VAR: deepest first | 原样符合 | VAR: no cascade | 有意偏离 | VAR: no cascade | 有意偏离 | 单独释放 effect 只清理它自身；如需子先父需显式 Scope。 |
| #243 | cleanup ordering correct after prior inner-only re-run | PASS | PASS | 原样符合 | PASS | 原样符合 | FAIL: Expected 0 > 1 | 改写后符合 | R4 在所有 compute 完成后才清理前一次 apply 的资源。 |
| #244 | sibling cleanup order on dispose | VAR: LIFO | VAR: LIFO | 原样符合 | VAR: no cascade | 有意偏离 | VAR: no cascade | 有意偏离 | 单独释放外部 effect 不会释放同 Scope 的内部 effect。 |
| #246 | throwing run body child effect cleanup | VAR: children survive | VAR: children survive | 原样符合 | VAR: disposes children | 有意偏离 | VAR: disposes children | 有意偏离 | adapter 在 finally 释放 fixture 的显式 Scope；Scope.run 自身只建立创建上下文。 |
| #247 | flush queue consistent after effect throw | PASS | PASS | 原样符合 | PASS | 原样符合 | PASS | 原样符合 |  |
| #248 | multi-signal change: stale unreachable computed | VAR: skipped | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 | VAR: skipped | 原样符合 |  |

## V2 · Solid 异步查询派生用例

来源为 Solid 源码快照 `4f3c3c4ce1f017b19102153070e056f5902f7bc1` 的 `packages/signals/tests`。
Dart 用 `Completer` 控制各次请求的落地顺序，用 `StreamController` 观察取消，
在 `packages/rill/test/query_test.dart` 中断言结果、报错、取消和依赖变化。
裁决依据是 rill 的查询规则（Q1–Q7）与 R7（等待 Future 随那一轮）。
查询读出的是 `AsyncState`，只在被观察时工作，所以下表各用例用观察者（测试里的 `Reader`、effect）或 `settled()` / `refresh()` 驱动。

| Solid 用例 | 保留的情形与 rill 断言 |
| --- | --- |
| `async-chain-supersession` | 下游等待上游，过期的首段结果不会唤醒下游，当前结果正常经过两级传播。 |
| `superseded-before-first-commit` | 首次提交前连续换问题，旧值和旧异常都被丢弃，旧 Query 的取消 Future 完成。还覆盖 Dart 同步 completer 在写入 batch 内落地。 |
| `overlapping-flights` | 独立查询以相反顺序完成，分别保留自己的结果。 |
| `iterator-supersede-close`、`async-cleanup-timing` | 被取代的流立即执行取消；最后一个观察者离开后一个微任务取消当前流（查询不归 Scope 所有）；生命周期通知见 `Query.cancelled`。 |
| `superseded-flight-pending-source` | 请求在途时切换依赖分支，旧分支后续变化不会再启动请求。 |
| `untracked-read-after-await` | await 前读取加入依赖，await 后的直接读取报 debug 诊断；显式 `peek` / `untracked` 保持静默。 |
| `try-catch-reactive-read`、`caught-reactive-read-diagnostic`、`loading-value` 首载 | **有意偏离**：不抛，读状态。首载读到 `AsyncLoading`，`peek()` 永不抛；`computed(() => q.value.valueOrNull ?? -1)` 先得 -1，首个答案到达后重新计算。没有 `NotReady`，也没有 R7 诊断（`RILL_CAUGHT_REACTIVE_READ` 已删除）。 |
| `error-is-an-answer`、`error-silent-recovery` | 新问题失败得到不带旧值的 `AsyncError`（`hasPrevious == false`），携带原对象和栈，`requireValue` 以原栈重抛；同一问题刷新失败得到 `AsyncError.withPrevious`，后续相等值仍恢复下游。 |
| `latest-async`、`isPending-memo-consistency`、`question-scoped-pending` 的普通查询部分 | 以 `AsyncData.refreshing/stale` 观察状态。首载为 `AsyncLoading`，依赖变化带 stale，同问题刷新保留对应答案，B 失败后刷新不会显示 A。 |
| `refresh-await`、`resolve`、`until` 的等待最终答案情形 | 用 `refresh()` 等待最终状态，重叠等待者都收到获胜请求的状态；失败以 `AsyncError` 返回。 |

## V2b · 冷却与串联（rill 自有，Solid 无对应）

查询规则的用例全部在 `packages/rill/test/query_test.dart`，用例名即下表名字；绑定侧在 `packages/rill_flutter/test/async_test.dart`。

| 规则 | 用例 |
| --- | --- |
| `AsyncState` | `public const constructors, hasPrevious and ==`、`valueOrNull, requireValue and map follow hasPrevious`（含 `RILL_NO_VALUE`）、`all merges by position`（二元–六元、`Iterable.all`） |
| Q1 / Q3 / Q4 | `an input change supersedes and cancels; old answers never land`、`a synchronous completion inside a write batch cannot land`、`overlapping independent flights settle independently`、`a stream switches its dependencies and cancels the replaced subscription`、`peek is a state, never throws; tracked reads see loading`、`a new question can show A while loading but B failing has no previous`、`a same-question refresh keeps the value; a failed refresh keeps it as previous`、`concurrent refresh waiters settle on the replacement landing`、`equals keeps the old value reference: an equal refresh wakes no value reader`、`AsyncError carries the original object and stack`、`streams: an error event does not end the stream; empty streams fail`、`tracks the synchronous prefix and diagnoses post-await reads`、`computedStream: the synchronous fn tracks; an async* body does not and is diagnosed`、`q.wait chains streams: the sync fn registers the wait` |
| Q3 新问题失败忘掉旧答案 | `new_question_failure_forgets_the_old_answer` |
| R1 问题节点不跑用户代码 | `cold_peek_runs_no_user_code; cold_peek_launches_nothing` |
| R2 开工只在对账、只在被观察时 | `first_frame_is_loading_and_siblings_agree`、`hot_branch_switch_into_cold_chain_launches`、`effect_stopped_before_flush_launches_nothing (stop() inside compute)`、`a cold read outside observers is diagnosed once; peek is exempt`（`RILL_COLD_QUERY_READ`）、`cold_query_read_warning_names_the_reader` |
| R3 状态纯派生 | `input_change_while_cold_is_stale_on_first_frame`、`cold_invalidated_query_reports_refreshing_without_request` |
| R4a 输入断边 | `unobserved_query_ignores_input_writes` |
| R4b `retain: 0` 微任务丢弃 | `cold_computed_reobserved_after_unfinished_load_restarts`、`stream_unsubscribes_a_microtask_after_last_observer`、`globalkey_reparent_keeps_query`、`stale_cooling_microtask_yields_to_a_later_observer`、`dropped_query_releases_consumed_answers` |
| R4c 在途 + `retain` 一个 Timer | `in_flight_with_retain_keeps_one_timer; timer_expiry_cancels_and_keeps_good_answer` |
| R4d 懒 TTL → SWR | `retained_answer_within_ttl_no_request; expired_retained_answer_revalidates_swr` |
| R4e 冷却时持有错误 = 失效 | `cooled_error_retries_on_return`、`cold_landed_error_retries_on_return` |
| R4f `keepAlive` 租约 | `keepalive_scope_skips_cooling; keepalive_scope_disposed_with_observer_does_not_cancel`（已销毁 Scope 断言 `RILL_DISPOSED`）、`keepalive_still_retries_cooled_error` |
| R4 可见性 | `pulse_input_stops_through_wait_chain`；绑定侧 `a Pulse input stops behind TickerMode through a wait chain` |
| R5 等待边比较器 | `diamond_wait_never_pairs_new_input_with_old_answer`、`two_upstreams_land_downstream_runs_once`、`upstream_equal_refresh_no_rerun`、`stream_upstream_resubscribes_when_only_downstream_observes`、`relanded_different_answer_after_discard_reruns_downstream`、`upstream_error_recovery_recovers_downstream`、`upstream_new_question_makes_downstream_stale_at_once`、`upstream_refetch_failure_keeps_downstream`、`wait_on_refreshing_upstream_waits_for_new_answer`、`wait_on_failed_refresh_resolves_error`、`a wait after an await throws and observes nothing` |
| R6 重试沿失败上溯 | `retry_downstream_retries_failed_upstream`、`retry_does_not_reinvalidate_retrying_upstream` |
| R7 等待 Future 随那一轮 | `abandoned_wait_neither_leaks_nor_throws`、`superseded_attempt_wait_never_completes`、`cold_peek_does_not_resume_paused_wait`、`repeated_wait_shares_future`、`abandoned_wait_under_an_observed_downstream_stays_silent`、`failed_first_wait_leaves_the_second_silent` |
| R8 开工在 Scope 之外 | `query_launch_in_build_joins_nothing` |
| V1 防环 | `mutual_wait_cycle_fails_with_cycle`、`self_wait_fails_with_cycle`、`wait_plus_sync_read_cycle_fails_with_cycle`（含查询读自己） |
| V2 协议对接 | `cold_binding_input_change_is_stale`、`cold_binding_input_change_through_wait_is_stale`、`wait_on_a_sampled_upstream_marks_the_reader`、`reused_edge_carries_the_sampled_mark`、`reused_wait_edge_carries_the_sampled_mark`、`unchanged_on_query_detects_a_change`、`unchanged_sees_cold_expiry`、`unchanged_sees_cold_binding_input_change` |
| V3 过期在 pull 里 | `settled_on_expired_query_waits_for_revalidation`、`expired_query_siblings_agree` |
| V6a 冷却结束保留计时器 | `cold_stream_close_ends_the_retention_timer` 的 `answered` 与 `empty` 两例 |
| V6d | `throwing_listen_lands_error` |
| 诊断与图检查 | `why_finds_queries_by_name_and_id; question and retry are recorded`、`async_state_equality_is_symmetric`、`check_graph_walks_into_the_answer_node`；rill_test `idle sees query work: in flight, and started between pumps`；rill_lint `rill_write_in_computed` 的 `test_computeParameters`（含 `computedStream`） |
| 比较器、等待与流结束 | `comparators, waits and stream ends` 组：`cycle_formed_after_success_lands_once_and_recovers`；`comparator_throw_lands_as_error_with_its_stack`、`comparator_reentrant_invalidate_installs_no_superseded_answer`；`repeated_wait_returns_one_future_and_reports_one_error`；`stream_cancel_that_drops_last_reader_opens_no_stream`；`cancelled_attempt_holds_no_query_and_its_wait_observes_nothing`；`stream_error_then_done_keeps_the_error`、`empty_stream_is_still_rill_empty_query`。进程测试 `test/process/query_process_test.dart`：`cycle_formed_after_success_lands_once_in_debug` / `_in_aot`，`cooled_query_is_not_held_by_a_pending_future`（VM service 强制 GC） |
| 环的恢复 | `cycle recovery and wait-edge comparator failures` 组：`independent_landing_recovers_a_computed_cycle_once_untied`、`wait_edge_comparator_throw_is_a_recoverable_error_cold` / `_observed`；进程测试 `independent_landing_recovers_once_untied_in_debug` / `_in_aot`；另见 `query_cycle_recovery_test.dart`、`query_ordering_test.dart`、`query_relaunch_test.dart`、`query_reconcile_test.dart` 与它们的进程 fixture |
| 绑定（F6、Q8） | `a query in a test leaves no pending timer: retain 0 and a landed retain`、`siblings agree on the first frame and the request starts in it`、`gate and leaf: requireValue is safe when the gate unmounts the leaf synchronously`、`a gate that passes the value down survives an AnimatedSwitcher`、`a parent rebuild with inline closures does not rebuild a retained reader`、`a page pop cools its queries: no query work is left`（`expectIdle` 侧见 rill_test 的 `idle sees query work: in flight, and started between pumps`）、`an unmounted reader does not wake when its query lands`、`a synchronous computed error goes to ErrorWidget and recovers`、`B4 linger rethrows the original failure and later recovers` |
| V4 生成边界 | `conformance/test/command_boundaries_test.dart` 的 `streamCancel`（同步取消里读同一查询；effect 退订后一个微任务取消流）与 `cleanup`（Scope 清理里读或刷新兄弟观察的查询；读取不开工，销毁后没有在途工作） |

**预期偏离。** 公开 API 只定义本地查询状态机。有关 hold、lane、transaction、optimistic、
`affects`、action 等待与加载边界的用例不移植。Solid 的独立 `isPending`、`loadingValue`、
`resolve` 与 `until` API 不在 rill 的公开 API 里，其匹配的状态断言见上表。`syncThenable` 依赖
JS 同步 thenable。Solid 捕获读取错误后仍传播 pending 的规则在 rill 里没有对应物：加载态是状态，不是异常；
同问题重取的加载表现按 Q2/Q3，通过状态观察。

## Readable.constant（v0.2.0，R1a）

`Readable.constant(value, {name})` 必须在任何接受 Readable 的地方成立，且从不变化、从不通知、不建边。
K1–K6 在 `conformance/test/constant_test.dart`，K7–K8 是绑定层用例，在 `packages/rill_flutter/test/constant_test.dart`；
rill_test 的 `wakes` 对常量的断言在 `packages/rill_test/test/mount_app_test.dart`。核心另有一条变异回归
（`packages/rill/test/deferred_effect_test.dart` 的 R1a）。

| 用例 | 断言 |
| --- | --- |
| K1 | `value` / `peek` 返回原对象（不复制），`name` 可选 |
| K2 | 只读常量的 computed 冷读、热读都只求值一次；无关写入不唤醒 |
| K3 | 常量与 signal 同时被读时，只有 signal 驱动重跑 |
| K4 | 读者不在常量上留边：`subscriberCount == 0`，`checkGraph` 通过 |
| K5 | `Unchanged(constant)` 永远成立，修订号不变 |
| K6 | 诊断：`RillDebug.describe` 给出 `constant` 与名字；`ext.rill.graph` 列出它，`valueType` 正确，deps/subs 为空 |
| K7 | `Reactive` 读常量不过读取守卫、不提示；只有同读的 signal 写入触发重建（一次 `RILL_REBUILD`）；`build` 里在 reader 外读也不提示 |
| K8 | `.toListenable()` 的值是常量，永不通知 |
| — | `wakes([constant])` 为空集 |

## 帧内托管写（v0.3.1，R3b）

核心用例在 `packages/rill/test/deferred_effect_test.dart` 的 `frame writes` 组（D1–D5），绑定用例在
`packages/rill_flutter/test/frame_writes_test.dart`（D6–D16）。D6、D8–D10、D12–D14 在修复前失败（`RILL_WRITE_DURING_FRAME`
或同步 apply），D11 是 R4a 已有的保证、作为 `_FirstApply.release` 新分支的回归。

| 用例 | 断言 |
| --- | --- |
| D1 | 托管写唤醒的 effect 只交给 drain；同一边界之后的 `track()` 退出、普通写入、空 `batch` 都不排空它 |
| D2 | 推迟期间再被托管写、普通写命中：只排一次 drain，apply 一次，用最新值 |
| D3 | drain 前停止：cleanup 执行，apply 不跑 |
| D4 | 标记随边界收尾清除（空闲收尾、完整 flush 两条路径）；没有写入新值的托管写不打标记，同一 batch 里的普通写仍同步 |
| D5 | 首个 apply 尚未放行的 deferredEffect 被托管写唤醒：release 不用旧值，drain 用最新值完成首个 apply |
| D6 | live `watch` 依赖桥，兄弟组件在 `didUpdateWidget` 改 notifier：apply 不在 build 里，写入不报错，同帧 post-frame 完成 |
| D7 | 同上但 apply 不写：帧结束后 `hasScheduledFrame == false`，推迟不多请求帧 |
| D8 | 同帧之后三个 `Reactive` 的 track 退出不排空：日志顺序是三个 reader，然后 cleanup、apply |
| D9 | 同帧卸载 State：只有上一轮的 cleanup，apply 不跑，桥没有残留订阅 |
| D10 | 经 `linger` 的 live `watch` 同样在帧后 apply |
| D11 | 同一次 build 里新建的 `watch` 被托管写唤醒：只 apply 一次，取最新值 |
| D12 | `LayoutBuilder` 在 layout 里改 notifier：apply 在帧后，写入不报错 |
| D13 | 事件里改 notifier：effect 不同步 apply，请求一帧，在它的 post-frame apply（R3b 的代价） |
| D14 | 推迟中的 effect 又被事件里的普通写命中：只 apply 一次，取两者的最新值 |
| D15 | 普通事件写入仍同步 apply，不请求帧（R3 不变） |
| D16 | Pulse 计时器到点是普通写，依赖它的 effect 同步 apply、不在 build 里 |

既有的 Pulse 校准用例（`lifecycle_test.dart` 的 I4–I6，`budget_test.dart`、`frame_fuzz_test.dart`）全部原样通过。


## 所有权（v0.5.0）

**adapter。** rill 没有环境所有者，rft 的 `run(fn)`（alien 的 `effectScope(fn)()`）改由 adapter 自己模拟：`run` 期间 adapter 记住
本测试的 `Scope`，它的 `effect` 包装调用 `scope.effect`，测试结束 `dispose`。effect 的回调返回 cleanup 时交给 `onCleanup`。
两种所有者共用一个调用点（`adapter.dart:162`），上表登记的失败消息里 effect 的位置因此只有一个。全部 rft 用例按原样通过。

**lifecycle fuzz。** `dispose` 变异销毁拥有一个 effect 的 Scope：该 effect 停止且不再 apply，它读的 computed 仍可读、可再被观察
（computed 没有所有者，`conformance/lib/lifecycle_fuzz.dart`）。100,000 步全过。

核心用例在 `packages/rill/test/ownership_test.dart`，绑定用例在 `packages/rill_flutter/test/ownership_test.dart`、
`diagnostics_test.dart` 的 `G1 / G2 / G3 read guard` 与 `routes and overlays: Reactive in the builder` 两组、`paint_visibility_test.dart`、`lifecycle_test.dart`。

| 规则 | 用例 |
| --- | --- |
| O1 派生不归所有者 | `late_final_computed_survives_first_reader`；`computed_has_no_dispose`；`cold_computed_keeps_no_reverse_edge`；`linger_created_in_build_survives_its_creator`；`linger_timer_stops_when_unobserved` |
| O2 没有环境所有者 | `scope_constructor_is_always_root`；`effect_created_in_apply_is_unowned`；`computed_created_in_build_is_not_owned_by_element`；`scope_made_in_build_is_root`；`query_launch_in_build_joins_nothing`（query_test） |
| O3 作用归显式所有者 | `scope_effect_stops_with_scope`；`scope_effect_stop_unlinks_registration`；`unowned_effect_stops_by_disposer`；`scope_effect_is_not_use_result`；Slot 任务随所有者 Stale 沿用 command_test 已有用例 |
| O4 已销毁 Scope 拒绝登记 | `disposed_scope_rejects_child_effect_slot_ondispose`（command_test）；`a disposed owner rejects it`（deferred_effect_test）；`keepAlive` 已销毁租约沿用 query_test 已有用例 |
| onCleanup | `nested_effect_registered_with_on_cleanup_stops_on_rerun`；`nested_effect_registered_with_on_cleanup_stops_with_outer`；`apply_throwing_after_on_cleanup_still_cleans_up`；`on_cleanup_runs_last_first_and_late_calls_join_or_run` |
| 一个组件所有者 | `reactive_stateful_with_reactive_state_has_one_scope / watch_owned_by_state_scope`；`I13 reassemble keeps a single watch; the State owns it`（lifecycle_test） |
| 无 provider 销毁 | `inherited_value_change_keeps_state_scope_and_tasks`（lifecycle_test） |
| V1 / V2 可见性是查询 | `tickermode_flip_rebuilds_no_reader`；`tickermode_flip_pauses_pulse_without_rebuild`；`reader_without_time_source_has_no_visibility_listener`；`reduce_motion_dependency_only_for_decorative_pulse`；`globalkey_move_of_a_reactive_without_inherited_dependencies_keeps_tracking`；`tickermode_resume_shows_the_calibrated_pulse_in_the_same_frame`；`pending_query_reading_a_pulse_follows_tickermode`；`equal_computed_switching_into_a_pulse_follows_tickermode`；`reduce_motion_flip_stops_a_painter_phase`、`reduce_motion_flip_stops_a_reader_phase`；`decorative_pulse_entered_outside_build_follows_reduce_motion`；既有 `an opaque route stops phase timers…`、`reduced motion stops paint phase…`（paint_visibility_test）原样通过 |
| 动效读者与 painter 宿主 | 同一 MediaQuery 下多个 motion 读者翻转 reduce-motion 不并发修改依赖表：`reduce_motion_flip_with_two_reactive_readers`、`reduce_motion_flip_with_a_reactive_and_a_painter`、`reduce_motion_flip_with_two_reactive_stateful_widgets`、`reduce_motion_flip_with_readers_of_two_periods`（均断言同帧对账、无剩余帧）；`reactive_paint_alone_guards_its_build_owner`；`painter_without_semantics_does_not_rebuild_semantics` |
| painter | `shared_painter_two_slots_two_observers`（paint_visibility_test）；「`ReactivePainter` 不是 `CustomPainter`」由类型保证（`CustomPaint(painter: ReactivePainter)` 不编译） |
| 弹层 | `dialog_with_reactive_builder_tracks`、`overlay_entry_with_reactive_builder_tracks`（diagnostics_test，纯 widgets 层的 `showGeneralDialog` / `Overlay`）；`rill_flutter` 不依赖 `material_ui`（测试也不依赖） |
| G1 / G2 / G3 读守卫 | `untracked_read_in_plain_build_throws`、`untracked_read_in_list_item_builder_throws`、`untracked_read_in_layout_throws`、`untracked_read_in_plain_paint_throws`、`peek_in_frame_is_allowed / untracked_in_frame_is_allowed`、`read_in_did_update_widget_requires_peek`、`read_guard_and_write_guard_agree_on_phase` |
| initState 里的读 | `slot_run_started_in_init_state_reads_untracked`、`effect_apply_in_init_state_reads_untracked`、`async_helper_from_init_state_throws_with_untracked_advice`；核心 `slot_run_first_part_is_not_tracked_by_its_starter`、`slot_run_and_apply_are_explicit_snapshots` |
| State scope 与 binding | `binding_probes_test.dart`：`state_scope_identity_is_fixed_during_dispose`、`state_scope_first_asked_after_dispose_is_disposed`；`unchanged_samples_an_unobserved_bridge`；`pulse_handles_taken_before_observation_share_one_timer`；`reactive_subclass_forwarding_builder_is_a_tracked_reader`、`untracked_read_in_list_generate_inside_builder_throws`。`binding_free_test.dart`（全程无 binding）：`controller_test_without_binding_reads_through_a_listenable`、`…_runs_bridged_effects`、`…_reads_a_pulse`。`pulse_binding_late_test.dart`（起始无 binding）：`pulse_observed_before_the_binding_follows_its_lifecycle`。lint：rules_test `test_subclassesAndNestedClosuresAreNotReported`，金丝雀 `NamedReactive`、`List.generate`、`lazyView`（不报）与 `WrappingReactive`（报） |
| lint | rules_test：`test_buildersByType`（ListView.builder、SliverChildBuilderDelegate、OverlayEntry、Builder、FutureBuilder、StreamBuilder、PageRouteBuilder、showGeneralDialog、PopupMenuButton 的 `List<Widget>`、自定义 Widget 的 builder 形参；嵌套 `Reactive` 不报）、`test_synchronousHelperAndTrackedReaders`（同步 helper 与返回 void 的函数不报）、`test_plainCustomPainterPaint`、`test_allFactories` 的 `Scope(` / `child` / `effect` / `slot`、`test_stateMembersBuildPaintAndScopeEffect`（含 `ReactivePainter.paint` 与 `CustomPainter.paint` 里的 effect）、`test_watchCallbacksAndPlainCode` 的同名非 rill `effect` 不报；金丝雀（`packages/rill_lint/fixtures`，只依赖 SDK 的 widgets 层）逐例校验：每个 `// expect:` 注释点名下一行必须报的规则，且不多报——含 `ListView.builder`、`CustomPainter.paint`、build 里的 `Scope()` 与 `scope.effect()`、`ReactivePainter.paint` 里的 `effect` |

## 命令与发布层（v0.6.0）

核心用例在 `packages/rill/test/command_rules_test.dart`（每条规则的最小反例）、
`packages/rill/test/wire_test.dart`（`package:rill/wire.dart`）与 `packages/rill/test/process/release_commit_test.dart`（关 assert 的 release 路径），
另有 `command_test` 的两段式与 Slot 用例。

| 规则 | 用例 |
| --- | --- |
| 默认安装 | `parallel_newer_answer_lands_when_older_arrives_first`；`publish_without_conditions_never_conflicts`（command_test）；`overwrite:` 参数不存在由类型保证（调用不编译） |
| U1 Signal 逐次精确 | `unchanged_signal_rejects_aba`、`unchanged_ignores_equal_writes`、`unchanged_on_wire_ignores_deduped_json`（wire_test） |
| U2 Computed 按拉取 | `unchanged_cold_computed_is_value_based`、`unchanged_hot_computed_rejects_a_pulled_round_trip`、`unchanged_hot_computed_misses_a_batched_round_trip`、`unchanged_hot_computed_misses_a_frame_deferred_round_trip`、`unchanged_samples_an_unwatched_binding_signal`、`unchanged_calibrates_a_paused_clock_under_a_hot_computed`、`unchanged_on_query_state`、`unchanged_on_throwing_computed`、`unchanged_on_constant_always_holds`、`holds_does_not_recompute_an_unchanged_computed`；`unchanged_samples_a_cold_bridge`、`unchanged_takes_the_sampled_value_as_baseline`（command_test）；query_test `unchanged_on_query_detects_a_change`、`unchanged_sees_cold_expiry`、`unchanged_sees_cold_binding_input_change`；constant_test `K5` |
| U3 / U4 条件是值 | `unchanged_taken_before_request_guards_another_task`、`alive_is_lifecycle_only`、`unchanged_retaken_after_own_write_guards_rollback`；command_test `require_at_root_returns_false_and_installs_nothing (computed)`、`require_in_part_drops_only_that_part, events included` |
| T1 / T2 两段式 | command_test `revalidates after staging disposes its owner`、`a throwing part restores the prior same-key wire candidate`、`comparator failure cannot install an earlier field or ledger`、`observer failure is reported after seeing the fully installed state`、`disposal revokes publication before sibling cleanup`；`transact_staging_throws_installs_nothing_with_original_stack`、`transact_and_publish_are_interchangeable` |
| T3 暂存期 | `staging_rejects_bare_writes_and_nested_commits`、`staging_rejects_invalidate_before_any_launch`、`staging_rejects_starting_a_task`、`read_during_staging_is_commit_time`、`transact_in_a_computation_throws`、`emit_during_staging_throws`；release：`reentrant_write_in_release_returns_false` |
| E1 / E2 / E3 保存点 | `part_exception_rolls_back_and_rethrows_original_stack`、`part_exception_uncaught_fails_the_whole_commit`、`part_unmet_returns_false`、`catch_all_in_stage_cannot_swallow_require`、`part_broken_after_returning_true_fails_the_commit` |
| S3 Outcome | `stale_reasons_are_superseded_and_owner_disposed_only`、`skip_returns_skipped`、`skipped_rechecks_the_owner_at_delivery`；`Outcome` 的 switch 漏 `Skipped` 由 sealed 类型保证（conformance 的两处 switch 已穷尽） |
| S4 无 parent | `nested_run_in_same_owner_tree_cancels_with_owner`；rill_test `idle tracks nested tasks through keyed joins and cancellation`；`parent:` 不存在由类型保证 |
| S5 句柄寿命 | `publish_after_body_finished_reports_closed`、`superseded_task_publishes_false_without_closed_diagnostic`、`a body that throws after supersession stays Stale`；进程测试 `pending_future_holds_no_disposed_scope_or_task_in_debug` / `_in_aot`（共享 SDK Future 挂起时销毁 128 个 Scope，debug 经 VM service 强制 GC、AOT 用分配压力，Scope 与 Task 的弱引用挂起时与完成后都是 0/128）、`disposed_scope_releases_a_task_on_a_pending_future_in_{debug,aot}`；`held_handle_of_a_cancelled_task_closes_when_its_future_settles`、`…_when_its_future_fails`（外部持有句柄时，迟到的完成仍让 `publish` 报 `RILL_CLOSED_PUBLICATION`） |
| S6 交付即裁决 | `owner_disposed_before_caller_resumes_delivers_stale`、`caller_resumes_in_delivery_microtask`、`superseded_caller_not_resumed_inside_new_run`、`delivery_never_inside_a_batch`、`queued_body_never_starts_inside_another_batch`、`task_finishing_inside_a_batch_defers_bookkeeping`、`queued_next_body_starts_before_previous_caller_resumes`、`joined_callers_share_one_verdict`、`finished_body_superseded_before_delivery_is_done` |
| Wire | wire_test：`wire_dedupes_equal_wire`、`wire_decode_failure_installs_nothing_and_decodes_again`、`wire_ledger_rolls_back_with_part`、`wire_custom_equals_projection`、`wire_set_forgets_ledger`、`wire_ledger_is_an_unmodifiable_snapshot`、`wire_ledger_is_named_after_the_wire`、`wire_keeps_typed_data_payloads`、`wire_library_imports_only_public_api`、`typed_field_reader_shared_by_decoder_and_comparator`（`jsonDecode` 的响应、解码器与比较器共用类型化字段读取、三次独立事务）、`ledger_keeps_json_types_and_stays_unmodifiable` |
| C10 迟到提交 | `transact_in_a_lapsed_task_reports_late_write`（含提交冲刷出的 effect 里的 `transact` 不报）、`transact_in_a_live_task_is_not_late` |
| 诊断 | `why_reports_refusing_condition`（`RillDebug.refusals`、`ext.rill.why` 的 `refusals`）、`refusals_filter_by_slot_and_slot_name`、`capacity_and_limit_trim_refusals`；`RILL_CONFLICTED` 文档与代码不存在（`tool/diagnostics.dart`） |
| lint | rules_test：`test_transactInComputed`、`test_transactInBuild`、`test_transactAfterAwait`；`test_allFactories` 的 `Wire(`；金丝雀 `violations.dart` 的 await 之后 `transact(` |
| 配方 | `turn_recipe_lets_the_later_ask_win` |

**参考模型。** `conformance/test/command_model_test.dart`：默认安装（没有写集冲突与 `overwrite` 维度）；`condition` 操作在任务上取一个 `Unchanged`，
`guarded` 的提交 `require` 它；`badPart` 是 `part` 抛出、在外面捕获；`transact`（不带任务的提交，可带条件）与 `deliver`（body 结束后、交付前销毁所有者）；
body 结束后的句柄调 `publish` 记为 `closed`。100 个种子 × 1000 步，共 100,000 步全过；撤掉模型里的条件判定或交付时的所有者重判，分别在种子 1 与种子 0 失败（实现方式的自检）。

**生成边界。** `command_boundaries_test.dart` 的 `savepoint` 用 `part` + `Wire`（条件在暂存前被破坏则只丢这部分，根层照常解码），`parent` 用 `condition`（条件作为值传给另一个槽的任务），
`join` 不带 `parent`（合并不重新准入，默认安装让首个任务的提交落地）。

**示例 store。** `examples/feed_store` 是一个端到端场景：轮询在请求前取 `Unchanged(sweep)` 并交给收尾任务（body 首行准入、提交里 `require`），
快照段是 `part`（条件是开工时的 `groups` / `nodes`），`sweepAll` 以开工时的 sweep 为条件（「首个回执胜」），`_runAction` 没有手检，轮询失败的 `trouble` 在 body 内 `t.publish`。
`the store has no hand checks, parent, overwrite or ignore` 断言源码里这四个词出现 0 次。

## 合成层直驱（F13，v0.7.0）

`ReactiveOpacity` / `ReactiveTransform` 的绑定层用例在 `packages/rill_flutter/test/composite_test.dart`。典型 reader 是底部 sheet（偏移与遮罩透明度）。

| 用例 | 断言 |
| --- | --- |
| C13a | `ReactiveOpacity` 在 0 < α < 1 间连续 10 次写：10 帧，子树 0 build、0 paint，`OpacityLayer.alpha` 跟随 |
| C13b | α 写到 0：子树离开 semantics 树；离开 0：回到 semantics 树、子树重绘恰好 1 次；`alwaysIncludeSemantics` 时 α=0 仍在树中 |
| C13c | `ReactiveTransform.translate` 连续 60 次写：60 帧，子树 0 build、0 layout、0 paint，`TransformLayer.transform` 跟随 |
| C13d | 平移后命中测试按当前矩阵：原位置 0 命中，新位置命中；semantics 矩形随矩阵移动 |
| C13e | 脱附期间 0 订阅，同一 render 对象重挂后 1 订阅且当帧的绘制与命中测试已用脱附期间写入的值；换源后新源 1、旧源 0，写旧源 0 帧；卸载全 0 |
| C13f | 派生出相等矩阵时 0 帧；`Readable<Matrix4>` 源可用 |
| C13g | `ReactiveOpacity` 在 1 → 0.5 → 0 → 1 上的策略：命中测试始终照常（与 `Opacity` 相同，透明度不禁用命中），semantics 只在 α 恰为 0 时离开 |
| C13h | 宿主：`composite_reader_pulse_follows_tickermode`——`TickerMode` 关闭时 `ReactiveOpacity` 读的 `Pulse.phase` 停表，恢复后重启 |
| C13i | `composite_reader_phase_follows_reduced_motion`（父组件同帧重建，走 `update`）与 `…_without_a_parent_rebuild`（同一 widget 实例，走 `performRebuild`）：reduced motion 翻转停 / 启装饰时间源，无剩余帧 |
| C13j | `composite_host_guards_its_build_owner_on_activate`：GlobalKey 移动激活宿主时重装守卫 |
| C13k | 变换原点（v0.7.2）`transform_origin_first_frame_corners: …`（5 例：dialog 绕中心 0.97、popup 绕上 / 下边 scaleY 0.96、单独 `origin`、`origin` 叠加 `alignment`）：首帧子节点四角的全局坐标经 `localToGlobal`、`TransformLayer`（offset + transform）、semantics 矩形三条路径都正确 |
| C13l | `transform_origin_hit_tests_about_the_alignment`：绕中心缩放后，只在未缩放框内的点不命中，只在绕中心缩放框内的点命中 |
| C13m | `transform_origin_directional_alignment_resolves_rtl`：`AlignmentDirectional.centerStart` 在 RTL 下绕右边、LTR 下绕左边；翻转方向子树 0 build、0 layout、0 paint |
| C13n | `transform_origin_alignment_change_updates_the_render_object_only`：popup 换边（topCenter → bottomCenter）同一 render 对象，子树 0 build、0 layout、0 paint，四角与图层随新原点 |
| C13o | `transform_origin_animation_is_0_build_0_layout`：绕中心 0.97 → 1 的 30 帧，子树 0 build、0 layout、0 paint，每帧中心不动、四角跟随 |

## 配置输入（F14，v0.7.0）

绑定用例在 `packages/rill_flutter/test/widget_input_test.dart`，用例名即规则；夹具是两个缩写的 raw widget（`RawListbox` + `ListboxController`，`RawSheet` + `SheetController`）。lint 用例在 `packages/rill_lint/test/rules_test.dart`。

| 规则 | 用例 |
| --- | --- |
| 同帧、无第二次 build（列表框） | `listbox_items_replaced_in_did_update_widget_are_current_in_the_same_frame`：高亮项被删、新增 disabled 项；同一次 pump 后焦点顺序与回退的高亮已是新值，读者 build +1，帧数 +1，无剩余帧，`watch` 在 `postFrameCallbacks` apply |
| sheet 吸附点 | `sheet_snap_points_move_the_layer_in_the_same_frame`：`ReactiveTransform` 的矩阵与 `TransformLayer` 同帧移动，内容 0 build |
| sheet reduced motion | `sheet_reduced_motion_synced_in_did_change_dependencies`：以 reduced 挂载时读者从未见过占位值；翻转后同帧更新、一次 build、`watch` 帧后 |
| equals 拦截 | `equal_configuration_object_propagates_nothing`：内容相等的新列表不推进修订号、不重算、不 build、无帧 |
| R3b | `effect_woken_by_sync_applies_after_the_frame`：顶层 `effect` 在帧后 apply，apply 里的写入合法 |
| OverlayPortal 子节点在子树内 | `overlay_portal_child_is_inside_the_owner_subtree` |
| 越界读者 | `reader_outside_the_owner_subtree_is_escaped`（兄弟 `Reactive`；报告后下一帧追上）、`native_listener_of_an_input_is_escaped`（`toListenable()`） |
| 越界判定只算依赖输入的读者 | `outside_reader_woken_by_a_pulse_during_sync_is_not_escaped`：sync 让子树里的 computed 开始读停着的 Pulse，对账采样唤醒子树外的时钟，不报 |
| sync 的位置 | `sync_in_an_event_handler_throws`、`sync_in_the_owner_build_throws`、`sync_in_init_state_throws`、`sync_from_another_build_in_a_later_frame_throws`（窗口随帧关闭）、`sync_inside_a_batch_throws`（拒绝且不写入） |
| 写守卫豁免 | `sync_in_did_update_widget_is_exempt_from_the_write_guard` |
| 属主销毁 | `owner_disposed_input_stays_readable_and_sync_throws`、`sync_in_the_owner_dispose_is_after_disposal`（`dispose` 体内、`super.dispose()` 之前） |
| lint | rules_test `test_widgetInputInBuild`（build 里的 `input(` 报；`late final` 字段、`initState`、同名非 rill 方法不报）；金丝雀 `_ConfiguredState.build`。`sync(`：`FrameWriteTest` 与 `ComputeTest` 的 `test_widgetInputSync`；金丝雀 `_InputCanaryState.build` |
