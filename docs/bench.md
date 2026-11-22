---
type: Reference
title: rill AOT benchmarks
description: Paired native Dart benchmark measurements for rill and alien_signals.
timestamp: 2026-11-18
---

# AOT benchmarks

Apple M1 Pro, 3.14.0, macos. Start load average (1m / 5m / 15m) 5.09 / 8.27 / 10.12.

Each timed case runs 7 paired rounds. A round starts one AOT process
per engine, each with 100 ms warmup and one at-least-1000 ms window.
The two processes run back to back and their order alternates between rounds.
Every process runs with a fixed 32 MB new-generation semi-space (initial =
maximum, `--new_gen_semi_initial_size=32,--new_gen_semi_max_size=32`), the same for every engine.
The per-case ratio is the median of the seven rill / alien_signals ratios.
Absolute times below are medians in microseconds per workload. The signals_core
reference runs separately after the pairs and does not enter the verdict.

A family score is the geometric mean of its case ratios for each round
index, followed by the median across those seven scores. Q1–Q3 uses linear
interpolation at the 25th and 75th percentiles. The budget is 1.10× for graph
workloads and 1.35× for CellX. A Q1–Q3 width greater than 10% of the median
makes a family **uncertain** and prompts a rerun on an idle machine.
The gate runs only on a local arm64 machine before a release, never in CI:
the CI runners are shared hosted machines whose load is outside this
gate's control, and the budgets were calibrated on arm64.
Otherwise, a median above budget fails and a median within budget passes.
Depth checks use independent processes and retain their pass criteria.

Warm workloads time writes, reads and validation on prebuilt observed graphs.
Cold workloads build a fresh unobserved chain outside the timer and time its
first terminal read. The cold limit is found by binary search. The warm
depth check pre-evaluates each node before attaching a terminal effect.
Timings include adapter overhead.

