---
type: Reference
title: RILL_WIDGET_INPUT_ESCAPED
description: >
  WidgetInput 离开了它的属主：在属主子树之外被读，或在属主的 didUpdateWidget / didChangeDependencies 之外被 sync。
when: An error or diagnostic carries RILL_WIDGET_INPUT_ESCAPED.
code: RILL_WIDGET_INPUT_ESCAPED
severity: error
package: rill_flutter
rules: F14、R3b
timestamp: 2026-11-21
---

# RILL_WIDGET_INPUT_ESCAPED

## 原因

`WidgetInput` 把 widget 配置带进图里，只在一个地方进、只往一个方向流。两种形式：

- **读者越界**：一次 `sync` 唤醒了属主子树之外的读者（兄弟或祖先里的 `Reactive`、`ReactivePaint`、合成层读者，或 `toListenable()` 的原生监听）。
  子树里的读者同帧更新；子树外的不能在 build 中标脏，只能晚一帧，显示一帧旧配置。消息列出这些读者。
- **sync 越界**：`sync` 不在属主的 `didUpdateWidget` / `didChangeDependencies` 里（`super` 调用之后）——在事件、post-frame 回调、`initState`、属主自己的 `build`、
  别的组件的 build 里，或属主已经销毁（`dispose` 体内也算）；或者位置对了，却包在 `batch` 里：flush 要等 `batch` 结束，子树里的读者会退回帧后、越界读者也不再报。

- 级别：error（debug）。读者越界经 `FlutterError.reportError` 报告，不抛：写入与传播已完成，越界读者在帧后更新；sync 越界抛 `FlutterError`，不写入。
- 来源：`package:rill_flutter`。release 不检查：越界读者静默晚一帧，越界 sync 是一次普通帧写。

## 触发

```dart
// 读者越界：控制器交给了兄弟组件
Column(children: [
  RawListbox(items: items, onController: (c) => shared = c),
  Reactive(builder: (_) => Text('${shared.focusOrder.value.length}')),  // 不在 RawListbox 子树里
]);

// sync 越界：在事件里同步配置
onTap: () => _items.sync(next),

// sync 越界：两个输入包在 batch 里
batch(() { _snaps.sync(widget.snaps); _minExtent.sync(widget.minExtent); });
```

## 修法

- 读者越界：把读者放进属主的子树（`OverlayPortal` 的浮层子节点算在内；独立的 `OverlayEntry` 不算）。子树外确实需要这个值时，让它有自己的源：父组件本来就持有配置，直接把配置或父的 signal 交给它。
  监听者如果本来就在属主子树内，直接用 `Reactive` 读 `.value`，不要用 `toListenable()`：原生监听没有宿主，位置不可知，一律算越界。
- sync 越界：配置只在 Flutter 换配置时进入——`didUpdateWidget` 里 `super` 之后 `sync(widget.x)`，依赖继承值的在 `didChangeDependencies` 里。
  随事件变化的是状态，不是配置：用 `Signal`，由事件写入。
- `batch` 里的 sync：去掉 `batch`。几个配置要一起变时合成一个 `WidgetInput`：不可变对象或 record，配 `equals`。
- 属主 `build` 里 `Builder` / `LayoutBuilder` 回调中的 sync 运行时拦不住，由 lint `rill_write_in_build` 报出；挪回 `didUpdateWidget` / `didChangeDependencies`。

## 相关规则

F14、R3b
