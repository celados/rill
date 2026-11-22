---
type: Reference
title: RILL_NO_VALUE
description: >
  `AsyncState.requireValue` 读到了 `AsyncLoading`：调用者断言此处有值，但这个问题还没有答案。
when: An error, diagnostic or VM service record carries RILL_NO_VALUE.
code: RILL_NO_VALUE
severity: error
package: rill
rules: Q2、F6
timestamp: 2026-11-20
---

# RILL_NO_VALUE

## 原因

`AsyncState.requireValue` 读到了 `AsyncLoading`：调用者断言此处有值，但这个问题还没有答案。`requireValue` 是门控之下的叶子用的显式断言，
不是控制流；抛出说明门控与叶子的前提被打破了。

- 级别：error
- 来源：`package:rill`，抛 `StateError('RILL_NO_VALUE: …')`；release 下同样抛
- `AsyncError` 上的 `requireValue` 不报这个码，而是以原对象和原栈重抛错误

## 触发

```dart
Reactive(builder: (_) => AnimatedSwitcher(
  duration: kThemeAnimationDuration,
  child: switch (user.value) {
    AsyncData() => const ProfilePage(),   // 叶子里 user.value.requireValue
    AsyncLoading() => const Skeleton(),
    AsyncError() => const ErrorView(),
  },
));
// 刷新失败后再进入新问题：淡出期的旧 ProfilePage 继续重建，读到 AsyncLoading 抛 RILL_NO_VALUE
```

## 修法

叶子只在门控同步卸载它时才能 `requireValue`（门控与叶子在同一次 buildScope 里、父先于子 build）。门控与叶子之间有过渡（`AnimatedSwitcher`、路由转场、`Hero`）、
叶子里有 `watch` / `effect`、或门控在刷新失败时保页，都不满足这个前提。改为：

- **门控传值**：`AsyncData(:final value) => ProfilePage(user: value)`，叶子读构造参数；
- 或叶子自己 `switch`，非 `AsyncData` 时返回 `const SizedBox.shrink()`，保页场景用 `valueOrNull`。

## 相关规则

Q2、F6
