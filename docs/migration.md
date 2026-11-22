---
type: Reference
title: rill migration log
description: >
  Every incompatible change since v0.2.1 (the migration baseline),
  per release: what was renamed or removed, how a signature or timing changed, and how to rewrite old code.
when: Upgrading a consumer across rill releases, or making a breaking change in rill (append an entry in the same commit).
---

# rill 迁移记录

基线：**v0.2.1**（`ecfe1ace5f76ddfdafcae4cd05e22e44b84fb3d6`）。
消费方升级时从基线往下逐条做完。**每个不兼容改动在同一个提交里追加一条**：改了什么、签名/时序怎么变、旧写法怎么改。
只改内部实现、对调用方无感的改动不记。

公开仓库的历史从 v0.7.3 开始。v0.7.3 之前各节里的 SHA 指公开前的历史，在本仓库查不到；它们只用来对照消费方原来写的 `ref`。

## v0.3.0（`5b5744e`）

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `Readable<T>.listenable` getter 改为方法：每次调用都新建适配器，getter 隐藏了分配 | `count.listenable` | `count.toListenable()`，在 `initState` / 字段里建一次，不要在 `build` 里建 |
| `ValueListenable<T>.signal` getter 改为方法，扩展名 `AnimationSignal` → `ListenableReadable` | `animation.signal` | `animation.toReadable()`，同样只建一次 |
| `Pulse.every` / `Pulse.phase` 同参数调用在有 reader 期间返回同一个源（原来每次调用一个新 Timer） | 为了共享而手工缓存 `Pulse.every(...)` 的静态字段 | 可删掉缓存，直接调用；行为不变只是不再重复建 Timer。`Pulse.minute` 现为 `every(1 min)` 的 getter |
| `RILL_INFINITE_LOOP`（flush 超 100 轮）在 release 下也抛 `StateError`，原来只在 debug | 依赖 release 下 effect 反馈环“自己停下” | 修掉反馈环；release 不再静默卡死 UI 线程 |
| `rill_create_in_build` 也报 `computedStream(...)` 与 `linger(...)` | 在 `build` 里建它们 | 挪到 State 字段 / store |

无签名变化的行为改动：`Slot.run`、`computedAsync` 在 release 下不再 fork Zone（只服务 debug 诊断归因）。

## v0.3.1（`2c39390`）

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 帧内托管写唤醒的 effect（含 `ReactiveState.watch` 的每一次 apply）改到 post-frame 执行（proposal R3b）。托管写包括：`toReadable()` 桥镜像 notifier 的每次变化（在 build、`didUpdateWidget`、layout 里，**也包括在事件里**改 notifier）、`Pulse` 的读时校准与恢复运行时的追平、`linger` 的读前准备。Pulse 计时器到点、普通 `signal` 写入、Task 发布仍同步 | effect / `watch` 的 apply 依赖桥或 Pulse 校准，期望在改 notifier 的那一行之后、或同一个 build 里就看到 apply 的结果（例如 apply 写的 signal 被同帧后面的 build 读到，或事件处理器里改完 notifier 立刻读 apply 的产物） | 要同帧在 build 里拿到的值改成**派生**：用 `computed` 从同一个源算出来，让 `Reactive` 直接读，不经 effect 中转。事件里需要立刻生效的写入直接写 rill `signal`（普通写，R3 同步），不要绕道原生 notifier → 桥。测试里改完 notifier 要 `await tester.pump()` 后再断言 apply 的结果。原来 apply 在 build 里写入会报 `RILL_WRITE_DURING_FRAME`，现在不再报 |

## v0.4.0（`4dabc4e`，异步派生）

> 不用 `computedAsync` / `Loading` / `Errored` 的使用方只需核对 `expectIdle`、`rill/internal.dart` 与 `Subscriber.failureSource` 三处；
> 直接消费异步状态的重点看「多态消费」与「状态构造」。

**查询的类型与读法**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `AsyncComputed<T>` 不再是 `Readable<T>`，而是 `Readable<AsyncState<T>>`（它是 `Computed<AsyncState<T>>` 的库内子类：`is Computed` 为真）；`.state` getter 删除 | `user.state`（状态）、`user.value`（值，加载中抛 `NotReady`） | `user.value` / `user.peek()` 就是状态：`switch (user.value) { AsyncData(:final value) => …, AsyncLoading() => …, AsyncError(:final error) => … }`。对 `Readable` 做 `switch` 的代码里，`case AsyncComputed()` 要写在 `case Computed()` 之前 |
| 把查询当 `Readable<T>` 传给组件 / `toListenable()` / `linger` 现在是编译错误 | `Avatar(user: store.user)`（`Readable<User>` 参数） | 组件参数改为 `Readable<AsyncState<User>>`；或调用方 `switch` 后传值；只要值的派生用 `computed(() => store.user.value.valueOrNull)` |
| `NotReady` 删除 | `try { q.value } on NotReady { … }`、`computed(() => q.value)` 靠抛出传播加载态 | 读状态：`q.value.valueOrNull`、`q.value.map(f)`、`(a.value, b.value).all` |
| 追踪域外 `.value` / `peek()` 首载中不再抛 `RILL_PENDING_ASYNC_UNTRACKED_READ` | `initState` 里 `q.peek()` 首载时崩 | 返回 `AsyncLoading`；要等答案用 `await q.settled()` |
| 读取不再开工；只有被观察的查询才工作 | 追踪域外读一次 `q.state` 就会启动加载并从此常驻 | 被观察 = 有 `Reactive` / effect / 热 computed 读它，或 `settled()` / `refresh()` 正在等，或被观察的下游 `q.wait` 它；开工在那次刷新的末尾。冷读只返回状态（输入已变时是 `stale` 且 `refreshing`，意为待取）；测试里 `await q.settled()`，debug 会提示 `RILL_COLD_QUERY_READ` |
| `AsyncState` 三个变体有公开 const 构造（原来只有私有 `._`） | 测试 / mock 无法构造状态 | `const AsyncLoading<User>()`、`AsyncData(user, refreshing: true)`、`AsyncError(e, s)`、`AsyncError.withPrevious(e, s, old)`；`Readable.constant(const AsyncLoading<User>())` |
| `AsyncError` 增 `hasPrevious`；「有旧值」以它为准 | `if (state.previous != null)` | `if (state.hasPrevious)`（`T` 可空时 `previous == null` 也可能是旧值） |
| 新问题 B 失败后重试 B、或再切到新问题 C，期间显示加载态，不再拿上一个问题 A 的值顶上（Q3） | — | 无需改写；依赖「重试时仍显示 A」的 UI 改为自己记住上一次的值 |
| `AsyncState` 增 `valueOrNull`、`requireValue`、`map`、`(a, b).all`、`Iterable.all`；变体实现 `==`（不看类型参数：`AsyncLoading<num>() == AsyncLoading<int>()`，两个方向一致） | 手写 n×3 种组合 | 用组合子；`requireValue` 只在门控同步卸载叶子时用（见下） |

