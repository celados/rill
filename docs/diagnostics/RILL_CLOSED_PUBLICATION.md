---
type: Reference
title: RILL_CLOSED_PUBLICATION
description: >
  暂存函数返回之后仍调用了 `Tx` 句柄，或 body 已结束的任务句柄仍调用 `publish`：暂存或发布权已经结束。
when: An error, diagnostic or VM service record carries RILL_CLOSED_PUBLICATION.
code: RILL_CLOSED_PUBLICATION
severity: error
package: rill
rules: C5、C5a、C8
timestamp: 2026-11-21
---

# RILL_CLOSED_PUBLICATION

## 原因

暂存函数返回之后仍调用了 `Tx` 句柄，或 body 已结束的任务句柄仍调用 `publish`：暂存或发布权已经结束。

- 级别：error
- 来源：`package:rill`，经 `StateError`。逃逸的 `Task` 句柄只在 debug 下抛（release 返回 `false`）；`Tx` 句柄两者都抛。
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
late Tx later;
transact((tx) => later = tx);
later.set(count, 1);             // 抛 RILL_CLOSED_PUBLICATION

late Task escaped;
await slot.run((t) async => escaped = t);
escaped.publish((tx) => tx.set(count, 1));   // body 已结束：debug 抛，release 返回 false
```

被取代或所有者销毁的**在途**任务调用 `publish` 不报，静默返回 `false`：那是正常的失效。

## 修法

暂存函数是同步的准备阶段（C5a 第 2 步）：把所有 `set` / `emit` / `require` / `part` 放在回调体内同步完成，
不要保存 `tx`，也不要在回调里启动异步闭包再回头暂存。需要异步数据就先 `await`，再调用 `t.publish`。

任务句柄只在 body 内有效（C8）。不要把 `t` 偷出 body 再在别处发布；要让另一个流程的提交带上本任务读到的条件，
把条件取成 `Unchanged` 值传过去（C3b），在那个流程自己的任务或 `transact` 里 `require`。

## 相关规则

C5、C5a、C8
