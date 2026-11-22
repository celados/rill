---
type: Reference
title: RILL_OPEN_REFRESH_BOUNDARY
description: >
  `wakes()` 在一个打开的刷新边界（batch、flush 或求值）里被调用，无法观察完整的一次刷新。
when: An error, diagnostic or VM service record carries RILL_OPEN_REFRESH_BOUNDARY.
code: RILL_OPEN_REFRESH_BOUNDARY
severity: error
package: rill_test
rules: R3a、§7
timestamp: 2026-11-18
---

# RILL_OPEN_REFRESH_BOUNDARY

## 原因

`wakes()` 在一个打开的刷新边界（batch、flush 或求值）里被调用，无法观察完整的一次刷新。

- 级别：error
- 来源：`package:rill_test`，经 `StateError`
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
batch(() {
  wakes([store.vitals], during: () => store.feed(tick));  // 抛 RILL_OPEN_REFRESH_BOUNDARY
});
```

## 修法

把 `batch` 放进 `during:` 里：`wakes([...], during: () => batch(() { ... }))`。

## 相关规则

R3a、§7