**生命周期：冷却与所有权**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 查询不再归环境 Scope（`scope.run` / `Reactive` 的 build）所有，不再有 `RILL_DISPOSED`；无观察者时自己冷却 | 在 store 的 `scope.run(() => computedAsync(…))` 里创建，靠 Scope 销毁停止 | 直接 `computedAsync(…)`；最后一个观察者离开时冷却（默认一个微任务后取消在途、丢弃答案）。查询读到的 computed 被销毁时，被观察的查询落成 `AsyncError(RILL_DISPOSED)` |
| 新参数 `retain`、`keepAlive`、`equals` | 无人观察时照样重载 / 常驻 | 往返不想重取：`retain: Duration(seconds: 30)`（逻辑 TTL：期内回来沿用答案；过期后冷读与回来的首帧就是 `AsyncData(旧值, refreshing: true)`，被观察即同问题重取；不是内存释放定时器）；串联时上游的 `retain` 不短于下游，否则回来会重问上游一次；跟随某个 Scope 保活：`keepAlive: session.scope`（租约：期内不丢答案、不取消在途与流，但持有的错误照样在冷却时失效；Scope 销毁时不强杀仍在用的读者；传入已销毁的 Scope 抛 `RILL_DISPOSED`）；按值去重：`equals:`（相等的新答案沿用旧值引用，不唤醒读值的下游） |
| 无人观察时上游写入不再触发重载；重新观察时只校验输入，`retain` 内不重取 | 依赖「后台一直在刷新」 | 需要新鲜度就把时间 / 前台状态做成输入（`Pulse`、lifecycle signal），或调用 `invalidate()` |
| `RILL_CANCELLED_QUERY` 删除：`keepAlive` 的 Scope 销毁不再让 `settled()` / `refresh()` 以该错误结束 | `settled()` 结果里判 `RILL_CANCELLED_QUERY` | 删掉该分支；等待者会拿到真实答案 |

**刷新、重试、串联**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 新增 `invalidate()`：让答案到期，不发请求、不增加观察者；被观察时同问题重取，冷着时保留答案、下次被观察再取；下游重试会先重试它等过的失败上游 | 重试按钮 `onRetry: q.refresh`；写操作后手动 `refresh()` | `onRetry: q.invalidate`；写后 `q.invalidate()`。`refresh()` 只在需要 `Future` 时用（`RefreshIndicator.onRefresh: q.refresh`） |
| `refresh()` / `settled()` 等到 `!stale && !refreshing` 才完成 | 刷新中 `settled()` 立即返回旧值 | 无需改写；依赖旧行为的测试改为等待终态 |
| 串联用 `q.wait(source)`，不再在 fn 里读 `source.value` 抛 `NotReady` | `computedAsync((q) async { final t = token.value; … })` | `computedAsync((q) async { final t = await q.wait(token); … })`，在第一个 await 之前调用（await 之后调用只等待、不追踪，debug 报 `RILL_READ_AFTER_AWAIT`）。上游落地不取消正在等它的下游；上游换问题、答案按 `equals` 变化或从失败恢复才让下游重取。`q.wait` 等终态：上游正在刷新时等刷完；上游刷新失败（`AsyncError.withPrevious`）时新发起的 `q.wait` 以错误结束，已拿到旧值的下游不受打扰。`q.wait` 成环（自等、互等、与同步读取混合）以 `RILL_CYCLE` 失败 |
| `computedStream` 的 fn 必须是同步函数；新 lint `rill_async_star_stream` | `computedStream((q) async* { final id = userId.value; yield* db.watch(id); })`（依赖从未被追踪） | `computedStream((q) { final id = userId.value; return db.watch(id); })`；串联查询：`Stream.fromFuture(q.wait(token)).asyncExpand(…)` |
| `Query` 的回调参数名惯例 `ctx` → `q`（仅文档） | `computedAsync((ctx) async { … ctx.cancelled … })` | `computedAsync((q) async { … q.cancelled … })`，可选 |

**Flutter**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `Reactive` 不再接住 build 里的读取异常，`_ReactiveElement` 少两个 InheritedWidget 依赖 | — | 无需改写；父级用内联闭包重建时不再标脏被保留的 reader |
| `Loading` 删除 | `Loading(fallback: (_) => const Spinner(), child: Reactive(builder: (_) => Text(user.value.name)))` | `Reactive(builder: (_) => switch (user.value) { AsyncData(:final value) => Text(value.name), AsyncLoading() => const Spinner(), AsyncError(:final error) => ErrorView(error) })` |
| `Errored` 删除（含它的 `retry` 回调） | `Errored(fallback: (_, error, retry) => ErrorView(error, onRetry: retry), child: …)` | 在 `switch` 的 `AsyncError` 分支里渲染，重试用 `q.invalidate` |
| 一处加载 UI 盖多个叶子 | `Loading` 包住整页（实际每个 reader 各渲染一个 fallback） | 页面门控 `switch ((a.value, b.value).all)`；`AsyncData(:final value) => Page(data: value)` 向下传值。叶子 `requireValue` 仅在门控同步卸载叶子时安全，`AnimatedSwitcher` / 路由转场 / 叶子里的 `watch` / 刷新失败保页都不行 |
| 同步 `computed` 在 `Reactive` 里抛出不再被 `Errored` 接住 | 依赖 `Errored` 显示同步 computed 的错误 | Flutter 常规 `ErrorWidget` + `FlutterError.reportError`；预期中的失败建模成 `AsyncError` 或普通状态 |

