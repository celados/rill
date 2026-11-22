---
type: Reference
title: RILL_EMPTY_QUERY
description: >
  `computedStream` 的流在发出任何值之前就结束了，这个问题没有答案。
when: An error, diagnostic or VM service record carries RILL_EMPTY_QUERY.
code: RILL_EMPTY_QUERY
severity: error
package: rill
rules: Q1、Q2
timestamp: 2026-11-21
---

# RILL_EMPTY_QUERY

## 原因

`computedStream` 的流在发出任何事件（值或错误）之前就结束了，这个问题没有答案。发过错误事件再结束的流保留那个错误，不报本码。

- 级别：error
- 来源：`package:rill`，经 `AsyncError` 状态
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
final user = computedStream((_) => const Stream<User>.empty());
await user.refresh();            // AsyncError(RILL_EMPTY_QUERY)
```

## 修法

流型查询至少要发出一个值或一个错误。确实可能为空时，在流里发出显式的空值（例如 `null` 或空列表），或改用 `computedAsync`。

## 相关规则

Q1、Q2
