---
type: Reference
title: RILL_CYCLE
description: >
  一个 computed 在求值时（直接或经由其它 computed）读到了它自己。
when: An error, diagnostic or VM service record carries RILL_CYCLE.
code: RILL_CYCLE
severity: error
package: rill
rules: §4.1、R6
timestamp: 2026-11-21
---

# RILL_CYCLE

## 原因

一个 computed 在求值时（直接或经由其它 computed）读到了它自己。

- 级别：error
- 来源：`package:rill`，经 `StateError`
- debug 下消息带节点的名字与创建位置；未命名的节点显示为 `kind@file:line`（D1）。

## 触发

```dart
late final Computed<int> a, b;
a = computed(() => b.value + 1);
b = computed(() => a.value + 1);
a.value;                         // 抛 RILL_CYCLE
```

## 修法

依赖图必须无环。把环上的一段改为 signal（由 effect 的 apply 或命令写入），或把两个值合并成一个 computed。
环是编程错误，rill 只保证两件事：

- **L0 不失控**：环不自激，两个环不互相唤醒，不栈溢出、不饿死事件循环。
- **L1 不永久毒化**：读到环的 computed 把错误存为状态，但从不缓存为已校验；它下一次冷读、重新挂载（再被观察）或它自己的输入变化时重新求值，
  环已解开就恢复。

**不提供** L2：环上没有环外输入的成员（例如上面从 `b` 进入时的 `a`），它热着的 effect 不会因为环外的变化被推送恢复，要等下一次冷读或重新挂载。

推论：**热着的环错误节点的下游，冷读也继承错误**。环解开后，若环上某个成员 `c` 仍被另一个页面观察（热着、没有环外输入变化），它照样保留 `RILL_CYCLE`；
已经零读者的下游 `b` 冷读或重新挂载时读到的就是 `c` 缓存的这个错误。卸载另一个页面后立即重挂也不算 `c` 冷却。等 `c` 的最后一个观察者离开、
或 `b` / `c` 自己的输入变化，冷读即恢复。

查询（`computedAsync` / `computedStream`）运行中才形成的环落成一次 `AsyncError(RILL_CYCLE)`，这是终态：查询不重试自己所在的环，
输入变化或 `invalidate()` 时重新提问。
await 之后的 `q.wait` 也参与防环：两个查询在 await 后互等，后登记的一方以 `RILL_CYCLE` 失败。

## 相关规则

§4.1、R6