**诊断码、导出与测试**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 删除诊断码 `RILL_LOADING_WITHOUT_BOUNDARY`、`RILL_PENDING_ASYNC_UNTRACKED_READ`、`RILL_CAUGHT_REACTIVE_READ`、`RILL_CANCELLED_QUERY` | 测试里断言这些码 | 删掉断言；`RILL_CAUGHT_REACTIVE_READ` 对应的 `try { … } catch` 在 computed 里本就合法（R7） |
| 新增 `RILL_NO_VALUE`（`requireValue` 读到 `AsyncLoading`）、`RILL_COLD_QUERY_READ`（debug 提示） | — | 见 `docs/diagnostics/` |
| `rill/rill.dart` 不再导出 `NotReady`，新增导出 `AsyncStateAll2`–`AsyncStateAll6`、`AsyncStateIterableAll`（`.all` 组合子）；`rill/internal.dart` 不再导出 `BindingFailure`、`retryBindingRead`，新增 `activeQueryCount`、`activeQueryStreamCount`、`activeQueryTimerCount` | 自定义绑定用 `BindingFailure` / `retryBindingRead` 做失败匹配与重试 | 删掉；失败按 Flutter 常规上报 |
| `Subscriber.failureSource` 删除 | 自定义 `Subscriber` 子类在 `track` 外接住异常后查失败来源 | 删掉；需要错误就直接 catch，查询的失败读 `AsyncError` |
| `linger` 的失败路径改为原样重抛（原对象与原栈），不再经 `BindingFailure` | — | 无需改写 |
| rill 核心新增依赖 `package:clock`（`retain` 的懒过期读 `clock.now()`，`fake_async` / `testWidgets` 的假时间自动生效） | — | 无需改写 |
| `expectIdle` 多查三项：在途查询、活跃流订阅、查询取消 Timer；查询开工也计入活动（与 `Slot.run` 一样，两次 pump 之间启停的查询也会让它失败），失败原因文案改为 `A rill task, timer or query started.` | 页面 pop 后查询仍在跑也能过 | 结束前完成假请求，或卸载后 `pump(retain)`；`keepAlive` 期内的查询会让它失败，属预期。对不用查询的代码三项恒为 0；断言旧文案 `A rill task or timer started` 的测试改文案 |
| `RillDebug.graph()` / `ext.rill.graph` 里一个查询是多个节点：查询本身（多出 `state`、`questionNode`、`generation`、`retry`、`observed`、`inFlight`、`streaming`、`retainMs`、`leased`、`waits` 字段）加上它的内部节点（问题、重试号、落地、答案），内部节点带 `ownedBy` 指回查询；写入来源新增 `retry of <query>`（`invalidate`、冷却失效、过期重取），落地仍是 `settle of <query>` | 按节点数或 kind 统计图的 DevTools 脚本 / 测试 | 统计时排除 `ownedBy` 指向查询的节点；按来源过滤写入的脚本认 `retry of` |
| lint 新增 `rill_async_star_stream`（`computedStream` 的实参是 `async*` / `async` 函数字面量） | — | `analysis_options.yaml` 的 `rill_lint.diagnostics` 加 `rill_async_star_stream: error`；按上面「`computedStream` 的 fn 必须是同步函数」改写 |
| `testWidgets` 里带 `retain > 0` 且仍在途的查询，卸载时会留下一个 Timer | — | 在测试体内完成假请求，或先 `pumpWidget(const SizedBox())` 再 `pump(retain)` |

## v0.5.0（`62b2f06`，2026-11-21，所有权显式化）

> 应用重点看「effect 签名」「没有环境所有者」「Context 删除」「painter」「读守卫」；组件库重点看「effect 签名」「painter」「弹层」「读守卫」。

**effect 签名**（所有调用点都要改）

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `effect`、`Scope.effect`、`ReactiveState.watch` 的 apply 改为 `(value, previous, onCleanup)`，返回 `void`；新导出 `typedef OnCleanup` | `effect(() => a.value, (v, previous) { …; return null; })`；`(v, _) { …; return sub.cancel; }` | `effect(() => a.value, (v, previous, _) { … })`；`(v, _, onCleanup) { final sub = …; onCleanup(sub.cancel); … }`。资源**在创建当下**登记，apply 之后抛错也会被清理；可多次登记，后登记先执行 |
| apply 返回之后再调用 `onCleanup`（异步续体里） | — | 登记到这个 effect 的当前一轮；effect 已停止则立即执行。旧一轮已被重跑取代后，它的续体再调 `onCleanup` 会挂到**当前**一轮，过期资源要等下一次重跑或停止才清理：异步工作走 `Slot`（取代即取消）或在续体里查自己的取消标记，不靠 `onCleanup` 收尾 |

**没有环境所有者**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `Scope.run` 删除；任何创建 API 都不再读「当前 Scope」 | `scope.run(() { effect(…); computed(…); })` | effect：`scope.effect(compute, apply)`（返回停止函数，可提前停，不接也不报 `unused_result`）；computed：直接 `computed(…)`，它不归任何所有者 |
| `computed` 不归 Scope，没有 dispose，读取不再抛 `RILL_DISPOSED` | 依赖 Scope 销毁后读 computed 抛错来发现「会话结束后还在读」 | 用数据表达结束（会话对象换新的、`attached` 为 false）；读者自己的寿命决定何时断开 |
| `late final` computed 不会再被首个读者拿走 | store 构造函数里逐个触碰 `late final` computed | 删掉这些空读 |
| `Scope()` 永远是根；子 Scope 只能 `parent.child()` | 在 `run` 或响应式 build 里 `Scope(name: …)`，隐式成为环境 Scope 的子 | 需要父子关系就写 `parent.child(name: …)`；在 build 里建 Scope 改到 State 生命周期里（lint `rill_create_in_build` 会报） |
| effect 的 apply 里建的 effect 不再挂到外层的所有者上 | apply 里裸写 `effect(…)` 或依赖外层所有者兜底 | 把内层的停止函数交给 `onCleanup`：`(v, _, onCleanup) { onCleanup(effect(…)); }`；多个资源就多次 `onCleanup` |
| `linger` 不归所有者：计时器只在有人读时存在 | 为每个 `linger` 建一个 Scope、`scope.run(() => linger(…))`，用完 `dispose` | 直接 `linger(source, d)`，不再需要 Scope；不用了就丢掉引用（例如列表不再为每行建 Scope，只存 `Readable`） |
| `rill/internal.dart` 不再导出 `rootScope`、`ownBindingResource`、`sameScopeBindings` | 自定义绑定用它们 | 根 Scope 用 `Scope()`；资源归显式传入的 Scope |

**Context 删除**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `Context`、`ContextValue`、`Scope(provide:)`、`child(provide:)`、`scope.use`、`Task.use` 删除 | `const _client = Context<ApiClient?>('client')`；`store.child(provide: [_client(c)])`；任务里 `t.use(_client)!` | 依赖放在会话对象上：`_Session` 加 `final ApiClient? client`；任务 body 捕获 `session.client`（类型就是契约，不再有 `RILL_MISSING_CONTEXT` 与 `fallback: null` 的问题） |
| `RillScope`、`RillScope.value`、`RillScope.of`、`context.use` 删除 | `RillScope(provide: [storeKey(store)], child: …)` + `context.use(storeKey)` | InheritedWidget（或 Provider 等）或构造参数；注入值变化时通知读者，不再销毁子树的作用与任务 |
| 只为安装守卫而包的 `RillScope`（测试里） | `RillScope(child: app)` | `await tester.mountApp(app)` 或 `debugInstallRillGuards(tester.binding.buildOwner!)` |
| 应用入口包的 `RillScope` | `runApp(RillScope(child: app))` | 直接去掉：首个 `Reactive` / `ReactivePaint` / `ReactiveState.watch` 自动安装守卫。根部纯 Widget 也要首帧就受守卫时，在 `runApp` 前 `WidgetsFlutterBinding.ensureInitialized()` 后调 `debugInstallRillGuards(WidgetsBinding.instance.buildOwner!)` |

