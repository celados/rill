---
type: Reference
title: RILL_LATE_WRITE
description: >
  任务已被作废（被取代、所有者销毁）或 body 已结束后，它的 Zone 里仍然发生了裸写入或 transact。
when: An error, diagnostic or VM service record carries RILL_LATE_WRITE.
code: RILL_LATE_WRITE
severity: warning
package: rill
rules: C4、C10、rill_write_after_await
timestamp: 2026-11-21
---

# RILL_LATE_WRITE

## 原因

任务已被作废（被取代、所有者销毁）或 body 已结束后，它的 Zone 里仍然发生了裸写入或 `transact`。
`transact` 对每个暂存目标各报一次：它不带任务的发布权，和裸写入一样迟到。

- 级别：warning
- 来源：`package:rill`，经 `diagnosticHook`；未设置 hook 时 debug 下按调用位置去重，经 `Zone.current.print` 输出一次
- 打印格式：`RILL_X at <调用位置>: <节点> <原因与修法> (rill docs/diagnostics/RILL_X.md)`。
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
await slot.run((task) async {
  final data = await api.load();
  sweep.value = data;            // 任务若已被取代：报 RILL_LATE_WRITE
  transact((tx) => tx.set(rows, data.rows)); // 同样报，标签是 rows
});
```

发布同步冲刷出的反应（effect 的 apply、watch 钩子、帧后回调）跑在触发冲刷的 Zone 里，但它们的写入
算反应自己的，不算那个任务的：effect 在任务发布的同一次提交里让任务失效再写入，不报。反应里新起的任务
有自己的 Zone，照常归属。

## 修法

只提示，不拦截：Zone 不决定归属（C2）。把 await 之后的写入与 `transact` 改成 `task.publish((tx) => tx.set(sweep, data))`，
任务失效时发布返回 `false` 且不改状态。lint `rill_write_after_await` 在静态层报同一类写法。

## 相关规则

C4、C10、`rill_write_after_await`
