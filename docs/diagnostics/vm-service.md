---
type: Reference
title: rill VM service extensions
description: >
  JSON shapes of ext.rill.graph, ext.rill.why and ext.rill.active, how to call them from a
  debug Dart or Flutter process, and what they return in release builds.
when: Reading rill's dependency graph, rebuild causes or live resources from a running process,
  by hand, from DevTools or through the Dart MCP vm_service tool.
timestamp: 2026-11-21
---

# VM service 扩展（D3）

debug 下（开启 asserts）创建第一个 rill 节点或 Scope 时，`package:rill` 在当前 isolate 注册三个扩展。
release 与 `--no-enable-asserts` 下不注册、不记录；AOT 编译后这些代码与扩展名都不在产物里
（[进程测试](../../packages/rill/test/process/vm_service_test.dart)）。每个结果都带 `type` 与 `enabled`。
同一份数据也可在进程内取：`RillDebug.graph()`、`RillDebug.whyJson()`、`RillDebug.active()`（`package:rill/debug.dart`）。

调用方式：

```sh
dart --enable-asserts --enable-vm-service=0 bin/app.dart     # flutter run 的 debug 模式自带
# HTTP：GET http://127.0.0.1:<port>/<token>=/ext.rill.why?isolateId=isolates/<id>&target=render
```

Dart：`service.callServiceExtension('ext.rill.why', isolateId: id, args: {'target': 'render'})`
（`package:vm_service`）。agent 用 Dart MCP 的 `vm_service` 工具调用同名方法。

## 节点身份

所有记录用同一种节点身份 `NodeInfo`：

| 字段 | 含义 |
| --- | --- |
| `id` | 进程内稳定的调试编号，图里的边用它引用 |
| `kind` | `signal`、`wireSignal`、`computed`、`asyncComputed`、`effect`、`observer`、`queryInputs`、`scope`、`slot`、`task` |
| `name` | 创建时传入的名字，可为 null |
| `label` | 名字；未命名时为 `kind@file:line`；内部节点按所有者命名（`sync.busy`、`user.state`、`sync.task`）；observer 为它的 reader（Element / painter） |
| `location` | 创建位置 `file:line`：第一个不属于 rill、SDK 与 Flutter 框架的栈帧；observer 为 null |

节点值默认不导出（应用的值可能是敏感数据），只给 `valueType`。

## `ext.rill.graph`

参数：`limit`（默认 2000）。结构：

```json
{
  "type": "RillGraph", "enabled": true, "revisionClock": 11, "count": 5, "truncated": false,
  "nodes": [
    {
      "id": 3, "kind": "computed", "name": "doubled", "label": "doubled",
      "location": "test/process/fixtures/app.dart:13",
      "version": 10, "revision": 10, "dirty": false, "pending": false, "disposed": false,
      "failed": false, "valueType": "int", "deps": [4], "subs": [2]
    }
  ]
}
```

- `version`：图消费的版本（下游据此判断是否变化）。`revision`：Readable 的修订号（C3a；signal 每次有效安装都推进，批内的回写可使它领先于 `version`）。
- `deps` / `subs`：依赖与订阅者的 `id`。无订阅者的 computed 不在上游的 `subs` 里。
- 可选字段：`failed`（computed 处于错误状态）、`valueType`、`state` / `stateNode` / `inputsNode`（asyncComputed）、`owner`（effect 的 Scope）、`runs`（effect 与 observer 的运行次数）、`ownedBy`。
- 节点登记用弱引用，已被回收的节点不出现；`count` 是仍存活的节点数。

## `ext.rill.why`

参数：`target`（节点 `id`、名字或 label；省略为全部）、`limit`（最新的 N 条）。保留最近 `RillDebug.capacity`（默认 128）次 reader 运行；
写入与 computed 变化另存最近 4096 条，超出的显示为 `unrecorded`。