**组件所有权**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 响应式 Element（`Reactive`、`ReactiveWidget`、`ReactiveStatefulWidget`）不再持有 Scope，build 只追踪 | — | 无需改写；`ReactiveStatefulWidget` + `ReactiveState` 现在只有一个 Scope（State 的） |
| 响应式 Element 被 GlobalKey 重挂（`activate`）时总是重建一次（与 `StatefulElement` 一致） | — | 无需改写；断言重挂后零 build 的测试按 +1 调整 |
| `context.onScope` 删除（连同 `RILL_MISSING_READER`） | `Reactive(builder: (context) { context.onScope('k', (scope) { … }); … })` | 改成 `StatefulWidget` + `ReactiveState`：资源在 `initState` 里建在 `scope` 上，作用用 `watch` |
| `ReactiveState.scope` 用 `Scope()` 建（原 `rootScope`），行为不变 | — | 无需改写 |
| `ReactiveState.scope` 的身份在销毁期间固定：`scope.onDispose` 回调里取 `scope` 得到正在销毁的那一个，在上面登记 effect / Slot / `onDispose` 抛 `RILL_DISPOSED`；`dispose` 之后首次取得到一个已销毁的 Scope（原来两种情况都会悄悄新建第二个根 Scope，登记的 effect 活过组件） | 清理回调里 `scope.effect(…)` 之类的再登记 | 删掉；清理期间要做的事直接在回调里做完 |

**可见性、绘制与弹层**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `Reactive` 不再每次 build 依赖 `TickerMode` 与 `MediaQuery`；`TickerMode` 翻转不重建任何 reader（读 Pulse 的 reader 只在校准值变了时同帧重建一次，不读的不重建） | 依赖 `TickerMode` 翻转让 reader 重建一次 | 需要随 `TickerMode` 改变画面的组件自己 `TickerMode.valuesOf(context)` |
| 读到 `Pulse.phase` 的 reader（及 `ReactivePaint`）对 `MediaQuery` 的 disableAnimations 建依赖，只在读到装饰时间源之后 | — | 无需改写 |
| `Pulse.every` / `Pulse.phase` 同参数调用从**创建起**返回同一个源（弱引用表，句柄活着就共享；原来要等到第一个读者订阅才登记，先存进两个字段再读会各开一个 Timer） | — | 无需改写；`identical(Pulse.minute, Pulse.minute)` 现在恒为真 |
| `ReactivePainter` 不再继承 `CustomPainter`；`draw` 改名 `paint`；只能交给 `ReactivePaint`（`painter` / `foregroundPainter` 的类型是 `ReactivePainter?`） | `class P extends ReactivePainter { void draw(Canvas c, Size s) … }`；`CustomPaint(painter: P())` | `void paint(Canvas c, Size s)`；挂在 `ReactivePaint(painter: P())`；`hitTest`、`semanticsBuilder`、`shouldRebuildSemantics` 照旧可覆盖（后者的形参是 `covariant ReactivePainter`，写成 `CustomPainter` 的要改）。静态 painter 用 Flutter 的 `CustomPaint`，与 reactive painter 混用就嵌套两层 |
| `ReactivePainter` 没有 `shouldRepaint`：**删掉每个子类的 `shouldRepaint` 覆盖**（留着带 `@override` 报 `override_on_non_overriding_member`，去掉 `@override` 也永远不会被调用）；`super(repaint: …)` 与 `addListener` / `removeListener` 覆盖同理删掉 | `@override bool shouldRepaint(P old) => old.color != color;` | 删除。重绘由 `paint` 里读到的 rill 值驱动；父级 build 交来**另一个** painter 实例（不 `identical`）时 `ReactivePaint` 换新 slot、重绘一次，同一实例不重绘。所以随参数变的 painter 要么每次 build 新建（等价于旧的 `shouldRepaint => true`），要么把参数做成 signal 在 `paint` 里读 |
| `RILL_SHARED_BARE_PAINTER`、`RILL_PAINTER_WITHOUT_VISIBILITY` 删除 | 测试里断言这两个码 | 删掉断言（类型上不可能再发生） |
| `showReactiveDialog`、`showReactiveModalBottomSheet` 删除；`rill_flutter` 不再依赖 `material_ui` | `showReactiveDialog(context: c, builder: (context) => …)` | `showDialog(context: c, builder: (_) => Reactive(builder: (context) => …))`；bottom sheet、`OverlayEntry`、自定义 route 同理。App 自己依赖 Material |

**环**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 环是编程错误：不再有全局环重试，任何写入都不再重试已失败的环。保证 L0（不自激、不互唤醒）与 L1（读到环的 computed 不缓存为已校验：冷读、重新挂载或它自己的输入变化即重新求值）；**不提供** L2：环上没有环外输入的成员，热着的 effect 不会被环外变化推送恢复；推论：这样一个仍被别处观察的成员，它的下游即使零读者，冷读或重新挂载也继承它的 `RILL_CYCLE` | 依赖一次无关写入或环外查询落地让热着的环成员自动恢复；卸载一个页面后指望它冷读的下游恢复，而另一个页面仍观察着环成员 | 消掉环（把一段改成 signal 或合并 computed）；过渡期要恢复就让该成员（所有观察它的页面）卸载或重挂后再冷读 |
| 查询运行中才形成的环落成终态 `AsyncError(RILL_CYCLE)`，只靠输入变化或 `invalidate()` 重新提问 | — | 无需改写；同上，修法是消掉环 |

