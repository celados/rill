---
type: Reference
title: rill mutation checks
description: How tool/mutate.dart works, and every current mutant with the test that killed it in the latest full run.
timestamp: 2026-11-22
---

# rill 变异测试

`dart run tool/mutate.dart` 在临时 pub workspace 先验证原版，再逐个替换库源码里的一处判断。
脚本要求每次替换只匹配一个位置，且至少一条实际执行的测试失败。编译失败、测试加载失败或变异存活均使门禁失败。

## 用法

```sh
dart run tool/mutate.dart                       # 全部 mutant（tool/check.sh 与 --no-bench 调用的就是这一条）
dart run tool/mutate.dart --file query.dart     # 只跑目标文件是 query.dart 的 mutant
dart run tool/mutate.dart --only "cold read"    # 只跑名字含该子串的 mutant
dart run tool/mutate.dart --file debug.dart --only refusals     # 两种过滤同时满足
dart run tool/mutate.dart --changed             # 只跑本分支（在 main 上则为上个 tag 以来）改过的库文件的 mutant（check.sh --quick）
dart run tool/mutate.dart --jobs 4              # 同时跑 4 个 mutant，各在自己的临时 workspace（默认 核数/3，至少 1）
dart run tool/mutate.dart --shard 2/4           # 只跑 4 个分片中的第 2 个（CI 的 mutate job）
dart run tool/mutate.dart --shard 1/4 --shard 2/4 --jobs 8   # 大机器一次领多个分片
dart run tool/mutate.dart --shard 3/4 --list    # 只列出会跑的 mutant（类别 + 名字），不跑
```

- 跑完全部选中的 mutant 才结束，最后一次列出所有存活者（按声明顺序，与并行交错无关）；有存活者就以退出码 1 结束，不在第一个存活者处停下。
- `--only` / `--file` 可重复，同类取并集、两类取交集；`--file` 按 mutant 的目标文件名（`runtime.dart`、`query.dart`、`observer.dart`……）匹配；
  `wire.dart` 在 `lib/` 而不在 `lib/src/`，用 `--file ../wire.dart` 选中。
- `--shard i/n` 在过滤之后分片：按声明顺序（核心、process、Flutter）把每个 mutant 放进当前预估耗时最少的分片（核心 6、process 3、Flutter 3，单位秒；平局取序号小的）。
  同一选择下分片确定，n 个分片的并集恰好是全集、互不重叠；可重复给出同一 n 的多个分片。
- `--jobs N` 开 N 个独立的临时 workspace，用一个队列并行喂 mutant；每个 workspace 只被一个 mutant 改动。核心测试自身已按核数并发，所以收益在 3–4 个 job 处饱和：
  在 10 核 M1 Pro 上（同时有其他负载）全量 144 个：`--jobs` 1 / 2 / 3 / 4 / 6 = 964 s（含一次 420 s 挂死）/ 262 s / 215 s / 176 s / 188 s。
  默认取 核数/3，给同机其他任务留余量。
- 不论过滤与否，所有 mutant 的原文都先在 checkout 里校验「恰好匹配一处」，过期的 mutant 立即报错；本次选中的 mutant 里没有核心（或 Flutter）mutant 时跳过对应的基线测试。
- 迭代时只跑相关文件的 mutant，分支交付用 `tool/check.sh --quick`（`--changed`）；全部 mutant 由 CI 每次 push 分片跑，发版前本机再跑一次完整门禁。
- `--changed` 只看库文件是否改动：只改测试时不重跑未改文件的 mutant，这个缺口由 CI 的全量运行兜住。
- 核心测试带 `--fail-fast`：第一个失败的测试即判死（否则一个让所有查询测试都挂起的 mutant 要逐个等满 5 s 超时）。
- 每次测试运行有挂死上限，到时 SIGKILL：流事件在微任务里送达，把工作变成经流事件反馈的 mutant 会饿死事件循环，
  测试自己的超时触发不了；被杀的运行记为判死（`hung past <n>s (killed)`）。上限按类型取：核心套件 60 s（正常 5–6 s），process 测试 180 s（其内部上限最长 60 s，另有编译），
  Widget 测试在假时间下运行，不设上限。是否挂死取决于测试运行器先调度到哪条测试，所以每次运行都可能有不同的 mutant 撞上限；它就是分片耗时的长尾。
