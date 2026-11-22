---
type: Reference
title: RILL_DROPPED_EVENT
description: >
  `Events(hold: true)` 在没有监听者期间积压的事件超过 `holdLimit`，最旧的一条被丢弃。
when: An error, diagnostic or VM service record carries RILL_DROPPED_EVENT.
code: RILL_DROPPED_EVENT
severity: warning
package: rill
rules: R21
timestamp: 2026-11-18
---

# RILL_DROPPED_EVENT

## 原因

`Events(hold: true)` 在没有监听者期间积压的事件超过 `holdLimit`（默认 16），最旧的一条被丢弃。

- 级别：warning，只在 debug 下报（`assert` 里），release 下照样丢最旧的一条但不提示
- 来源：`package:rill`，经 `diagnosticHook`；未设置 hook 时按调用位置去重，经 `Zone.current.print` 输出一次
- 打印格式：`RILL_DROPPED_EVENT at <emit 位置>: <事件流> <原因> (rill docs/diagnostics/RILL_DROPPED_EVENT.md)`。

## 触发

```dart
final notices = Events<String>(name: 'notices', hold: true);
for (var i = 0; i < 17; i++) notices.emit('$i'); // 还没有人 listen：第 17 条挤掉 '0'
```

## 修法

确认监听者确实会出现：hold 只覆盖"界面挂载前"这一段，不是长期缓冲。监听者长期缺席时改为状态（signal），
或在发出前合并同类事件；确实需要更多积压时调大 `holdLimit`。

## 相关规则

R21