**查询调度**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `keepAlive` 租约期内，一轮在途工作一旦没人要（冷读发现问题已变、冷态 `invalidate()`），立即结束：`q.cancelled` 完成、流订阅取消（原来租约期内会跑到自己结束，期间占着上游订阅）。租约只保留当前问题的答案 | 依赖租约让作废的一轮跑完、在它的续体里做副作用 | 副作用放到落地后的观察者里；需要旧问题的工作继续，就保持被观察 |
| `retain > 0` 冷着时，输入变化本身不再取消在途的一轮（冷态不采样问题）；冷读（`peek()` 等）发现问题已变时取消（R4c）。无冷读时在途工作留到 Timer 到期或落地，落地答案读作 `refreshing, stale` | 依赖冷态输入变化立刻取消 | 需要立刻取消就冷读一次或 `invalidate()` |
| **流事件一律在微任务里送达**：`computedStream` 是异步源，不管控制器是不是 `sync: true`，`data` / `error` / `done` 都经该轮自己的先进先出队列、在发出它的代码返回之后的微任务里送达；这一轮已被取消或作废时直接丢弃。原来同步控制器的事件在 `add` 那一行里就被查询看到（在 `batch` 里则在 batch 结束时），同一个 batch 里多个同步流之间还按依赖顺序原子排序。现在不承诺同步流在同一 batch 内跨流按拓扑原子排序，与标准异步 `Stream` / `Future` 一致：上游在自己的 `onListen` / `onCancel` / 比较器里发给别的流的值，到达之前下游可能先按旧答案开工或落地一次，随后被新值取代（读作 `stale`，再问新问题），最终值一致 | `ctl.add(1); expect(q.peek(), AsyncData(1))`；依赖同一个 batch 里几个同步流按上下游顺序生效 | 断言前 `await Future<void>.delayed(Duration.zero)`（widget 测试里 `await tester.pump()`）；需要原子地一起变的值放进同一个 signal / 同一个流事件，不要拆到几个同步流里靠顺序 |
| **`q.wait` 只能在第一个 `await` 之前调用**：之后调用在 debug 与 release 下都抛 `StateError('RILL_READ_AFTER_AWAIT: …')`，查询这一轮以它失败（原来只在 debug 报警告，然后作为「晚等待」照样等上游终态）。在已结束的一轮的 `Query` 上调用同样抛错 | `computedAsync((q) async { final a = await x(); return await q.wait(other); })` | 把 `q.wait(other)` 挪到第一个 `await` 之前（`final f = q.wait(other); final a = await x(); return await f;`），它会成为输入；确实只要一次性答案、不想追踪，用 `await other.settled()`（终态 `AsyncState`，取值用 `requireValue`） |
| 一个查询的一步在它第一次调用用户代码之后结束：流工厂（`computedStream` 的 fn）返回后，订阅由下一步建立，此前若最后一个读者已被移走就不再 `listen`（原来照样 `listen`，订阅留到 `retain` 到期）；一个 flush 里多个已解决的 `q.wait` 逐个投递，前一个的续体同步关闭了本轮的流时，后面的不再投递 | 依赖工厂里移走读者之后仍然订阅 | 无需改写 |
| 有限的查询链无论多深都不栈溢出；已展开的链不报 `RILL_INFINITE_LOOP`（冷展开的 `q.wait` 链例外，见下方已知限制 1）；真实反馈（例如流的订阅写回自己的输入、effect 每轮新建一个写回自己输入的查询）仍在 100 轮报 `RILL_INFINITE_LOOP`。经流事件的反馈（比较器、`onListen` 或被唤醒的 effect 每次都给同步控制器发值）现在跨微任务：连续 100,000 代互相触发才丢弃并报 `RILL_INFINITE_LOOP`（作为未捕获的异步错误，不再从发值的那一行同步抛出） | 测试里断言 `ctl.add(...)` 那一行同步抛 `RILL_INFINITE_LOOP` | 消掉反馈；测试里用 `runZonedGuarded` 接住它。彼此无上下游关系的查询之间的执行顺序不承诺 |

**已知限制**（与 v0.4.0 相同，不是回归）

1. 从末端冷读（或首次观察）一条从未展开过的 `q.wait` 链，每层占 flush 的一轮：99 层以内正常，100 层起在最上游开工之前报 `RILL_INFINITE_LOOP`（`Last writes: <none>`）。
   这么深的链先观察或 `settled()` 上游一段，再读末端。v0.5.x 修复。
2. 经流事件的反馈上限（100,000 代）只挡同步回送链：默认（异步）控制器的回送每次重新计代，不报错、一直跑（会回到事件循环）。修法是消掉反馈。