- 杀死者按测试**结束**先后取第一个失败的（`--fail-fast` 取消的长测试排在真正失败的那个之后）。下表的「首个杀死它的测试」因此是一次运行的观察值，
  并发调度不同时可能换成另一条同样失败的测试。

## 当前 mutant 与杀死它们的测试

2026-11-22 全量运行（`--jobs 4`，221 s）：**核心 118/118（含 6 个 process mutant）、Flutter 52/52** 全部判死，没有挂死。
表中测试名是完整名（含 group 前缀）。

### 核心（`packages/rill/lib`，核心测试套件判定）

| 变异 | 首个杀死它的测试 |
| --- | --- |
| signal equality early return | `wait cycles, expiry, supersession and retries wait_on_a_sampled_upstream_marks_the_reader` |
| revision on every install | `why a reader ran a computed chain reaches the write and its call site` |
| quiet ABA pulldown | `installs advance inside batch and ABA stays quiet` |
| pending flag pull | `first cycle via a, observed=true` |
| cold dependency version | `question, reconcile and derived state input_change_while_cold_is_stale_on_first_frame` |
| cold first subscriber attaches upstream | `first cycle via a, observed=true` |
| cold last subscriber detaches upstream | `unmounting_the_last_reader_of_a_query_sampling_a_clock_cools_it` |
| cleanup precedes apply | `stopping before release applies nothing; cleanup and errors flow` |
| debug feedback round limit | `feedback_through_a_new_query_each_run_runs_out_of_rounds` |
| write guard independent of active subscriber | `untracked blocks dependency collection and preserves write guard` |
| computed equality prunes the graph | `why a reader ran an equal computed output stops the chain and records nothing` |
| defer the next observer when a callback queues work | `each deferred observer consumes the settled graph` |
| recover the interrupted effect round | `a fatal compute leaves earlier prepared and later effects armed` |
| a fatal refresh requires retry | `a fatal refresh never exposes an obsolete hot or cold value` |
| preserve a fatal from the flush body | `a fatal from apply wins over a throwing ordinary error handler` |
| prefer a fatal from the error handler | `a fatal from the handler wins over its earlier ordinary error` |
| isolate ordinary subscriber notification errors | `a throwing subscriber does not interrupt propagation` |
| dispose deep Scope trees iteratively | `deep Scope disposal is iterative, child-first and LIFO` |
| owner disposal revokes publication and cancels | `held handles of cancelled tasks held_handle_of_a_cancelled_task_closes_when_its_future_settles` |
| supersede revokes previous flight | `staging events, late commits and refusal records transact_in_a_lapsed_task_reports_late_write` |
| skip prevents admission while busy | `conditions are values unchanged_taken_before_request_guards_another_task` |
| queue starts in admission order | `queued RPC failure stays in the admission error zone` |
| same key reuses the future | `delivery decides joined_callers_share_one_verdict` |
| final check after all staging | `revalidates after staging disposes its owner` |
| delivery checks the owner | `delivery decides owner_disposed_before_caller_resumes_delivers_stale` |
| delivery runs in its own microtask | `delivery decides owner_disposed_before_caller_resumes_delivers_stale` |
| a throwing part rolls back | `savepoints part_exception_rolls_back_and_rethrows_original_stack` |
| require in a part belongs to the part | `savepoints part_unmet_returns_false` |
| a kept part is checked again with the commit | `savepoints part_broken_after_returning_true_fails_the_commit` |
| staging is checked like a computation | `transact staging_rejects_bare_writes_and_nested_commits` |
| end bookkeeping waits for the boundary | `delivery decides queued_body_never_starts_inside_another_batch` |
| Skipped is delivered with the owner check | `outcomes and handles skipped_rechecks_the_owner_at_delivery` |
| Unchanged samples a binding signal | `Unchanged unchanged_samples_an_unwatched_binding_signal` |
| Unchanged calibrates a hot computed | `Unchanged unchanged_calibrates_a_paused_clock_under_a_hot_computed` |
| transact checks the write guard | `transact staging_rejects_bare_writes_and_nested_commits` |
| only an ended body reports a closed publication | `staging events, late commits and refusal records refusals_filter_by_slot_and_slot_name` |
| emit checks staging | `staging events, late commits and refusal records emit_during_staging_throws` |
| transact in a lapsed task is late | `staging events, late commits and refusal records transact_in_a_lapsed_task_reports_late_write` |
| a flushed reaction is not the task | `staging events, late commits and refusal records transact_in_a_lapsed_task_reports_late_write` |
| refusals match their slot | `staging events, late commits and refusal records refusals_filter_by_slot_and_slot_name` |
| capacity trims refusals | `staging events, late commits and refusal records capacity_and_limit_trim_refusals` |
| limit truncates refusals | `staging events, late commits and refusal records capacity_and_limit_trim_refusals` |
| the ledger turns a JSON object into Map<Object?, Object?> | `typed_field_reader_shared_by_decoder_and_comparator` |
| query yields to a pending dependency update | `an_upstream_event_sent_from_onCancel_converges_on_its_value` |
| a failed new question does not revive the previous answer | `state, new question and refresh a new question can show A while loading but B failing has no previous` |
| validate concrete signal before installation | `rejects widened staging types (event=false)` |
| validate concrete event before installation | `rejects widened staging types (event=true)` |
| rethrow the original query stack | `AsyncState valueOrNull, requireValue and map follow hasPrevious` |
| deferred first apply runs at creation | `compute tracks at once; the first apply waits for release` |
| release applies a withheld value | `a failing compute withholds the first apply until one succeeds` |
| failed compute keeps the held value | `a failing compute withholds the first apply until one succeeds` |
| first apply sees the held previous | `compute tracks at once; the first apply waits for release` |
| constant links into its readers | `a constant leaves no edge in its readers` |
| frame writes defer no effect | `frame writes effects it wakes wait for the drain; track exits do not drain` |
| an idle flush keeps the frame mark | `frame writes ordinary writes outside it still flush synchronously` |
| a full flush keeps the frame mark | `frame writes ordinary writes outside it still flush synchronously` |
| a frame write that installs nothing still marks | `frame writes ordinary writes outside it still flush synchronously` |
| release applies a held value a frame write made stale | `frame writes a held first apply woken by it is made by the drain, latest` |
| binding inputs sample on a cold pull | `an_unobserved_landing_is_installed_without_sampling` |
| a wait edge marks the sampled input | `wait cycles, expiry, supersession and retries wait_on_a_sampled_upstream_marks_the_reader` |
| a retained query samples the clock | `cooling retained_answer_within_ttl_no_request; expired_retained_answer_revalidates_swr` |
| expiry is derived in the pull | `cooling retained_answer_within_ttl_no_request; expired_retained_answer_revalidates_swr` |
| a refreshing answer is pending | `wait cycles, expiry, supersession and retries wait_on_refreshing_upstream_waits_for_new_answer` |
| a failed refresh resolves a new wait as an error | `wait cycles, expiry, supersession and retries wait_on_failed_refresh_resolves_error` |
| the comparator only records a resolution | `a_round_whose_producer_ended_delivers_no_second_wait` |
| equal upstream answers keep the downstream | `waiting upstream_equal_refresh_no_rerun` |
| retry reaches a failed upstream | `waiting retry_downstream_retries_failed_upstream` |
| retry leaves a retrying upstream alone | `wait cycles, expiry, supersession and retries retry_does_not_reinvalidate_retrying_upstream` |
| a cooling microtask yields to a new observer | `wait cycles, expiry, supersession and retries stale_cooling_microtask_yields_to_a_later_observer` |
| only work in flight keeps a timer | `cooling in_flight_with_retain_keeps_one_timer; timer_expiry_cancels_and_keeps_good_answer` |
| a retained answer records when it went cold | `cooling retained_answer_within_ttl_no_request; expired_retained_answer_revalidates_swr` |
| a held error is invalidated while cold | `cooling cooled_error_retries_on_return` |
| a lease does not skip held-error invalidation | `cooling keepalive_still_retries_cooled_error` |
| a cold landing ends the retention timer | `wait cycles, expiry, supersession and retries cold_landed_error_retries_on_return` |
| an ended round leaves its waits uncompleted | `answers, retention and diagnostics abandoned_wait_under_an_observed_downstream_stays_silent` |
| a cold stream close ends the retention timer | `wait cycles, expiry, supersession and retries cold_landed_error_retries_on_return` |
| a cold sampled node refreshes on any freshness check | `wait cycles, expiry, supersession and retries wait_on_a_sampled_upstream_marks_the_reader` |
| a reused edge carries the sampled mark | `answers, retention and diagnostics reused_edge_carries_the_sampled_mark` |
| a reused wait edge carries the sampled mark | `answers, retention and diagnostics reused_wait_edge_carries_the_sampled_mark` |
| AsyncState equality ignores the type argument | `answers, retention and diagnostics async_state_equality_is_symmetric` |
| a superseded attempt is cancelled | `a_leased_round_a_cold_peek made stale ends its producer` |
| a disposed Scope accepts registrations | `a disposed owner rejects it` |
| a throwing apply drops what it registered | `onCleanup apply_throwing_after_on_cleanup_still_cleans_up` |
| onCleanup after stop is dropped | `onCleanup on_cleanup_runs_last_first_and_late_calls_join_or_run` |
| an apply is not an explicit snapshot | `library snapshots are not untracked reads slot_run_and_apply_are_explicit_snapshots` |
| the Slot body is tracked by its starter | `library snapshots are not untracked reads slot_run_first_part_is_not_tracked_by_its_starter` |
| a throwing comparator escapes the landing | `comparators, waits and stream ends comparator_throw_lands_as_error_with_its_stack` |
| a reentrant comparator installs the superseded answer | `an_upstream_event_sent_from_onCancel_converges_on_its_value` |
| a wait-edge comparator throw escapes the pull | `cycle recovery and wait-edge comparator failures wait_edge_comparator_throw_is_a_recoverable_error_cold` |
| a wait-edge comparator failure is not the answer | `cycle recovery and wait-edge comparator failures wait_edge_comparator_throw_is_a_recoverable_error_cold` |
| each wait wraps the shared future | `comparators, waits and stream ends repeated_wait_returns_one_future_and_reports_one_error` |
| the next stream opens after a reentrant cancel | `an_upstream_event_sent_from_onCancel_converges_on_its_value` |
| an error event is not an answer | `comparators, waits and stream ends stream_error_then_done_keeps_the_error` |
| a failed edge comparison is forgotten | `independent cycles, edge recovery and round ends wait_edge_recovers_to_the_value_before_its_comparator_threw` |
| a failed stream factory leaves its round open | `independent cycles, edge recovery and round ends stream_factory_throw_ends_the_round` |
| a cycle failure is cached as validated | `first cycle via a, observed=false` |
| carried after-flush work counts as a round | `a_cold_wait_chain_unfolds_one_round_per_level (known limit)` |
| a leased round nobody asks for keeps its producer | `comparators, waits and stream ends stream_cancel_that_drops_last_reader_opens_no_stream` |
| a cold read that finds a new question keeps the round | `a_leased_round_a_cold_peek made stale ends its producer` |
| every step of a reconcile yields to the flush | `a_round_completing_many_waits_owes_no_round` |
| a pass that broke for effects is never counted | `feedback_through_a_new_query_each_run_runs_out_of_rounds` |
| a queued end does not hold the next wait | `a_round_whose_producer_ended_delivers_no_second_wait` |
| one step completes every wait | `a_round_completing_many_waits_owes_no_round` |
| an unobserved round listens to its stream | `a_factory_that_removes_the_last_reader_never_listens` |
| the factory step listens at once | `unmounting_the_last_reader_of_a_query_sampling_a_clock_cools_it` |
| a stream event is delivered inside the code that sent it | `stream_events_are_delivered_a_microtask_later` |
| deliveries that keep queuing deliveries are never counted | `a_comparator_that_always_sends_a_newer_answer_is_reported` |
| a wait after the first await only waits | `waiting a wait after an await throws and observes nothing` |
| the step guard lets a transition run after user code | `the_step_guard_refuses_a_transition_after_user_code` |
| an unobserved reconcile samples its question | `unmounting_the_last_reader_of_a_query_sampling_a_clock_cools_it` |
| a cached tracked wait completes at once | `cycle untying, landing rounds and cached waits a_cached_tracked_wait_resumes_only_while_observed` |
| a reconcile that moved the graph is not asked again | `cooling in_flight_with_retain_keeps_one_timer; timer_expiry_cancels_and_keeps_good_answer` |

