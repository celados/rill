---
type: Reference
title: RILL_REBUILD
description: >
  一个响应式 Element 确认依赖变化并标脏；载荷是 `写入 → 经过的 computed → reader` 路径。
when: An error, diagnostic or VM service record carries RILL_REBUILD.
code: RILL_REBUILD
severity: info
package: rill_flutter
rules: F2、R3a、D2
timestamp: 2026-11-18
---

# RILL_REBUILD

## 原因

一个响应式 Element 确认依赖变化并标脏；载荷是 `写入 → 经过的 computed → reader` 路径。

- 级别：info
- 来源：`package:rill_flutter`，经 `diagnosticHook`（仅在设置时）
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
diagnosticHook = (code, path) {
  if (code == 'RILL_REBUILD') debugPrint(path); // count @12 → busy → Headline
};
```

## 修法

不是错误。需要完整因果链（写入位置、写入来源、上一轮 effect）时用 `RillDebug.why(element)`、
`tester.whyRebuilt(...)` 或 VM service `ext.rill.why`。

## 相关规则

F2、R3a、D2