```json
{
  "type": "RillWhy", "enabled": true, "capacity": 128,
  "records": [
    {
      "seq": 3, "kind": "effect", "run": 3, "initial": false, "time": "2026-11-18T18:51:46.265629",
      "node": {"id": 1, "kind": "effect", "name": "render", "label": "render", "location": "test/process/fixtures/app.dart:18"},
      "causes": [
        {
          "node": {"id": 2, "kind": "computed", "label": "computed@test/process/fixtures/app.dart:15", "...": "..."},
          "revision": 11, "previous": 8, "change": "value",
          "causes": [
            {
              "node": {"id": 3, "label": "doubled", "...": "..."},
              "revision": 10, "previous": 7, "change": "value",
              "causes": [
                {
                  "node": {"id": 4, "label": "count", "...": "..."},
                  "revision": 9, "previous": 6, "change": "write",
                  "site": "test/process/fixtures/app.dart:27", "causes": []
                }
              ]
            }
          ]
        }
      ],
      "text": "effect render (test/process/fixtures/app.dart:18) ran (#3)\n  ← computed@test/process/fixtures/app.dart:15 changed @11\n    ← computed doubled (test/process/fixtures/app.dart:13) changed @10\n      ← signal count (test/process/fixtures/app.dart:11) written @9 at test/process/fixtures/app.dart:27"
    }
  ]
}
```

- 记录的 `kind`：`effect`（compute 重跑）、`observer`（Flutter Element 或 painter 在刷新边界确认变化后标脏，F2）、`query`（AsyncComputed 因输入变化重问）。
  等值的派生不唤醒 reader，也就没有记录。
- `causes` 是这次运行消费的、与上次不同的输入；`revision` 是新版本、`previous` 是上次消费的版本（新依赖为 null）。
- `change`：`write`（叶子写入）、`value`（computed 输出变了）、`error`（computed 进入错误状态）、`initial`（首次求值）、`unrecorded`（已滚出缓冲）。
- 写入还带 `site`（写入调用位置）与 `origin`：`publish by <slot>.task`、`bare write in <slot>.task`、`apply of <effect>`、`settle of <query>`（落地）、`retry of <query>`（重试号：`invalidate`、冷却失效、过期重取）、`bookkeeping of <slot>`；
  由某个 effect 的 apply 写入时，`trigger` 嵌入那次 effect 运行及其原因，于是多轮刷新能一路追到根写入。
- 一次 batch 里同一个 signal 写了多次时，记录的是 reader 实际消费的那一次。

## `ext.rill.active`

```json
{
  "type": "RillActive", "enabled": true,
  "counts": {"tasks": 1, "pulses": 0, "bindingTimers": 0, "effects": 1},
  "effects": [{"id": 1, "kind": "effect", "label": "render", "location": "…:18", "runs": 3, "deps": [2], "owner": 5}],
  "tasks": [{
    "id": 8, "kind": "task", "label": "sync.task", "location": "…:25",
    "slot": {"id": 7, "kind": "slot", "label": "sync", "location": "…:23"},
    "policy": "supersede", "key": "poll", "queued": false, "stale": null, "parent": null
  }],
  "scopes": [{
    "id": 5, "kind": "scope", "label": "app", "location": "…:10",
    "slots": [], "effects": [1], "callbacks": 0,
    "children": [{"id": 9, "kind": "scope", "label": "session", "slots": [7], "children": [], "...": "..."}]
  }],
  "pulses": [{"id": 12, "kind": "signal", "label": "signal@lib/now.dart:31", "periodMs": 1000, "decorative": false, "running": true, "readers": 1}]
}
```

- `effects`：未停止的 effect。`tasks`：各 Slot 的在途任务（含排队中的 `queued: true`），`stale` 为已失效的原因。
- `scopes`：存活的根 Scope 及其子树；`slots` / `effects` 是该 Scope 拥有的节点 `id`（computed 不归 Scope），`callbacks` 是 `onDispose` 等清理回调的数量，`children` 是子 Scope。
- `pulses`：仅在 `rill_flutter` 加载后出现；列出有订阅者的 `Pulse` 时间源，`running` 表示计时器在跑（不可见时暂停，F9）。
- `counts` 与 `rill_test` 的 `expectIdle` 用同一组计数。
