---
type: Reference
title: RILL_INVALID_SUBSCRIBER
description: >
  绑定层对一个已释放或正在追踪中的订阅者调用了 `track`。
when: An error, diagnostic or VM service record carries RILL_INVALID_SUBSCRIBER.
code: RILL_INVALID_SUBSCRIBER
severity: error
package: rill
rules: F1、F7
timestamp: 2026-11-18
---

# RILL_INVALID_SUBSCRIBER

## 原因

绑定层对一个已释放或正在追踪中的订阅者调用了 `track`。

- 级别：error
- 来源：`package:rill`，经 `StateError`
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
final observer = MyObserver();   // package:rill/internal.dart 的 Subscriber
observer.dispose();
observer.track(() => count.value); // 抛 RILL_INVALID_SUBSCRIBER
```

## 修法

只在绑定代码里出现（`package:rill/internal.dart`）。释放后的订阅者不能复用，重新创建一个；
不要在 `track` 的回调里再次 `track` 同一个订阅者。

## 相关规则

F1、F7
