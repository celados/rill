---
type: Reference
title: rill_lint rules
description: >
  The rill_lint analyzer rules, what each one flags and why, its honest boundary, and the fix;
  including why rill_write_after_await does not follow Timer callbacks and what
  rill_effect_in_lifecycle points to, and the layouts where the analyzer silently drops the plugin.
when: A rill_lint diagnostic appears, a rule seems to miss or over-report, or a rule is added.
timestamp: 2026-11-21
---

# rill_lint 规则

插件在 `packages/rill_lint`，配置方式见 [README](../README.md#使用)。规则分层与保证边界见
[分层](#分层运行时守卫是权威)。门禁的金丝雀
（`packages/rill_lint/fixtures`）要求每条规则都至少报一次错。

| 规则 | 报什么 | 修法 |
| --- | --- | --- |
| `rill_cast_to_signal` | 把只读类型 `is` / `as` 成 `Signal` | 需要写就显式传 Signal |
| `rill_write_in_computed` | computed / effect compute / `watch` compute 里写入、`transact(` 或 `WidgetInput.sync(` | 写入放到命令或 apply |
| `rill_write_in_build` | `build` / `paint` 里直接写入或 `transact(`；`WidgetInput.sync(` 按[帧内位置](#帧内位置)判定，还报直接位于 widget builder 闭包里的 | 事件或 post-frame 回调 |
| `rill_create_in_build` | [帧内位置](#帧内位置)（`build` / `paint`，含 `ReactivePainter.paint`，以及直接位于 widget builder 闭包里）建 signal、computed、Events、`Wire`、`linger`，以及 `Scope(`、`scope.child(` / `.effect(` / `.slot(`、`ReactiveState` 的 `input(`（每次调用都是一个旧读者看不到的新节点） | 在 store 或 State 的生命周期里建 |
| `rill_untracked_read` | Flutter 自己会把 builder 留到以后执行的 API（Flutter 的 Widget / Route / OverlayEntry / `*Delegate` 构造，返回 Future / Route / OverlayEntry / `PersistentBottomSheetController` 的 Flutter 函数；别处声明的不报）的 widget builder 形参（按类型识别：首参 `BuildContext`、返回 Widget / 一组 Widget），以及普通 `CustomPainter.paint` 里读 `.value`。只看直接包住读取的那个闭包：嵌套闭包（`map`、`forEach`、`List.generate`、本地 helper）里的读取不报；`Reactive` 及其子类不算延迟执行的被调用方（[分层](#分层运行时守卫是权威)） | 用适配器或包一层 `Reactive`（quick fix）；painter 改成 `ReactivePainter` 交给 `ReactivePaint`；快照用 `peek()` |
| `rill_write_after_await` | async 函数体里 await 之后的裸写入与 `transact(` | 放进 Slot，用 `Task.publish` 暂存 |
| `rill_effect_in_lifecycle` | State 成员、widget `build`、painter `paint`（`CustomPainter` 与 `ReactivePainter`）里的 `effect(` 与 `scope.effect(`（receiver 静态类型是 rill 的 `Scope`） | `ReactiveState.watch` |
| `rill_async_star_stream` | `computedStream` 的实参是 `async*` / `async` 函数字面量：依赖只在函数同步返回 stream 之前收集，函数体在 listen 之后才运行，读取与 `q.wait` 都不追踪 | 改成同步函数：先读输入、调 `q.wait`，再返回 stream，如 `Stream.fromFuture(q.wait(token)).asyncExpand(…)`；不给 quick fix（改写要人判断）。只认函数字面量，tear-off 不报 |

## 帧内位置

`rill_create_in_build` 与 `rill_write_in_build` 对 `WidgetInput.sync(` 共用一个判定（`semantics.dart` 的 `inBuild`），
两条规则对「在 build 里」不会不一致：

- `build` / `paint` 方法体本身；
- 直接位于 widget builder 闭包里：闭包作为实参传给按类型识别的 widget builder 形参（首参 `BuildContext`、返回 Widget /
  一组 Widget），如 `Reactive(builder:)`、`Builder`、`LayoutBuilder`、`ListView.builder` 的 `itemBuilder`。不论被调用方
  是否延迟执行：这种闭包总在某次 build 或 layout 里运行，每次重建都会再跑一遍。

只看直接包住调用的那个闭包：再往里一层的闭包（事件回调、`forEach`、本地 helper）不报；`initState`、`didUpdateWidget`
与 `late final` 字段初始化不是帧内位置。v0.7.1 起 `rill_create_in_build` 才覆盖第二种（一个使用方报告：`Reactive` builder
里 `signal(` 每次重建都给下游一个新实例）。

## 分层：运行时守卫是权威

`rill_untracked_read` 与运行时守卫 G2（帧内未追踪读取抛
[RILL_UNTRACKED_READ](diagnostics/RILL_UNTRACKED_READ.md)）判同一件事。**G2 是权威**：它看的是读取实际在哪儿执行。
lint 只做**不误报**的早期提示，判断不了时不报，漏报交给 G2。由此定下三条：

- **只在闭包直接作为已知延迟执行被调用方的实参时报。** 读取所在的最内层函数体必须就是交给
  已知延迟执行被调用方（下一条）的 widget builder。
  再往里一层的闭包（`Iterable.map` 之类的惰性视图、`forEach` / `List.generate` 这类就地执行的回调、本地 helper）
  何时执行要看调用链，lint 不推断：`[0, 1].map(f).length` 不执行 `f`，`map(f).followedBy(…).toList()` 执行，
  前者报是误报，后者由 G2 在运行时抓住。
- **只认 Flutter 自己的延迟执行 API。** 被调用方必须声明在 Flutter 里：Flutter 的 Widget / Route / OverlayEntry / `*Delegate` 构造
  （`Builder`、`LayoutBuilder`、`ListView.builder`、`PageRouteBuilder`、`SliverChildBuilderDelegate` 等），或返回 Future / Route /
  OverlayEntry / `PersistentBottomSheetController` 的 Flutter 函数（`showDialog`、`showModalBottomSheet`、`showGeneralDialog` 一族）。
  声明在别处的构造或函数一律不报：自定义 Widget 可以在构造器初始化列表里立即调用 builder，返回 Future 的函数可以在返回前立即调用，
  这时读取在包着它的 `Reactive` 里被追踪，报就是误报。第三方包（如路由库）的 builder 由 G2 兜底。
- **`Reactive` 子类不报。** 构造函数把 builder 原样转给 `Reactive` 的 builder（`super.builder`、
  `super(builder: b)`、经 `this.named(b)` 重定向、多层子类）时它就被追踪；子类拿 builder 做别的
  （例如包进普通 `Builder`），lint 也无法确定，同样不报，交给 G2。

新增或放宽判断时守住这个方向：宁可漏报，不可误报；误报会让人关掉规则，漏报还有 G2。

## rill_write_after_await：为什么不跟进 Timer 回调

规则只看 async 函数体本身：await 之后的写入可能属于一次已经被取代的操作（换了会话、来了更新的请求），
它应当是 Slot 任务按发布权写入。

`Timer`、`Stream.listen`、`addListener` 的回调不是这个函数体的延续，而是**离散事件**，和一次点击一样。
从事件里写入是正当的；把它们算进来，每一个事件处理器都会被报。所以下面的写法不报，这是有意的：

```dart
Future<void> start() async {
  await connect();
  Timer.periodic(const Duration(seconds: 1), (_) => elapsed.value++);   // 不报：这是事件
}
```

但这类代码通常有更好的写法：

- **周期性的 UI 状态从时间派生**，不要在循环或 Timer 里写。`Pulse.every` / `Pulse.minute` / `Pulse.phase`
  是按需运行的时间源（有可见 reader 才走、不可见暂停、恢复时校准，F9）；同参数的调用在有 reader 时共享同一个源，
  所以可以直接写在 computed 里：

  ```dart
  final elapsed = computed(() => Pulse.every(const Duration(seconds: 1)).value.difference(startedAt));
  ```

- **确实需要写入**（例如采样一个外部值），计时器要归某个 Scope，随所有者释放：

  ```dart
  final t = Timer.periodic(period, (_) => sample.value = read());
  scope.onDispose(t.cancel);          // State 里用 ReactiveState 的 scope
  ```

  rill 不另设 `scope.periodic`：`Pulse` 覆盖了"随时间变化的状态"，剩下的写入用上面两行已经有归属，再包一层不增加表达力。

## rill_effect_in_lifecycle

`initState`、`didChangeDependencies`、`didUpdateWidget`、`build` 都在框架 build 期间运行，painter 的 `paint` 在 paint 期间运行。普通 `effect()` 的首次 apply
是同步的，所以它就在 build 里执行，其中的写入触发 [RILL_WRITE_DURING_FRAME](diagnostics/RILL_WRITE_DURING_FRAME.md)。
用相位判断（`schedulerPhase == idle`）绕开是错的：runApp 的首次 build 同步发生在帧外，相位恰好是 idle。

```dart
class _RegionState extends State<Region> with ReactiveState {
  @override
  void initState() {
    super.initState();
    watch(() => widget.toasts.value, (toasts, previous, _) {   // 首个 apply 在帧后，之后同步
      entries.value = reconcile(toasts);
    });
  }
}
```

报告范围：State 的实例成员（生命周期方法、被它们调用的 helper、字段初始化）、widget 的 `build`；`scope.effect(` 与顶层 `effect(` 同样报。
嵌套闭包（事件回调、`addPostFrameCallback`）不报。边界：从 State 之外的普通函数间接建的 effect 看不到。

为什么方法叫 `watch` 而不是 `effect`：Dart 先在词法作用域里解析裸名，import 进来的顶层 `effect` 胜过 mixin 继承的成员，
State 里的 `effect(` 永远是顶层那个。这条规则正是为此而设。

## 插件静默

**现象**：被分析的目录树里只要有一个带自己 `.dart_tool/package_config.json` 的嵌套包（`example/`、
`packages/foo/` 跑过 `pub get`），analysis_server 就把整棵树的插件全部丢掉：rill_lint 一条不报，`analyze`
照样通过，没有任何错误输出。和嵌套包自己配没配插件、插件用 path 还是 git 引用都无关。一个使用方的 example
因此让 rill 规则失效了一周多，迁移时一次报出 27 处。

**这是 analyzer 的限制，rill_lint 绕不开**：插件只能在包或 workspace 根的 `analysis_options.yaml` 启用
（[using_plugins.md](https://github.com/dart-lang/sdk/blob/main/pkg/analysis_server_plugin/doc/using_plugins.md)），
多上下文下的插件配置是上游未解决的问题（[dart-lang/sdk#62161](https://github.com/dart-lang/sdk/issues/62161)、
[#62451](https://github.com/dart-lang/sdk/issues/62451)、[#63609](https://github.com/dart-lang/sdk/issues/63609)）。
2026-11-20 在 Dart 3.14 上复现：嵌套包没有 package_config 时插件正常，`pub get` 之后静默。

**修法**：
1. 嵌套包写进根包的 `analyzer.exclude`（如 `example/**`），各自单独 analyze；需要规则的嵌套包在自己的根配置插件。
2. 门禁加 `dart run rill_test:lint_canary`：临时往 `lib/` 放违规文件、分析整个包，没有 rill 诊断就失败。
   rill 自己的门禁验证它在插件生效时通过、在没配插件的包上失败（`tool/check.sh` 的 `check_plugin_probe`）。
   嵌套包导致的静默不进门禁：同样的布局在本机连跑多次，偶有一次插件照常报出，上游行为不够确定。

用 `ignore` + `unnecessary_ignore: error` 做常驻金丝雀行不通：插件不在时 analyzer 不认识插件的代码，
不会判 ignore 多余。插件诊断的 ignore 要带命名空间：`// ignore: rill_lint/<rule>`。