### process（只有进程测试看得到，按名字跑 `test/process/query_process_test.dart` 的一条）

同步死循环（进程内超时打断不了，由进程测试的 kill 计时器判死）或只在强制 GC 下才可见的引用（debug 经 VM service、AOT 用分配压力）。

| 变异 | 首个杀死它的测试 |
| --- | --- |
| a cancelled attempt keeps its query | `cooled_query_is_not_held_by_a_pending_future` |
| validation revisits a node still in its cycle | `cycles_rounds_and_installs_in_debug` |
| a computed that gains an input is held | `no_scheduler_rounds_feedback_or_relink_table_in_debug` |
| a cooled query keeps its answer | `cooled_query_releases_its_answer_in_debug` |
| a cancelled run stays on its Future | `disposed_scope_releases_a_task_on_a_pending_future_in_debug` |
| a cut link holds its task | `pending_future_holds_no_disposed_scope_or_task_in_debug` |

### Flutter（`packages/rill_flutter/lib` 与核心 `runtime.dart`，按 widget 测试文件判定）

| 变异 | 首个杀死它的测试 |
| --- | --- |
| every notify marks the Flutter reader dirty | `equal derived output is idle (warm: false)` |
| reattach retains old paint | `a moved painter repaints a value written while detached` |
| clock ignores reader visibility | `wall clock aggregates readers through a shared computed` |
| every persistent notification queues a post-frame mark | `persistent marks are deduplicated and discarded on detach` |
| untracked reads are silent | `G1 / G2 / G3 read guard untracked_read_in_plain_build_throws` |
| sample retired cold inputs before running the current branch | `B1 cold derived values skip retired managed inputs` |
| ignore writes made while the subscriber is tracking | `B2 a native bridge write after consumption reaches the next frame` |
| skip listener cleanup after dispatch | `B3 last listener can remove itself and reattach` |
| linger samples before registering the recovery dependency | `B4 linger rethrows the original failure and later recovers` |
| watch applies first inside the build | `ReactiveState.watch runApp-like mount: first apply after the frame, no error` |
| deferred apply requests no frame | `ReactiveState.watch created while idle, it asks for the frame it waits on` |
| State keeps its scope after dispose | `ReactiveState.watch disposing the State stops its effects and runs cleanup` |
| bridge writes are ordinary | `R3b bridge listener written during a frame a live watch applies after the build, in the same frame` |
| activate leaves the reader unbuilt | `hosts, visibility and initState reads globalkey_move_of_a_reactive_without_inherited_dependencies_keeps_tracking` |
| the host wake-up leaves its update for after the frame | `hosts, visibility and initState reads tickermode_resume_shows_the_calibrated_pulse_in_the_same_frame` |
| a painter host does not reconcile on a dependency change | `hosts, visibility and initState reads reduce_motion_flip_stops_a_painter_phase` |
| visibility ignores TickerMode | `V1 / V2 visibility is a query tickermode_flip_pauses_pulse_without_rebuild` |
| decorative sources ignore reduced motion | `V1 / V2 visibility is a query reduce_motion_dependency_only_for_decorative_pulse` |
| the host reconciles inside notifyClients | `motion readers and painter hosts reduce_motion_flip_with_two_reactive_readers` |
| a painter host leaves its BuildOwner unguarded | `motion readers and painter hosts reactive_paint_alone_guards_its_build_owner` |
| painters without semantics rebuild semantics | `motion readers and painter hosts painter_without_semantics_does_not_rebuild_semantics` |
| an untracked frame read is let through | `G1 / G2 / G3 read guard untracked_read_in_plain_build_throws` |
| a cleanup founds a second State scope | `state_scope_identity_is_fixed_during_dispose` |
| pulse handles share only once observed | `pulse_handles_taken_before_observation_share_one_timer` |
| frame questions need a binding | `controller_test_without_binding_reads_through_a_listenable` |
| a pulse never registers its lifecycle observer | `pulse_observed_before_the_binding_follows_its_lifecycle` |
| a sync defers the readers below its owner | `WidgetInput listbox_items_replaced_in_did_update_widget_are_current_in_the_same_frame` |
| the subtree check ignores Element ancestry | `WidgetInput listbox_items_replaced_in_did_update_widget_are_current_in_the_same_frame` |
| the write guard does not exempt a sync | `WidgetInput listbox_items_replaced_in_did_update_widget_are_current_in_the_same_frame` |
| sync is an ordinary write | `WidgetInput listbox_items_replaced_in_did_update_widget_are_current_in_the_same_frame` |
| escaped readers are not reported | `WidgetInput reader_outside_the_owner_subtree_is_escaped` |
| every outside reader woken during a sync is escaped | `WidgetInput outside_reader_woken_by_a_pulse_during_sync_is_not_escaped` |
| sync is legal outside the owner window | `WidgetInput sync_from_another_build_in_a_later_frame_throws` |
| the owner window never closes | `WidgetInput sync_from_another_build_in_a_later_frame_throws` |
| sync is legal in the owner build | `WidgetInput sync_in_the_owner_build_throws` |
| sync after the owner is disposed is legal | `WidgetInput sync_in_the_owner_dispose_is_after_disposal` |
| a sync inside a batch is let through | `WidgetInput sync_inside_a_batch_throws` |
| a sync in the owner dispose is not after disposal | `WidgetInput sync_in_the_owner_dispose_is_after_disposal` |
| the composite host leaves its BuildOwner unguarded on activate | `F13 host composite_host_guards_its_build_owner_on_activate` |
| a composite reader has no host | `F13 host composite_reader_pulse_follows_tickermode` |
| the composite host does not reconcile in performRebuild | `F13 host composite_reader_phase_follows_reduced_motion_without_a_parent_rebuild` |
| the composite host does not reconcile when its parent rebuilds it | `F13 host composite_reader_phase_follows_reduced_motion` |
| re-attach waits for the next notification | `F13 opacity: a change updates the layer only; crossing zero drops paint and semantics` |
| transform origin: alignment is ignored | `F13 origin and alignment (v0.7.2) transform_origin_first_frame_corners: dialog: scale 0.97 about the centre` |
| transform origin: origin is ignored | `F13 origin and alignment (v0.7.2) transform_origin_first_frame_corners: origin alone: the centre in child coordinates` |
| transform origin: the alignment ignores the text direction | `F13 origin and alignment (v0.7.2) transform_origin_directional_alignment_resolves_rtl` |
| transform origin: the layer uses the raw matrix | `F13 origin and alignment (v0.7.2) transform_origin_first_frame_corners: dialog: scale 0.97 about the centre` |
| transform origin: hit tests use the raw matrix | `F13 origin and alignment (v0.7.2) transform_origin_hit_tests_about_the_alignment` |
| transform origin: applyPaintTransform uses the raw matrix | `F13 origin and alignment (v0.7.2) transform_origin_first_frame_corners: dialog: scale 0.97 about the centre` |
| transform origin: a placement change does not update the layer | `F13 origin and alignment (v0.7.2) transform_origin_alignment_change_updates_the_render_object_only` |
| transform origin: updateRenderObject drops the alignment | `F13 origin and alignment (v0.7.2) transform_origin_alignment_change_updates_the_render_object_only` |
| transform origin: updateRenderObject drops the text direction | `F13 origin and alignment (v0.7.2) transform_origin_directional_alignment_resolves_rtl` |

