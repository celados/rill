---
type: Reference
title: RILL_COLD_QUERY_READ
description: >
  在任何观察者之外读取了一个从未开工的查询的 `.value`；查询只在被观察时工作，这次读取只会得到当前状态（通常是 `AsyncLoading`）。
when: An error, diagnostic or VM service record carries RILL_COLD_QUERY_READ.
code: RILL_COLD_QUERY_READ
severity: info
package: rill
rules: Q5、Q6
timestamp: 2026-11-20
---

# RILL_COLD_QUERY_READ

## 原因

在任何观察者之外（追踪域外、`untracked` 之外）读取了 `AsyncComputed.value`，一个微任务之后这个查询仍不被观察、也从未开工。
查询只在被观察时工作（Q5）：读取本身从不开工，所以这次读取得到的是当前状态，通常是永远的 `AsyncLoading`。

- 级别：info，每个查询只提示一次
- 来源：`package:rill`，debug 下经 `diagnosticHook`；未设置 hook 时按调用位置去重，经 `Zone.current.print` 输出一次
- `peek()` 豁免：它是正常的状态判断（例如组件库 `initState` 里取初值）

## 触发

```dart
final user = computedAsync((q) => api.profile(cancel: q.cancelled));

test('loads the profile', () {
  expect(user.value, isA<AsyncData<Profile>>());   // 永远是 AsyncLoading；一个微任务后提示 RILL_COLD_QUERY_READ
});
```

## 修法

- 要答案就等它：`await user.settled()`（等待期间查询被观察，所以会开工）；
- 要随数据更新：在 `Reactive`、effect、`ReactiveState.watch` 或热 computed 里读它；
- 只想看一眼当前状态：用 `peek()`。

## 相关规则

Q5、Q6
