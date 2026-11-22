---
type: Reference
title: RILL_INFINITE_LOOP
description: >
  一次刷新超过 100 轮仍未稳定：effect 的 apply 不断写入会再次唤醒自己的值；或流事件连续 100,000 代互相触发、始终不回到事件循环。
when: An error, diagnostic or VM service record carries RILL_INFINITE_LOOP.
code: RILL_INFINITE_LOOP
severity: error
package: rill
rules: R4、D2
timestamp: 2026-11-21
---

# RILL_INFINITE_LOOP

## 原因

一次刷新超过 100 轮仍未稳定：effect 的 apply 不断写入会再次唤醒自己的值。

查询的流事件在微任务里送达。一次送达里的用户代码（比较器、`onListen`、被唤醒的 effect）又给某个流发了值，
那个值在下一个微任务送达，算这一串的下一代；连续 100,000 代仍在互相触发（从未回到事件循环，计时器与帧都被饿死），这一串事件被丢弃，并以同一个码报出
（从发出事件的流回调所在的 Zone 抛出，作为未捕获的异步错误）。来自外部的事件（socket、计时器、帧里的写入）从第 0 代开始。

**冷展开的长 `q.wait` 链也会触发（已知限制）。** 从末端冷读一条从未展开过的 `q.wait` 链时，每一层要等下一层的查询函数运行才被发现，
每发现一层占一轮：100 层起在最上游开工之前就报这个码，即使没有任何写回或环（`Last writes: <none>`）。展开过、热着的链不受此限。v0.5.x 修复。

**异步控制器的回送不在上限里。** 100,000 代只数一次送达期间同步入队的事件；默认（异步）控制器的回送每次都在上一次送达之后入队，代数重新从零开始，
不会报这个码（与 v0.4.0 相同），循环会一直跑。

- 级别：error
- 来源：`package:rill`，经 `StateError`（debug 与 release）
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
final stop = effect(() => count.value, (value, _, _) {
  count.value = value + 1;       // 每轮都写，永不收敛
});
```

流事件的反馈：

```dart
final q = computedStream<int>((_) => controller.stream, equals: (a, b) {
  controller.add(b + 1);         // 每次比较都再发一个值
  return a == b;
});
```

## 修法

消息列出最后一轮写入的节点、它的创建位置与写入位置。让 apply 的写入收敛：写入前比较、只在条件变化时写，
或把派生值改成 computed。用 `RillDebug.why(stop)` 看每一轮由哪次写入触发。流事件的反馈：不要在比较器、`onListen` / `onCancel`
或由这个查询唤醒的 effect 里给它（或它的上游）的流发值。冷展开的长链：`Last writes: <none>` 且链有 100 层以上，就把链分段，先观察（或逐段 `settled()`）上游一段，再读末端。

## 相关规则

R4、D2