## 没有 mutant 的判断

以下分支刻意不设 mutant，因为去掉它们行为不变（等价变异）或另一处检查已兜住：

- 「保留最早的 held 值」：每次重算都先清 `_held`，与原版等价。
- `_FirstApply.release` 的「销毁后放行」检查：`_applyPrepared` 会再查一次销毁，去掉等价。
- 帧内托管写的 drain 跳过已销毁节点：`_prepare` 会再查一次销毁，去掉等价。
- Pulse 与 linger 的帧内写标记：今天没有活着的 effect 能经它们被唤醒，去掉不可观察；标记是为了让这个性质属于通道本身。
- 查询开工后的 `_reaches(question, question)` 环检查：去掉它会让环测试挂住而不是失败；开工前的预检被跳过时等价，因为开工后的检查晚一次开工抓到同一个环。
  `mutual_wait_cycle_fails_with_cycle`、`self_wait_fails_with_cycle` 直接覆盖防环规则。
- 挂载时的可见性与在 build 之外进入的装饰性 Pulse：在可见性查询下它们不是代码里的分支，而是直接问宿主的结果；`visibility ignores TickerMode` 已经去掉了这个问题。
- 求值链上「成员查询的落地算环内」「沿依赖边能到达成员的上游算环内」：检出环时的求值链只含经 pull 进入的节点，已找到的场景里去掉它们行为不变；它们是防御性的定义，
  判红交给双环与菱形回归。
- rill_lint 的规则不在 mutate 里（mutate 不变异 rill_lint），由 `packages/rill_lint/test/rules_test.dart` 的正反例与金丝雀 fixture 逐例校验。

## lifecycle fuzz

`conformance/lib/lifecycle_fuzz.dart` 还会随机改变图的生命期与环状态（观察、销毁、成环与解环）。门禁跑 100,000 步生成的生命期操作，
另有 100,000 步的差分 fuzz（`conformance/lib/fuzz.dart`）。
