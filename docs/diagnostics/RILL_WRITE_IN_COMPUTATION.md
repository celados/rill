---
type: Reference
title: RILL_WRITE_IN_COMPUTATION
description: >
  computed、effect 的 compute 或提交的暂存函数运行期间写入了 signal（或发起了提交、让查询到期、启动了任务、发出了事件）。
when: An error, diagnostic or VM service record carries RILL_WRITE_IN_COMPUTATION.
code: RILL_WRITE_IN_COMPUTATION
severity: error
package: rill
rules: R4、R5、C5a、C7、rill_write_in_computed
timestamp: 2026-11-21
---

# RILL_WRITE_IN_COMPUTATION

## 原因

computed、effect 的 compute 或提交的暂存函数运行期间写入了 signal（或发起了提交、让查询到期、启动了任务、发出了事件）。

- 级别：error
- 来源：`package:rill`，经 `StateError`（debug）
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
final total = computed(() {
  lastTotal.value = cart.value.sum;  // 抛 RILL_WRITE_IN_COMPUTATION
  return cart.value.sum;
});

transact((tx) {
  tx.set(status, next);
  todos.invalidate();                 // 抛：暂存期（during staging）
  notices.emit('saved');              // 同样抛：改用 tx.emit(notices, 'saved')
});
```

暂存期（`transact` / `t.publish` 的暂存函数，C5a 第 2 步）按计算处理，不区分写者：裸写入、嵌套的
`transact` / `t.publish`、`q.invalidate()` / `q.refresh()`、`slot.run`、裸的 `events.emit` 都报。它们要么改变暂存读到的值，要么发出提交失败时撤不回的副作用。
`transact` 本身也是一次写入：在 computed、effect 的 compute 里调用同样报（C7）。

## 修法

消息给出被写的节点和正在求值的节点（名字或创建位置），暂存期显示为 `during staging`。派生值用 computed 表达；需要副作用就放进 effect 的 apply，
或命令（`slot.run` + `t.publish`）。暂存函数里只暂存：写入改成 `tx.set`，事件改成 `tx.emit`（随提交安装后发出），让查询到期与启动后续命令放到提交之后
（`if (t.publish((tx) { … })) todos.invalidate();`）。`untracked` 不豁免。lint `rill_write_in_computed` 在静态层报直接写入与 `transact(`。

## 相关规则

R4、R5、C5a、C7、`rill_write_in_computed`
