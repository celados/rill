---
type: Reference
title: RILL_DISPOSED
description: >
  对已销毁的 Scope 登记子 Scope、effect、Slot、`onDispose`，或把它作查询的 `keepAlive` 租约。
when: An error, diagnostic or VM service record carries RILL_DISPOSED.
code: RILL_DISPOSED
severity: error
package: rill
rules: C1
timestamp: 2026-11-20
---

# RILL_DISPOSED

## 原因

对已销毁的 Scope 登记子 Scope、effect、Slot、`onDispose`，或把它作查询的 `keepAlive` 租约。

v0.5.0 起只有 Scope 会被销毁：computed、查询、`linger`、`Pulse` 等派生节点不归任何所有者，读取它们不会抛这个码。
已销毁的 Scope 拒绝新登记是编程错误，release 下同样抛。

- 级别：error
- 来源：`package:rill`，经 `StateError`
- debug 下消息带 Scope 的名字与创建位置；未命名的显示为 `scope@file:line`（D1）。

## 触发

```dart
final session = store.child(name: 'session');
session.dispose();
session.slot();                                         // 抛 RILL_DISPOSED
session.effect(() => tunnel.state.value, (s, _, _) {});   // 抛 RILL_DISPOSED
computedAsync(load, keepAlive: session);                // 抛 RILL_DISPOSED：租约 Scope 已销毁
```

## 修法

作用在活着的 Scope 上登记（C1）。缓存的 Scope 指针不能证明它还活着，用之前查 `scope.disposed`；
跨会话的作用建在更长寿的 Scope 上，或者用顶层 `effect()` 自己持有停止函数。

## 相关规则

C1
