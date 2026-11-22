---
type: Reference
title: RILL_WRITE_DURING_FRAME
description: >
  build、layout 或 paint 期间写入了 signal。
when: An error, diagnostic or VM service record carries RILL_WRITE_DURING_FRAME.
code: RILL_WRITE_DURING_FRAME
severity: error
package: rill_flutter
rules: F4、F12、R5、rill_write_in_build、rill_effect_in_lifecycle
timestamp: 2026-11-19
---

# RILL_WRITE_DURING_FRAME

## 原因

build、layout 或 paint 期间写入了 signal。

- 级别：error
- 来源：`package:rill_flutter`，经 `FlutterError`（debug）
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
Reactive(builder: (_) {
  seen.value = true;             // 抛 RILL_WRITE_DURING_FRAME
  return const SizedBox();
});
```

最常见的间接来源是在 `initState` 等生命周期里建普通 `effect`：它的首次 apply 是同步的，落在 build 里。

```dart
@override
void initState() {
  super.initState();
  effect(() => toasts.value, (t, _, _) { entries.value = t; });   // 首次 apply 在 build 中写
}
```

runApp 的首次 build 同步发生在帧外、调度相位仍是 idle，所以按 `schedulerPhase` 判断"现在能不能写"在根部挂载时会判错；
`pumpWidget` 在帧回调里 build，测不出这一点。

## 修法

从事件回调或 `addPostFrameCallback` 里写。需要随渲染派生的值用 computed。lint `rill_write_in_build` 报 build / paint 里的直接写入。

生命周期里的 effect 改用 `ReactiveState.watch`（F12）：compute 在挂载时追踪，首个 apply 在帧后，之后同步；State 销毁时自动释放。
lint `rill_effect_in_lifecycle` 报 State 成员与 `build` 里的 `effect(` 和 `scope.effect(`。组件库用 rill_test 的 `tester.mountApp(app)`
按 runApp 的方式挂载来测根部组件。不要用相位判断绕开守卫。

## 相关规则

F4、F12、R5、`rill_write_in_build`、`rill_effect_in_lifecycle`（[lint](../lint.md)）
