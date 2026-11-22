---
type: Reference
title: RILL_UNTRACKED_READ
description: >
  在帧阶段（build / layout / paint）读了 `.value`，但没有读者追踪它：值变化时界面不会更新。
when: An error, diagnostic or VM service record carries RILL_UNTRACKED_READ.
code: RILL_UNTRACKED_READ
severity: error
package: rill_flutter
rules: F3、F5、rill_untracked_read
timestamp: 2026-11-20
---

# RILL_UNTRACKED_READ

## 原因

在帧阶段（build / layout / paint）读了 `.value`，但没有读者追踪它：值变化时界面不会更新。

帧阶段由读写守卫共用的一个判定给出（F3 G1）：任一已知 BuildOwner 正在 build、`RenderObject.debugActiveLayout` 或 `debugActivePaint` 非空。
`initState` / `didUpdateWidget` / `didChangeDependencies` / `deactivate` 都在 build 阶段内。显式快照不报：`peek()`、`untracked`、effect 的 apply、
`Slot.run` 的 body 在第一个 await 之前的部分。

- 级别：error（v0.5.0 起；原来只 `debugPrint` 一次，layout / paint 里不报）
- 来源：`package:rill_flutter`，经 `FlutterError`：build 里成为 `ErrorWidget` 并上报，layout / paint 里经 `FlutterError.reportError`。只在 debug 下安装
- 消息带节点的名字与创建位置、读取的调用位置、所在阶段与三种修法。

## 触发

```dart
Reactive(builder: (_) => ListView.builder(
  itemBuilder: (_, i) => Text('${items.value[i]}'),   // itemBuilder 在列表项自己的 build 里运行，不在 Reactive 的追踪里
));

class _PageState extends State<Page> {
  @override
  void didUpdateWidget(Page old) {
    super.didUpdateWidget(old);
    _start(store.selected.value);                       // 生命周期里的快照
  }
}

class Bar extends CustomPainter {
  void paint(Canvas c, Size s) => c.drawRect(rect(level.value), paint);   // 普通 CustomPainter
}
```

## 修法

- 要随值更新：把读取放进响应式读者——在内层包 `Reactive`、用 `ReactiveLayoutBuilder` 等 F5 适配器、或把 painter 写成 `ReactivePainter` 交给 `ReactivePaint`。
- 只要快照：`peek()`。
- 生命周期调用的纯 Dart helper / async 方法（它们内部用 `.value`，因为也会被追踪路径调用）：在调用点包 `untracked(() => …)`。

lint `rill_untracked_read` 在会把 builder 留到以后执行的被调用方（构造 Widget / Route / OverlayEntry / `*Delegate`，返回 Future / Route / OverlayEntry 的函数）
与普通 `CustomPainter.paint` 上静态报出，并提供包入 `Reactive` 的 quick fix。

## 相关规则

F3、F5、`rill_untracked_read`