**读守卫与 lint**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 帧阶段（build / layout / paint）内无追踪的 `.value` 读取 debug 抛 `RILL_UNTRACKED_READ`（原来只 `debugPrint`，paint / layout 里连提示都没有） | 普通 `StatelessWidget.build`、`initState`、`didUpdateWidget`、`deactivate`、`ListView.builder` 的 itemBuilder、普通 `CustomPainter.paint` 里读 `.value` | 要更新就包 `Reactive` / 用 `ReactivePaint`；只要快照就 `peek()`；生命周期里调用的纯 Dart helper / async 方法在调用点包 `untracked(() => …)` |
| effect 的 apply、`Slot.run` 的 body（第一个 await 之前）不算漏追踪，也不再被外面的 `Reactive` 追踪（原来在 build 里启动的任务，body 首段的读取会成为这个 reader 的依赖） | 依赖 build 里启动的任务首段读取让 reader 重建 | 让 reader 自己读那个值 |
| `rill_untracked_read` 按类型识别 **Flutter 自己**会把 builder 留到以后执行的 API（Flutter 的 `Widget` / `Route` / `OverlayEntry` / `*Delegate` 构造、返回 `Future` / `Route` / `OverlayEntry` / `PersistentBottomSheetController` 的 Flutter 函数）的所有 widget builder 形参，以及 `CustomPainter.paint` | 只报 4 个构造函数与 2 个 Material 函数 | 新报出的位置按上一行改写；`build` 里同步调用的本地 helper、builder 里再嵌一层的闭包（`map` / `forEach` / `List.generate`）、`Reactive` 子类、Flutter 之外声明的 Widget 或函数（可能立即执行 builder）都不报，由运行时 `RILL_UNTRACKED_READ` 兜底（[lint 分层](lint.md#分层运行时守卫是权威)） |
| `rill_effect_in_lifecycle` 也报 `scope.effect(`；`rill_create_in_build` 也报 `Scope(`、`scope.child(`、`scope.effect(`、`scope.slot(` | — | State 里的作用用 `watch`；Scope 与 Slot 在 `initState` / 字段里建 |
| `RILL_DISPOSED` 只在对已销毁的 Scope 调 `child` / `effect` / `slot` / `onDispose` 或作 `keepAlive` 租约时抛；删除 `RILL_MISSING_SCOPE`、`RILL_MISSING_CONTEXT` | 测试里断言 computed 的 `RILL_DISPOSED` 或这两个码 | 删掉断言 |

## v0.6.0（`d001164`，2026-11-21，命令与发布层拆分）

> 从 v0.5.0 往下做（`Context` 已删，任务里用 `session.client`）。用命令层的使用方逐条过一遍；不用命令层的核对一遍即可。

**默认冲突语义**（行为变化，所有 `publish` 都要过一遍）

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 提交默认安装：写入不再因为「任务开始后别人装过这个字段」而失败；`overwrite:` 参数删除 | `p.set(x, v, overwrite: true)`；不带 `overwrite` 时依赖默认写集冲突让位 | `tx.set(x, v)`。依赖默认冲突让位的地方（例如轮询结果让位给期间落地的用户命令）改成显式条件：开工时 `final asked = Unchanged(x);`，提交里 `tx.require(asked)`（只让这一部分让位就放进 `tx.part`） |
| `Task.expect` 删除 | `t.expect(sweep);` 之后每次 `t.publish` 隐式带上读集 | 开工时 `final asked = Unchanged(sweep);`，每次需要它的提交里 `tx.require(asked)`；外部操作前 `if (!t.alive \|\| !asked.holds) return;`。v0.5.0 里 `expect` 对冷桥（无监听的 `toReadable()`、Pulse）先采样，`Unchanged` 的取基线与 `holds` 同样先采样，行为不变 |
| 同一任务先后两次 `publish`，且前一次写了受保护的字段 | `t.expect(x)` 后连续 `t.publish`：读集只防别人的写入，两次都成功 | `Unchanged` 是取值那一刻的基线，自己的写入也算变化：照搬成同一个 `asked` 两次 `require`，第二次返回 `false`。在自己的写入成功之后重取：`var asked = Unchanged(x); if (t.publish((tx) { tx.require(asked); tx.set(x, 1); })) asked = Unchanged(x);` 再做第二次提交（两次之间别人的写入照样让第二次失败） |
| `Slot.run` 的 `parent:` 删除 | `slot.run(body, parent: t)`：继承读集、写集基线、级联取消 | 读集：把 `Unchanged` 当参数传给子流程，body 首行 `if (!asked.holds) return;`，提交里 `require`。级联取消：让子任务的 Slot 归同一棵 Scope 树（会话、store、attempt）；需要「随父任务结束」就为这段流程建 `owner.child()` 并在结束时 dispose；父任务被 supersede 而页面仍存活时，还要把父任务的 `cancelled` 接到子 Scope 的销毁，见表后「父任务被取代时取消子流程」 |
| `t.alive` 只看寿命（所有者存活、未被作废、body 未结束） | `t.alive` 也包含读集是否冲突 | 另有条件时一起问：`t.alive && asked.holds` |

**父任务被取代时取消子流程**：`parent:` 原来会在父任务被 supersede 时级联作废子任务。迁移成子 Scope 之后，只在父 body 的 `finally` 里 dispose 子 Scope 不够：
父任务被取代时 body 并不会停下，它还在 `await` 子任务，`finally` 要等子任务结束才跑；页面（`owner`）仍然存活，子任务照常 `Done` 并写入（旧版是 `Stale`）。要显式把父任务的 `cancelled` 接到子 Scope 的销毁上：

```dart
final old = outer.run((t) async {
  final sub = owner.child();
  // 父任务一被作废（supersede 或所有者销毁）就销毁子 Scope：子任务交付 Stale，迟到的 publish 返回 false。
  unawaited(t.cancelled.then((_) => sub.dispose()));
  try {
    final step = await sub.slot().run(fetchStep);
    // …
  } finally {
    sub.dispose(); // 正常结束时的收尾；dispose 可重复调用
  }
});
```

`t.cancelled` 只在任务被作废时完成；body 正常结束时它不完成，回调连同 `sub` 随任务一起回收。整个页面销毁时子 Scope 本就随 `owner` 销毁，这一行只为「父任务被取代、页面还在」。

**提交与保存点**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `Publish` 改名 `Tx`；新增同步顶层 `transact((tx) { … })`，返回 `bool` | 假槽 + 从不 await 的 async 闭包 + 外部变量重抛 | `transact((tx) { … })`：先全部暂存再一起安装，暂存异常按原栈抛出。`t.publish` 与 `transact` 签名相同，可以作为函数值传给共用的暂存代码 |
| `p.optional(fn)` → `tx.part(fn)`：返回 `bool`；里面抛出的异常回滚这部分后按原对象与原栈重抛 | `final dropped = p.optional(fn); if (dropped != null && dropped is! StaleReason) throw dropped;`（丢栈） | 冲突让位、解码失败仍中止整次：`tx.part(fn)`。解码失败也只丢这部分：`try { tx.part(fn); } on FormatException catch (e) { … }` |
| 暂存函数运行期间对 signal 的裸写入 debug 报 `RILL_WRITE_IN_COMPUTATION` | 在解码器 / 暂存函数里顺手写别的 signal | 写入改成 `tx.set`；暂存函数里的读取（`x.peek()`）就是提交时刻的值 |
| `tx.require` 不抛异常 | 依赖 `_Conflict` 异常中断暂存 | 条件只登记、层结束时判定；想省掉后面的解码就先 `if (!asked.holds) return;` |
| 暂存函数里调用 `q.invalidate()` / `q.refresh()`、嵌套 `transact` / `t.publish`、`slot.run` debug 报 `RILL_WRITE_IN_COMPUTATION` | 在暂存函数里顺手让查询到期、启动后续命令 | 放到提交之后：`if (t.publish((tx) { … })) todos.invalidate();` |
| `part` 返回 `true` 之后被暂存期的重入破坏（release 下解码器写了条件的 source），整次提交返回 `false` | 原来那一部分被静默丢弃、整次仍返回 `true` | 无需改写；以返回值判断的代码（`if (published && shown)`）现在不会拿错账 |
| `Unchanged` 对 computed 只按拉取时的输出判定：热 computed 在一个 batch 或帧写推迟窗口里的往返也不算变化 | `t.expect(computed)` | 要逐次精确，以 computed 读的 signal 为条件（例如以几个槽各自的 `busy` 为条件） |
| `transact` 在 computed / effect 的 compute 里报 `RILL_WRITE_IN_COMPUTATION`，帧阶段里报 `RILL_WRITE_DURING_FRAME` | — | 与裸写入同样处理 |
| 暂存函数里裸调 `events.emit` debug 报 `RILL_WRITE_IN_COMPUTATION`（原来监听者当场收到，提交失败也收不回） | `transact((tx) { …; notices.emit('saved'); })` | `tx.emit(notices, 'saved')`：随提交安装后发出，提交失败或所在 `part` 被丢弃就不发 |
| 已失效任务（被作废或 body 已结束）的 Zone 里调用 `transact`，debug 报 `RILL_LATE_WRITE`（每个暂存目标一次；原来只有裸写入报） | await 之后用 `transact` 写，绕开迟到诊断 | 改成 `t.publish`：任务失效时返回 `false` 且不改状态。提交冲刷出的 effect 里的 `transact` 不报 |

**结果**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `Outcome` 新增 `Skipped`（`OnBusy.skip` 没有运行）；`StaleReason` 只剩 `superseded`、`ownerDisposed`（`conflicted`、`skipped` 删除） | `case Stale(reason: StaleReason.skipped)` | `case Skipped()`。switch 漏掉 `Skipped` 是编译错误，按编译器逐个补。`Skipped` 也在交付时裁决：所有者已销毁则是 `Stale(ownerDisposed)` |
| 结果在交付给调用者的那一刻裁决：所有者在任务结束与调用者恢复之间被销毁，交付 `Stale(ownerDisposed)` | `final o = await slot.run(…); if (session.scope.disposed) return null;`；`when !attempt.disposed`；widget 里对 `ReactiveState.scope` 上的槽 `if (!mounted) return` | 删掉这些手检：直接 await 拿到 `Done` 时所有者一定还活着。**只对所有者本身成立**：组件 `await store.save()`（槽在 store / 会话 Scope 上）之后仍要 `if (!mounted) return`；key 合并的多个调用者共享交付那一刻的裁决 |
| Task 句柄在 body 结束（返回或抛出）之后 `publish` 返回 `false` 并 debug 报 `RILL_CLOSED_PUBLICATION`；被作废的在途任务调 `publish` 照旧静默返回 `false` | 把句柄偷出 body、靠 `Completer` 悬住 body 再在外面发布 | 条件取成 `Unchanged` 值，在本任务的 body 里提交；不再需要第二个任务 |

**WireSignal 移出核心**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `WireSignal`、`Publish.feed` 删除；`package:rill/wire.dart` 新增 `Wire<T>`（不是 `Signal`，只用公开 API） | `final status = WireSignal<S?>(null, decode, name: 'status');` `p.feed(status, json)`；`status.value = null` | `final _status = Wire<S?>(null, decode, name: 'status'); Readable<S?> get status => _status.readable;` `_status.stage(tx, json)`；重置 `_status.set(tx, null)`（在 `transact` 或 `t.publish` 里）。读法不变。可传 `equals:` 自定义线上比较 |
| `RILL_CONFLICTED` 删除 | 测试里断言它 | 删掉断言 |

**调试工具**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `RillDebug.graph()` / `ext.rill.graph` 不再有 `wireSignal` 这个 kind；`Wire` 的账本是普通 signal，名为 `'<name>.ledger'`（无名为 `'wire.ledger'`） | DevTools 脚本 / 测试按 `kind == 'wireSignal'` 找 wire | 按名字找账本，或直接读 `wire.readable` |
| 在途任务的调试记录删掉 `parent` 字段；`stale` 只会是 `superseded` / `ownerDisposed` | 脚本读 `parent` 或判 `stale == 'conflicted'` / `'skipped'` | 删掉；被拒绝的提交改看新增的 `RillDebug.refusals([target])`（`package:rill/debug.dart` 导出 `RillRefusal`，`ext.rill.why` 的载荷多 `refusals` 数组） |
| `RillDebug.refusals(target)` 可按 Slot 实例或槽名（`'sweep'`）过滤，`RillRefusal` 带 `slot`；`condition` 只有 `task` / `unchanged`；`RillDebug.capacity` 调小时同步裁剪已记的拒绝，`whyJson(limit:)` 同样截断 `refusals` | 按任务标签 `'sweep.task'` 过滤 | 照旧可用；也可直接传槽 |

**lint**

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `rill_write_after_await` 也报 await 之后的 `transact(` | 用 `transact` 绕开规则 | 放进 Slot，用 `t.publish` |
| `rill_create_in_build` 也报 `Wire(` | — | 在 store 或 State 的生命周期里建 |
| `rill_write_in_computed`、`rill_write_in_build` 也报 `transact(` | — | 移出 computed / build |

**使用方提示**

- 多处并发重读同一目标的 `OnBusy.parallel` 槽（例如多处并发强制刷新账户）：默认安装之下，先发晚到的旧读会覆盖后发先到的新读（旧的默认 OCC 在先发先到时丢新读，同样不对）。迁移时改成 `supersede`，或按读取目标 `key` 合并；不要留在无保护的 `parallel`。
- 轮询响应里的某个字段原来靠默认写集冲突让位给期间落地的另一次写入（例如一次探测的结果）；现在开工时取该字段的 `Unchanged`，在 `tx.part` 里 `require`。忘写就是旧响应静默覆盖新结果。

**已知限制与不支持**

1. 挂起的 Future 只放开 rill 自己的引用：Scope 销毁后，切断的链对 Task 只留弱引用。body 自己的闭包仍随 Future 存活——`async` body 帧里的 `t`、作为 body 的页面方法所属的对象（Task 又持有所有者 Scope）——那是调用方的引用；要放开就把 `t.cancelled` 交给 RPC，让它真的结束。
2. debug 下，第一次在 body 里才被访问的惰性全局（例如 `final sdkReady = Completer<void>();` 写在顶层、首次在任务里取 `.future`）会记下那个任务的 debug Zone，从而留住**这一个**任务与它的 Scope。release 没有这个 Zone。共享 Future 在任务外创建即可。
3. 五条非目标：release 下暂存期回调的对抗性同步重入；同一次提交内对同一 Wire 重复 `stage` 或先 `set` 后 `stage`；`bindingSignal` 的 `beforeRead` 在暂存期同步触发 effect；`key:` 合并调用者之间的同步销毁与二次 Future 组合后的空窗；跨槽「后发者胜」（用 `Turn` 配方）与没有新任务时的 `Slot.cancel()`。
4. v0.5.0 的查询层已知限制不变（上一节「已知限制」两条，以及深链更新的二次方成本）。

## v0.7.0（`4b2eb13`，2026-11-21，配置输入与合成层直驱）

> 从 v0.6.0 往下做。写 raw widget（配置输入、sheet 一类的合成层直驱）的使用方重点看全部；其他使用方只需核对 `input` 命名冲突与 lint 一条。

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| 新增 `ReactiveState.input<T>(initial, {equals, name})` → `WidgetInput<T>`（`readable`、`sync`）；`sync` 只在属主的 `didUpdateWidget` / `didChangeDependencies` 里、`super` 之后（F14） | 控制器的配置 signal 在 post-frame 回调里写（spike 的做法：派生状态晚一帧、多一次 build）；或在 `didUpdateWidget` 里写 signal 撞 `RILL_WRITE_DURING_FRAME`；或每次 build 给控制器一个新的常量 `Readable` | `late final _items = input(widget.items, equals: Equality.deep);` 把 `_items.readable` 交给控制器；`didUpdateWidget` 里 `super.didUpdateWidget(old); _items.sync(widget.items);`。依赖继承值的（reduced motion）`input(false)` 占位，`didChangeDependencies` 里 `sync(MediaQuery.disableAnimationsOf(context))`：首次 build 之前就已同步 |
| 子树之外的读者被 sync 唤醒时 debug 报 `RILL_WIDGET_INPUT_ESCAPED`（`FlutterError.reportError`，不抛）；越界位置的 `sync` 抛同一个代码 | — | 读者放进属主子树（`OverlayPortal` 浮层子节点算在内）；子树外要用就给它自己的源。随事件变化的值是状态，写 `Signal` |
| `ReactiveState` 覆写了 `didUpdateWidget` / `didChangeDependencies`（只在 debug 开 sync 窗口），并新增成员 `input` | State 里自己声明了名为 `input` 的字段或方法 | 改名（编译器会报冲突）。`super.didUpdateWidget` / `super.didChangeDependencies` 本来就必须调用，`sync` 要写在它之后 |
| sync 唤醒的 effect 与 `watch` 在帧后 apply（R3b，与桥同一个通道） | 期望 `didUpdateWidget` 里改配置后，同帧 build 读到 `watch` apply 写出的值 | 本帧要用的值从输入 `computed` 派生；`watch` 只做 Flutter 侧的副作用（动画、焦点、播报） |
| 新增 `ReactiveOpacity(opacity: Readable<double>)`、`ReactiveTransform(transform: Readable<Matrix4>)`、`ReactiveTransform.translate(offset: Readable<Offset>)`（F13）与它们的 `RenderReactiveOpacity` / `RenderReactiveTransform` | spike 分支 `spike/render-drive`（`58d60e5`）上的同名类；或手写 `RenderProxyBox` 在 ticker 里改变换 | 改依赖本版本，用法不变。与 spike 的差别：读者有宿主，`TickerMode` 关闭或 reduced motion 时读到的 Pulse 会停（spike 上恒为可见）。不经 widget 直接构造的 render 对象仍按原生监听处理 |
| lint `rill_create_in_build` 增报属主 `build` 方法体里的 `input(` | `build` 里 `final items = input(widget.items);` | 挪到 `initState` 或 `late final` 字段；不给 quick fix |
| `batch` 里调用 `sync` 在 debug 下抛 `RILL_WIDGET_INPUT_ESCAPED`：flush 要等 `batch` 结束，读者会悄悄晚一帧、越界不报 | `didUpdateWidget` 里 `batch(() { _snaps.sync(widget.snaps); _min.sync(widget.min); });` | 一起变的配置合成一个输入：`input((snaps: …, min: …), equals: …)`，一次 `sync` |
| lint `rill_write_in_build` / `rill_write_in_computed` 覆盖 `WidgetInput.sync(`：报 `build` / `paint` 方法体里、直接位于 widget builder 闭包（`Builder`、`LayoutBuilder` 等）里、以及 compute 回调里的调用；`didUpdateWidget` / `didChangeDependencies` 与它们的 helper 不报 | `build` 里 `LayoutBuilder(builder: (_, c) { _width.sync(c.maxWidth); … })` | 挪回 `didUpdateWidget` / `didChangeDependencies`；layout 测得的值不是配置（非目标） |

## v0.7.1（`867ca71`，2026-11-21，lint 补报，无运行时改动）

> 从 v0.7.0 往下做。只有 lint 变化：`packages/rill`、`packages/rill_flutter` 的运行时代码与 v0.7.0 相同。
> 起因是一个使用方的报告：`Reactive` builder 里的 `signal(` 每次重建都给 `RawSheet` 一个新的 `open`。

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| lint 新报出的位置：`rill_create_in_build` 与 `rill_write_in_build` 的 `WidgetInput.sync(` 共用[帧内位置](lint.md#帧内位置)判定，增报**直接位于 widget builder 闭包里**（`Reactive(builder:)`、`Builder`、`LayoutBuilder`、`ListView.builder` 等，按形参类型识别）建的 signal / computed / Events / `Wire` / `linger` / `Scope` / `input(` 等。更深一层的闭包（事件回调、`forEach`）、`initState`、`late final` 字段不报 | `Reactive(builder: (context) { final open = signal(true); return RawSheet(open: open, …); })` | 挪到 State 的 `late final` 字段、`initState` 或 store；确实要每次新建的（测试里验证归属语义）写 `// ignore: rill_lint/rill_create_in_build` 并说明理由。不给 quick fix |

## v0.7.2（`ecfad2c`，2026-11-21，新增参数，无不兼容改动）

> 从 v0.7.1 往下做。只有新增：`ReactiveTransform` 收变换原点，旧调用不变（两个参数默认 `null`，矩阵绕左上角，与 v0.7.1 相同）。`packages/rill` 与 v0.7.1 相同。
> 起因是一个使用方的需求：popup 绕锚点边 scaleY 0.96 → 1、alert dialog 绕中心 0.97 → 1 需要渲染时的子节点尺寸；post-frame 尺寸 signal 首帧原点算错。

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| `ReactiveTransform(transform:)` 新增 `alignment: AlignmentGeometry?` 与 `origin: Offset?`，语义同 `Transform`：图层、命中测试、`applyPaintTransform` 按当时 size 求 `translate(origin + alignment.alongSize(size)) · matrix · translate(−…)`，`AlignmentDirectional` 用环境 `Directionality`。是普通 widget 参数，改动只更新 render 对象；`.translate` 不收（平移与原点无关）；`Readable` 原点是非目标 | 自写 `RenderProxyBox`在 paint 时按 size 算原点 | popup：`ReactiveTransform(alignment: below ? Alignment.topCenter : Alignment.bottomCenter, transform: computed(() => Matrix4.diagonal3Values(1, t.value, 1)), child: …)`；dialog：`ReactiveTransform(alignment: Alignment.center, transform: computed(() => Matrix4.diagonal3Values(s.value, s.value, 1)), child: …)` |

## v0.7.3

API 与行为都没有变化。仓库公开，历史从这一版重新开始，旧的 `ref` SHA 不再能拉到。

| 改动 | 旧写法 | 新写法 |
| --- | --- | --- |
| git 依赖的 `ref` 换成新历史上的 SHA | `ref: <v0.7.2 的 SHA>` | `ref:` 填 `git ls-remote https://github.com/celados/rill.git 'refs/tags/v0.7.3^{}'` 的结果；`rill`、`rill_flutter`、`rill_test`、`rill_lint` 四处一起换 |