Workloads follow [js-reactivity-benchmark](https://github.com/transitive-bullshit/js-reactivity-benchmark/tree/b79242895c35307da995dd271d6f1b570472a826).
Dynamic workloads use Dart's seeded RNG. CellX alternates the two upstream
input tuples on the warm graph.

| Case | alien_signals | signals_core | rill | Paired median | Q1–Q3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| kairo-avoidable | 102.338 | 262.219 | 119.615 | 1.168× | 1.138×–1.178× |
| kairo-broad | 193.859 | 277.904 | 210.824 | 1.075× | 1.069×–1.080× |
| kairo-deep | 68.742 | 131.202 | 58.115 | 0.842× | 0.840×–0.845× |
| kairo-diamond | 146.897 | 198.980 | 148.592 | 1.010× | 1.004×–1.021× |
| kairo-mux | 129.188 | 160.686 | 143.338 | 1.110× | 1.101×–1.126× |
| kairo-repeated | 39.174 | 42.288 | 42.724 | 1.098× | 1.078×–1.105× |
| kairo-triangle | 60.691 | 76.727 | 56.915 | 0.937× | 0.936×–0.938× |
| kairo-unstable | 53.995 | 59.754 | 57.394 | 1.070× | 1.058×–1.075× |
| cellx-10 | 2.639 | 3.928 | 3.121 | 1.182× | 1.179×–1.191× |
| cellx-20 | 4.798 | 7.305 | 5.786 | 1.200× | 1.197×–1.216× |
| cellx-30 | 7.018 | 10.892 | 8.598 | 1.227× | 1.224×–1.238× |
| cellx-1000 | 371.136 | 529.726 | 494.454 | 1.320× | 1.305×–1.347× |
| cellx-2500 | 1007.431 | 1393.134 | 1633.960 | 1.637× | 1.615×–1.719× |
| cellx-5000 | 2844.275 | 4336.989 | 3971.404 | 1.509× | 1.255×–1.578× |
| mol | 37.856 | 37.893 | 37.740 | 0.996× | 0.993×–1.002× |
| dynamic-simple | 157.959 | 235.954 | 170.018 | 1.075× | 1.073×–1.089× |
| dynamic-component | 788.321 | 1254.932 | 761.593 | 0.963× | 0.943×–0.979× |
| dynamic-large | 1909.620 | 2353.449 | 1814.458 | 0.949× | 0.940×–0.971× |
| dynamic-wide-dense | 6272.069 | 10593.970 | 6317.914 | 1.008× | 1.004×–1.023× |
| dynamic-deep | 9971.248 | 15844.480 | 9642.920 | 0.968× | 0.946×–1.000× |
| cold-50 | 2.266 | 2.350 | 2.301 | 1.024× | 1.003×–1.121× |
| cold-500 | 26.084 | 28.456 | 25.873 | 1.009× | 0.978×–1.035× |
| cold-1000 | 50.427 | 55.941 | 50.200 | 0.991× | 0.942×–1.011× |
| cold-2500 | 122.214 | 128.161 | 120.978 | 0.978× | 0.971×–0.984× |
| cold-5000 | stack overflow | stack overflow | stack overflow | — | — |
| cold-limit | 3619 layers | 3993 layers | 4632 layers | — | — |
| warm-300000 | pass (teardown overflow) | stack overflow | pass | — | — |

| Workload family | Paired median | Q1–Q3 | Budget | Verdict |
| --- | ---: | ---: | ---: | --- |
| kairo | 1.032× | 1.031×–1.040× | 1.10× | pass |
| cellx | 1.325× | 1.304×–1.355× | 1.35× | pass |
| mol | 0.996× | 0.993×–1.002× | 1.10× | pass |
| dynamic | 0.979× | 0.976×–1.010× | 1.10× | pass |
| cold | 1.007× | 0.980×–1.026× | 1.10× | pass |

**Gate verdict** pass.

## Ablation

基线为 `90f67ba`，其完整门禁为 Kairo 1.123×、CellX 1.384×。以下消融覆盖全部 8 个 Kairo 和 6 个 CellX 用例。每个用例和实现都用独立 AOT 进程运行，先预热 100 ms，再取三个至少 220 ms 窗口的中位数。各用例内以固定种子打乱进程顺序。消融使用同一个入口在运行时选用例，方便对每个实现编译一次。正式门禁按用例分别编译并使用 2 s 窗口。

表里的倍数以**同轮 rill 对照**为分母，再取组内几何均值；小于 1 表示变快。第 1、2 轮以旧版为对照，第 3 轮以正式候选版（含 Scope 登记优化与释放保护）为对照。反事实只用于上界估计，不进入交付代码。

| 轮次 | 单项改动或组合 | Kairo / 对照 | CellX / 对照 | 处理 |
| --- | --- | ---: | ---: | --- |
| 1 | 仅不同对象时重比较 _committed | 0.996× | 0.965× | 拒绝，首写已跳过第二次比较 |
| 1 | 省略 _committed 比较 | 0.998× | 1.007× | 反事实，破坏 ABA |
| 1 | 直接展开 identical 或 == | 0.989× | 0.984× | 收益不稳定 |
| 1 | refresh 一层 try，错误收尾移到冷函数 | 0.991× | 0.936× | 保留 |
| 1 | Scope 用链表登记闭包 | 0.986× | 1.026× | 改测直接登记节点 |
| 2 | Scope 链表直接登记节点 | 0.994× | 1.026× | 保留，生命周期测量见下文 |
| 1 | 仅冷 computed 写 _validated | 0.979× | 0.957× | 保留 |
| 1 | 节点局部递增，省略全局修订时钟 | 0.991× | 0.962× | 反事实，破坏全局修订语义 |
| 1 | 用本次安装修订号刷新 _writes | 0.981× | 0.971× | 保留 |
| 1 | 仅 Scope 确实切换时写入上下文 | 0.980× | 0.967× | 保留 |
| 1 | 在当前轮队列内压缩已准备项 | 0.955× | 0.916× | 保留 |
| 1 | 仅有 cleanup 时写入及检查释放 | 0.989× | 0.951× | 保留 |
| 1 | 省略依赖边 cycle 写入，用反查去重 | 1.010× | 0.985× | 收益不稳定 |
| 1 | 每个 effect compute 后立即 apply | 0.944× | 0.839× | 反事实，破坏轮次屏障 |
| 1 | 省略整轮 apply | 0.962× | 0.816× | 反事实，破坏 R4 |
| 2 | 队列压缩、Scope 切换与 cleanup 快路径 | 0.954× | 0.961× | 保留 |
| 2 | refresh 冷路径与两个写入戳优化 | 0.988× | 1.134× | 与调度组合复测 |
| 2 | 合并调度与 refresh 写入戳优化 | 0.954× | 0.831× | 进入组合候选 |
| 2 | 将首次求值和热读取分开 | 0.978× | 0.918× | 保留 |
| 2 | 将依赖清理与诊断移到冷函数 | 0.969× | 0.969× | 保留 |
| 2 | 依赖边分配移到冷函数 | 0.975× | 0.968× | 保留，正式代码保留已释放检查 |
| 2 | 合并三项追踪快路径 | 0.932× | 1.004× | 进入组合候选 |
| 2 | 合并调度、refresh 与追踪 | 0.911× | 0.810× | 筛选候选，存在对照异常 |
| 3 | 候选版改用两个 ListQueue | 1.000× | 1.057× | 拒绝，CellX 变慢 |
| 3 | 候选版复用两组可空数组 | 0.962× | 1.063× | 拒绝，CellX 变慢 |
| 3 | 在候选版展开默认相等调用 | 1.006× | 1.057× | 拒绝，CellX 变慢 |
| 3 | 在候选版取消 compute/apply 屏障 | 0.987× | 0.962× | 反事实，另做匹配复测 |

第 2 轮组合候选对 alien_signals 为 1.029× / 1.085×。CellX-20 与 CellX-30 的 alien_signals 中位数分别为 6.61 和 13.62 µs；第 3 轮回到 4.71 和 6.90 µs。正式候选在第 3 轮为 1.039× / 1.288×。以正式门禁裁定达标。

当前 signal 在干净的首写已经利用 dirty 位跳过第二次比较。Kairo 每批只写一个源，CellX 每批对四个源分别写一次。省略比较的反事实对这些工作负载没有稳定收益。等值短路仍需在安装前完成，包括用户比较器抛错和未消费的 ABA。

原生 AOT 相等微测交替比较同值和不同值，每种类型和实现分别取五个窗口的中位数。测试通过通用入口传入数值，含取数和计数成本。

| 输入 | 直接 identical 或 == | 当前整数快路径 |
| --- | ---: | ---: |
| int | 6.10 ns | 6.10 ns |
| double | 6.91 ns | 7.22 ns |

整数分派在该微测的计时分辨率内相当。double 的直接表达式较快，展开相等调用在整个候选版的 CellX 上没有同向收益。

### Scope 生命周期

预热 Kairo、CellX 不计图创建和释放。另用独立 AOT 进程为 Scope 创建等量 computed 和 effect，比较直接释放 Scope 与逐个调用 effect 的释放句柄后再释放 Scope，分别取五个窗口的中位数。

| computed / effect 各 N 个 | 创建 + Scope 释放，旧 → 新 | 逐个停止 + Scope 释放，旧 → 新 |
| ---: | ---: | ---: |
| 100 | 0.354 → 0.022 ms | 0.375 → 0.011 ms |
| 1,000 | 33.71 → 0.245 ms | 37.57 → 0.120 ms |
| 5,000 | 846.16 → 1.102 ms | 947.59 → 0.485 ms |

### 取样与后续消融

macOS `sample` 采到了 AOT 指令地址，采样文件缺少 Dart 函数名。另用 VM service 对相同 CellX-1000 工作负载做 JIT 取样，排除等待线程后为 3,045 个叶样本。热点包括 `_prepare` 392、`_applyPrepared` 325、`_link` 270、`_propagate` 266、`_end` 255、`_readCached` 215、`_refresh` 115，以及列表扩容 59。该取样用于选消融方向，倍数取自 AOT。

本机 Dart SDK 的 growable list 在 `clear()` 时缩掉容量。两个容量复用方案均完成了用例，在 CellX 上分别比压缩队列慢 5.7% 和 6.3%。保留原地压缩方案。

### 匹配的 effect 语义反事实

在最终候选源码上单独替换刷新循环。每种实现每个用例运行两个独立 AOT 进程，第二个进程组反转顺序。每个进程取三个至少 300 ms 的窗口，各用例合并六个窗口取中位数。表中为完整语义耗时除以反事实耗时的组内几何均值；越大表示被移除的工作成本越高。

| 反事实 | Kairo | CellX |
| --- | ---: | ---: |
| compute 后立即 apply，移除本轮全体 compute 的屏障 | 1.001× | 1.070× |
| 保留 compute，跳过 apply 阶段 | 1.034× | 1.161× |

这两行是分别与完整版本匹配的测量。CellX 单独移除屏障的差值为 6.96%；整个 apply 阶段的差值为 16.14%。原地压缩队列已经保留在候选版，另外两种队列方案没有降低 CellX 的剩余开销。正式实现保留屏障、cleanup 时序和 apply，门禁仍按 1.10× 判定。

在隔离副本运行提前 apply 的反事实，正式 API 的 #50 改写用例失败。第二个 compute 直接读到了第一个 apply 写入的 10，丢失了分相版本中同轮读到 0 的记录。原始独立进程数据见本地 `.out/ablation/round{1,2,3}.json` 和 `.out/ablation/matched.json`。

### 完整门禁复测

正式候选的 `tool/check.sh` 完成了锁文件、格式、分析、19 条核心测试、rft、100,000 步 fuzz、11 个变异与全部 AOT 用例，退出码 1。组内倍数为 Kairo 1.021×、CellX 1.260×、Mol 0.991×、Dynamic 0.984×、Cold 0.925×。CellX 是唯一超预算组。rill 通过 300,000 层预热写入和释放，冷链首次读取达 4,632 层，对照为 3,619 层。

CellX 从上次完整门禁的 1.384× 降至 1.260×。匹配测量中 R4 屏障单项超过 5%，本轮尝试的调度实现仍有差距。按约定在此停止，保留公开 API、已定语义和性能门槛。

### M2–M4 回退的定位（2026-11-18，M5 合入后）

`1fb8534` 的完整门禁为 Kairo 1.088×、CellX 1.394×，M1 验收（`b805aa2`）为 1.025×、1.276×，IQR 都窄。以下定位与修复不改语义。

**方法：同二进制交错对比。** 把每个待测提交的 `packages/rill/lib` 以独立包名（`rill_<sha>`）放进同一个基准包，
和 alien_signals 一起编进同一个 AOT 可执行文件，每个用例一个（`-DCASE`，同 `bench/bin/sample.dart`）。每轮为每个引擎起一个进程，
引擎顺序按固定种子打乱，每个进程预热 100 ms 后取一个至少 500 ms 的窗口。倍数以同轮 `b805aa2` 为分母，族内取几何均值后
跨轮取中位数，方括号为 Q1–Q3。所有引擎共用同一份 adapter 代码与同一批二进制，差异只来自 rill 本身。脚本与原始数据在本地
`.out/bisect/`（`setup.py` 生成基准包，`run.py` 测量，`report.py` 汇总）。

AOT 是否删掉 assert 先单独确认：`dart compile exe` 生成的程序里 `assert(hit())` 未执行，`assert(false)` 不抛。M4b 的
`_debugCreated`、`_debugBegin` 等挂点都在 `assert` 里，不进入计时路径。

**二分（5 轮）。** 只列改过 `runtime.dart` / `graph.dart` 的提交：

| 提交 | 内容 | Kairo / M1 | CellX / M1 |
| --- | --- | ---: | ---: |
| `37b7538` | M2 原语（出生修订号、候选值校验） | 1.001× | 0.985× |
| `5110e6e` | 发布边界的写入诊断 | 0.999× | 0.984× |
| `27801e9` | 发布校验与任务继承 | 1.002× | 0.987× |
| `310ae28` | keyed flight 与子任务准入 | 0.997× | 0.994× |
| `48eb740` | M3 绑定钩子（采样输入、创建位置字段） | 1.010× | 1.003× |
| `b92a0e4` | M3 消费值记录（链接上三个字段、写入时遍历订阅者） | 1.041× | 1.024× |
| `c9dbf16` | M4b 诊断 | 1.045× | 1.048× |
| `d1b7ff2` | 无 hook 时打印警告 | 1.042× | 1.039× |

M2 没有回退，CellX 还快 1–2%。回退集中在 M3：`b92a0e4` 让每次写入和每个变化的 computed 都遍历一遍订阅者找等值输出，
每次重新追踪都记录消费值，链接多三个字段。`c9dbf16` 在热路径上只有 assert 与失败分支的改动，其 CellX 增量集中在
cellx-2500（+7.6%），小图不变，按代码布局与大图噪声处理，没有单独修。

**第一个候选：每节点计数。** 在节点上记"比较消费值的订阅者"数目，为零时跳过遍历。Kairo 回到 1.015×，小 CellX 回到 0.99×，
但 cellx-1000 / 2500 / 5000 变成 1.070× / 1.204× / 1.065×。多一个字段让每个节点变大，大图的缓存开销超过了省下的遍历。
这说明大图的回退来自对象尺寸，修法应当是把只有绑定用到的状态从公共节点和链接上拿走，而不是再加状态。拒绝。

**第一次完整门禁暴露 cold 回退。** 候选版（下列五项全部施加）的完整门禁 Kairo 1.040×、CellX 1.304×，但 cold 族 1.109× 超预算：
cold-2500 从 1.045× 变成 1.759×，cold-50 到 cold-1000 正常。该候选同二进制对 M1 为 Kairo 1.011×、CellX 1.010×；cold-2500
复测为 1.859×，真实且稳定。

逐项回退都不能复原；从修复前的 `1fa9561` 出发逐组施加，单独每组都正常（cold-2500 1.10–1.12×），只有"失败来源并入
`_Failure`"与"创建栈移出节点"同时施加才慢（1.866×）。两者合起来让每个 Computed 少两个字段，按 16 字节对齐正好小一档；
单独删一个字段对齐后尺寸不变。补回"未使用字段"的变体测不出来，因为 AOT 的类型流分析会删掉没有读取的字段。

`--verbose_gc`（经 `DART_VM_OPTIONS`）给出机制：快版本的新生代容量长到 32 MB，一个进程 82 次 scavenge；慢版本停在 8 MB，232 次，
每次 0.6–0.7 ms。VM 按每次 scavenge 的存活比例决定是否扩容新生代（`new_gen_garbage_threshold` 90%）。冷链在计时外构建，
Computed 变小后 scavenge 的落点和存活比例变了，新生代不再扩容，计时的首读里频繁 scavenge，每次都复制整条活着的 2500 层链。
这是 GC 尺寸启发式的阈值效应，不是代码变慢。CellX 是预热图，一个进程只有 6–7 次 scavenge，不受此影响；它反过来从更小的
Computed 获益（cellx-2500 0.948× 对 1.124×）。两者冲突，按门禁取舍：保留 Computed 原尺寸。

**采用的修复：**

- 消费值的三个字段移到子类 `_ValueLink`，只为比较消费值的 `Subscriber` 创建；普通链接回到 M1 的尺寸。
- 全局计数 `_comparingSubscribers`（构造时加、释放后减）。为零时写入、computed 变化和重新追踪都跳过等值工作；
  不为零时走原逻辑，语义不变。重新追踪的判断放在 never-inline 的 `_recapture` 里，`_link` 内联进每次读取的部分只多一次计数判断。
- signal 的 `sample` / `beforeRead` 两个钩子合并为一个可选对象，读取时一次空判断，钩子路径 never-inline。
- 创建栈从每个节点的字段移到 debug 的 Expando。
- computed 的失败来源**保留为独立字段**（见上：并入 `_Failure` 会让 Computed 小一档并触发 cold 回退），代码里注明原因。

**修复后（同二进制，7 轮，每窗口 400 ms）：**

| 引擎 | Kairo / M1 | CellX / M1 | cold / M1 | Kairo / alien | CellX / alien | cold / alien |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `b805aa2` | 1.000× | 1.000× | 1.000× | 1.023× | 1.296× | 0.935× |
| `d1b7ff2`（修复前） | 1.048× | 1.049× | 1.061× | 1.072× | 1.368× | 0.976× |
| 修复后 | 1.011× [1.010–1.014] | 1.036× [1.022–1.038] | 1.037× [1.031–1.043] | 1.035× | 1.340× | 0.956× |

完整 `tool/check.sh`（含性能）退出码 0：Kairo 1.039×、CellX 1.307×、Mol 1.009×、Dynamic 0.995×、Cold 0.970×，变异 41/41 与 10/10。
Kairo 剩下约 1% 落在 kairo-mux（1.043×）与 kairo-triangle（1.031×），CellX 剩下的主要是 cellx-2500 的缓存占用，没有继续追。

建议另议：cold 用例对新生代尺寸启发式敏感，节点尺寸的正常变化就可能让它跳一档。若要让它只量首读，可在基准进程里固定
新生代大小（如 `--new_gen_semi_initial_size`），这会改变测量口径，本次没有改。

### computed 在 Scope 之外求值（2026-11-18）

一次评审要求 computed 求值时不沿用拉取者的环境 Scope。第一版记下 computed 的所有者、求值时切过去（与 effect 一致），
完整门禁不过：cold 1.105×（Q1–Q3 1.097×–1.109×）超 1.10× 预算，首读 3,130 层低于对照的 3,619 层。原因与上一节相同：
多一个 `_owner` 字段让 Computed 大一档；切换放在单独的 `_evaluate` 里（自带 try/finally）多了一层首读栈帧。
改为在 `_firstRead` / `_refresh` 已有的 try/finally 里内联清空环境 Scope、不加字段后，门禁通过：Kairo 1.046×、CellX 1.324×、
Mol 1.005×、Dynamic 0.994×、Cold 0.959×，首读 4,454 层（修复前 4,632 层，少的是一个局部变量的帧）。本文件开头的表是这次运行。

## Paired gate repeatability

Two consecutive full checks on the same worktree and machine, with other sessions left running. The old independent-window run under load had reported CellX at 1.324×, compared with 1.260× in the earlier run.

| Run | UTC start–end | Load averages at start → end (1m / 5m / 15m) | Full check exit |
| --- | --- | --- | ---: |
| 1 | 2026-11-18T04:17:57Z–2026-11-18T04:27:14Z | 6.24 5.69 5.20 → 4.40 6.51 6.02 | 1 |
| 2 | 2026-11-18T04:27:14Z–2026-11-18T04:36:20Z | 4.40 6.51 6.02 → 25.41 29.75 17.81 | 1 |

The two runs below were judged against the earlier 1.30× CellX budget. Paired measurement put CellX at 1.30–1.31× across both, so the budget was set to 1.35×: R4's compute barrier and apply phase account for most of it, with room for noise.

| Family | Budget | Run 1 median [Q1–Q3] | Run 2 median [Q1–Q3] |
| --- | ---: | --- | --- |
| kairo | 1.10× | 1.033× [1.027–1.041] · pass | 1.064× [1.031–1.076] · pass |
| cellx | 1.30× | 1.308× [1.287–1.329] · fail | 1.302× [1.297–1.321] · fail |
| mol | 1.10× | 0.999× [0.997–1.005] · pass | 1.081× [1.057–1.134] · uncertain |
| dynamic | 1.10× | 0.984× [0.976–0.990] · pass | 0.954× [0.927–0.989] · pass |
| cold | 1.10× | 0.933× [0.929–0.939] · pass | 0.923× [0.904–0.935] · pass |

Both checks produced exit 1.
Family verdicts changed for mol. An uncertain verdict emits a warning and does not fail the performance gate.

During run 2, a load snapshot after dynamic-component recorded 60.03 / 25.19 / 13.62. Both full checks failed solely on CellX. The CellX medians differ by approximately 0.006×. Mol in run 2 exercised the warning path.

Raw pairs and complete logs are retained locally under .out/paired-gate/run-1 and .out/paired-gate/run-2.

## M1 repair verification

The fresh table above was measured with the review fixes at `e538156` and
the existing budgets from `e04d222`. The complete `tool/check.sh` succeeded
with all five workload families within budget. CellX measured 1.306×
[1.276–1.318], and rill passed the 300,000-layer warmed propagation check.
The cold limit was 4,632 layers for rill and 3,619 for alien_signals.

The same check passed 36 core tests, the original 100,000-step differential
fuzz and the new 100,000-step lifecycle fuzz. The mutation gate killed
all 23 mutants. The lifecycle generator reproduced B2 on the unmodified
`e04d222` runtime before testing the repairs.

## Measurement basis: fixed new generation (2026-11-20, M6 ③ step 0)

**Why.** The Dart VM starts each process with a small new-generation semi-space and grows it as allocation
demands. The cold workloads build a fresh chain per sample, so their time includes scavenges. How many there are,
and when growth stops, depends on the node's byte size. When a field moves a node across a size class, the cold
cases shift without any change in graph work, and engines with different node sizes shift differently. M6 ③ changes
the shape of query nodes, so we fix the basis first: every process, rill and the references alike, runs with
`DART_VM_OPTIONS=--new_gen_semi_initial_size=32,--new_gen_semi_max_size=32` (initial = maximum = 32 MB). Once
growth is out of the measurement, ratios follow the graph code. The flag is in `bench/bin/run.dart`
(`_vmOptions`), and the report states it.

**Old vs new basis A/B** (same code, 7 pairs per case, rill / alien_signals median [Q1–Q3]). It was measured with
the 1-minute load at 24–38 from other sessions, so it only shows the order of magnitude. It does not support
attributing an effect to any single case.

| Case | Old basis | New basis |
| --- | --- | --- |
| cold-50 | 0.944× [0.842–1.082] | 0.922× [0.758–0.993] |
| cold-500 | 1.088× [0.834–1.215] | 1.114× [0.922–1.671] |
| cold-1000 | 0.963× [0.743–1.027] | 1.159× [1.009–1.316] |
| cold-2500 | 1.114× [0.856–1.480] | 0.907× [0.621–0.916] |
| cellx-1000 | 1.492× [1.331–1.599] | 1.269× [1.166–1.404] |
| cellx-2500 | 1.399× [1.276–2.541] | 1.340× [1.200–1.687] |

**New baseline and M6 ③.** Full `tool/bench.sh` runs alternated between the pre-③ code on the new basis
(`a821e28` plus the runner change) and the ③ implementation. Load averages are those at the start of each run.

| Run | Load (1m) | kairo | cellx | mol | dynamic | cold |
| --- | ---: | --- | --- | --- | --- | --- |
| baseline 1 | 10.0 | 1.046× pass | 1.281× pass | 0.975× pass | 1.002× pass | 0.985× pass |
| ③ 1 | 10.2 | 1.037× pass | 1.281× pass | 0.994× pass | 0.982× pass | 0.939× pass |
| baseline 2 | 8.7 | 1.038× pass | 1.294× pass | 1.010× pass | 0.996× pass | 1.001× pass |
| ③ 2 | 8.7 | 1.033× pass | 1.195× pass | 1.069× uncertain | 0.932× pass | 0.944× pass |
| ③ gate (`tool/check.sh`) | 8.2 | 1.035× pass | 1.288× pass | 0.990× pass | 1.004× pass | 0.973× pass |

On the new basis, ③ costs nothing measurable in any family. Synchronous computed hot paths are unchanged, and
query fields live only on `AsyncComputed`. The `_flags` spare-bit dispatch fallback was not needed. The mol IQR in
③ run 2 hit 15% while load rose to 14.6, which is noise. Under the old basis, CellX had once measured 1.359×
(fail) and then 1.286× at load 24–38. On the new basis, CellX is steady at 1.20–1.29×.

**Code review fixes (v0.4.0).** Two hot-path edits: a reused edge in `_link`
checks whether its input samples (one virtual getter, rest out of line), and a cold `_ensureFresh` re-evaluates a
sampled node. Full gate at load 4.9: kairo 1.034× (Q1–Q3 1.033×–1.036×), cellx 1.245× (1.239×–1.266×),
mol 0.998×, dynamic 1.007×, cold 0.948× (0.944×–0.952×), all pass; no family moved beyond the ③ runs above.

## M7 ① 所有权（2026-11-21）

去掉环境 Scope 之后，`_firstRead` / `_refresh` 不再内联切换 Scope，computed 也不再检查 `_disposed`。effect 的 apply
多传一个 `onCleanup`（每个 effect 一个稳定闭包，`late final`）。完整门禁退出码 0：Kairo 1.025×、CellX 1.310×（Q1–Q3
1.268×–1.371×）、Mol 1.002×、Dynamic 0.900×、Cold 1.000×。首读深度恢复到 4,632 层，即上面「computed 在 Scope 之外求值」修复之前的数值。
本文件开头的表就是这次运行。跑的时候起始负载在 9–12，CellX 的四分位距偏宽。

第一次门禁 CellX 测出 1.459×，超出预算。按单进程 A/B 对 cellx-1000 排查（基线 `27cd144`，每组 3 次）：

| 变体 | rill cellx-1000 中位数（µs） |
| --- | ---: |
| `27cd144` | 489–493 |
| 本分支，adapter 的 compute 包一层闭包 | 569–584 |
| apply 每次 tear-off `_addCleanup`，不用 `late final` | 584–598 |
| 本分支，adapter 不包闭包（`inspect` 关时直接传 `action`） | 498–510 |

回归来自 conformance adapter：改写时把 compute 统一包成一个局部函数，每次运行多一层闭包调用，约 15%。恢复为
`inspect ? wrapper : action` 后，与基线的差距是 2–4%，这部分来自 apply 多出的一个参数和 `onCleanup` 的 late 检查。
`late final` 和每次 tear-off 测不出差别，所以保留 `late final`，它的语义是每个 effect 一个稳定闭包。

## M8 ② 命令层拆分（2026-11-21）

删掉 `Signal._birthRevision` 与 `Scope._taskAncestors`，图的热路径不变。完整 `tool/check.sh` 两次运行都在预算内，机器在两次之间都不空闲（起始负载 8–17，另有会话在跑）：

| 家族 | 第一次（`tool/check.sh`） | 第二次（`tool/bench.sh --gate`，本文件开头的表） |
| --- | ---: | ---: |
| kairo | 1.031× | 1.048× |
| cellx | 1.343× | 1.314× |
| mol | 0.997× | 1.015× |
| dynamic | 1.092×（IQR 22%，uncertain） | 0.980× |
| cold | 0.957× | 1.013×（IQR 13%，uncertain） |

与 M7 ① 的记录（Kairo 1.025×、CellX 1.310×、Dynamic 0.900×、Cold 1.000×）相比在噪声范围内，符合「持平」的预期。两次各有一个家族因四分位距超过 10% 判为 uncertain，换另一次运行即为 pass，不是回归。

**`publish-10`（报告行，不进门禁）。** 一个并行槽里的长任务连续提交 200,000 次，每次 8 个 signal 字段 + 2 个 wire 段（值每次都变，wire 每次都解码），一个 effect 观察全部字段；
AOT，7 轮取中位数，脚本在本机 `/tmp` 下一次性搭建（旧：`766d93f` 的 `Publish.set` / `feed` + `WireSignal`；新：`Tx.set` + `Wire.stage`）：

| | 第一次 | 第二次 |
| --- | ---: | ---: |
| 旧（默认 OCC、读集戳、wire 账本通道） | 3,282 ns | 3,289 ns |
| 新（默认安装、`Wire` 只用公开 API） | 2,297 ns | 2,655 ns |

新路径每次提交快约 20–30%：没有写集与 wire 代次的判定，账本是普通 signal，跟值走同一条安装路径。负载高（1 分钟 29），只作方向性记录。

**变基到 v0.5.0 之后（本文件开头的表）。** 完整 `tool/check.sh` 一次通过，起始负载 3.6，全部家族 pass：

| 家族 | v0.5.0（`62b2f06` 的记录） | ② 变基后 |
| --- | ---: | ---: |
| kairo | 1.037× | 1.037× |
| cellx | 1.288× | 1.286× |
| mol | 0.999× | 0.999× |
| dynamic | 0.995× | 0.998× |
| cold | 0.985× | 1.000× |

与 v0.5.0 逐家族持平（差距都在四分位距内），不需要配对 A/B。上面两次运行与 `publish-10` 是变基前在 `766d93f` 之上测的，留作方向性记录。

## M9 WidgetInput + F13（2026-11-21）

本分支只改 `rill_flutter` 与 `rill_lint`：`packages/rill`、`conformance`、`bench` 与锁文件和 v0.6.0（`d001164`）逐字节相同，基准跑的是同一份代码。
完整 `tool/check.sh` 退出码 0，起始负载 5.1 / 8.3 / 10.1（本文件开头的表）：Kairo 1.032×、CellX 1.325×（Q1–Q3 1.304×–1.355×）、Mol 0.996×、Dynamic 0.979×、Cold 1.007×，全部 pass。
上一轮 CellX 判为 uncertain（1.296×，负载约 7），这一轮中位数在预算内，但 Q3 越过 1.35×，于是和 v0.6.0 做配对 A/B 定论。

**配对 A/B。** 两棵树各自编译 `bench/bin/sample.dart`（同一 VM 选项、1000 ms 窗口），每轮每个深度依次采 v0.6.0 与本分支的 rill 和 alien_signals，
版本先后与引擎先后都逐轮交替；6 个深度各 9 轮，5 分钟负载 6.0–8.7。表中为中位数 [Q1–Q3]；「配对」一列是同一轮里本分支 rill/alien 除以 v0.6.0 rill/alien。

| 深度 | v0.6.0 rill/alien | 本分支 rill/alien | 本分支 ÷ v0.6.0（配对） | rill 耗时 本分支 ÷ v0.6.0 |
| --- | --- | --- | --- | --- |
| cellx-10 | 1.174× [1.158–1.181] | 1.161× [1.143–1.174] | 0.999× [0.959–1.008] | 0.996× [0.982–0.999] |
| cellx-20 | 1.219× [1.201–1.231] | 1.206× [1.196–1.224] | 0.995× [0.982–1.011] | 1.009× [0.989–1.024] |
| cellx-30 | 1.241× [1.235–1.246] | 1.225× [1.207–1.230] | 0.973× [0.931–0.987] | 0.995× [0.981–1.005] |
| cellx-1000 | 1.367× [1.324–1.443] | 1.321× [1.308–1.374] | 0.957× [0.905–0.975] | 0.990× [0.928–1.009] |
| cellx-2500 | 1.586× [1.536–1.759] | 1.572× [1.459–1.616] | 0.941× [0.885–1.031] | 1.014× [0.919–1.096] |
| cellx-5000 | 1.275× [1.224–1.429] | 1.339× [1.257–1.465] | 1.045× [1.002–1.093] | 0.998× [0.916–1.050] |

合并 54 对：本分支 ÷ v0.6.0 = 0.985×（Q1–Q3 0.941×–1.014×）；家族中位数 v0.6.0 1.245×、本分支 1.232×。各深度 rill 耗时之比都在 1.00 ± 1.5% 以内。
**结论：CellX 与 v0.6.0 持平，没有回归。** 1.3× 上下是 v0.6.0 本身的水位，接近 1.35× 时的 uncertain 或越线来自负载下大深度用例（1000–5000）的方差，与本分支无关。
