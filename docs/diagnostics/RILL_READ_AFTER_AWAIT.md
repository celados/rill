---
type: Reference
title: RILL_READ_AFTER_AWAIT
description: >
  查询在第一个 await 之后（或 `computedStream` 的 `async*` 体里）读取了响应式值（警告：这次读取不会成为依赖），或调用了 `q.wait`（抛错）。
when: An error, diagnostic or VM service record carries RILL_READ_AFTER_AWAIT.
code: RILL_READ_AFTER_AWAIT
severity: warning
package: rill
rules: Q4
timestamp: 2026-11-21
---

# RILL_READ_AFTER_AWAIT

## 原因

查询在第一个 await 之后读取了响应式值；这次读取不会成为依赖。同样适用于 `computedStream` 的函数是 `async*`：体在 listen 之后才开始运行，
依赖收集早已结束，体内的读取全部不追踪（lint `rill_async_star_stream` 在编译期拦这种写法）。

`q.wait(source)` 在第一个 await 之后（或 `async*` 体里、或在已结束的一轮的 `Query` 上）调用时**抛错**：debug 与 release 一样抛
`StateError('RILL_READ_AFTER_AWAIT: …')`，这一轮以它失败。`q.wait` 只在追踪期建立输入；await 之后的「只等待、不追踪」用法已删除
（它为一个违规用法维护了第二套生命周期）。

- 级别：读取是 warning；`q.wait` 是 error（抛出）
- 来源：读取经 `diagnosticHook`，未设置 hook 时 debug 下按调用位置去重，经 `Zone.current.print` 输出一次；`q.wait` 直接抛 `StateError`
- 打印格式：`RILL_X at <调用位置>: <节点> <原因与修法> (rill docs/diagnostics/RILL_X.md)`。
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
final user = computedAsync((_) async {
  final id = userId.value;       // 依赖
  final profile = await api.profile(id);
  return merge(profile, locale.value); // await 之后：报 RILL_READ_AFTER_AWAIT，locale 变化不会重问
});
```

## 修法

把所有需要追踪的读取与 `q.wait` 移到第一个 await 之前，存进局部变量；多个上游用 `await (q.wait(a), q.wait(b)).wait`，在同步部分全部登记。
确实只想要一次快照就用 `peek()`；确实只想要另一个查询的一次性终态、不想让它成为输入，用 `await source.settled()`。

`computedStream` 用同步函数：先读输入、调 `q.wait`，再返回 stream：

```dart
final messages = computedStream((q) {
  final room = roomId.value;                   // 追踪
  final token = q.wait(session.token);         // 同步调用：登记依赖
  return Stream.fromFuture(token).asyncExpand((t) => api.messages(room, t, cancel: q.cancelled));
});
```

## 相关规则

Q4；`q.wait` 是带比较器的依赖边，只在追踪期（第一个 await 之前）建立
