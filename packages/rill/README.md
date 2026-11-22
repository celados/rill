---
type: Index
title: rill package
description: Pure Dart reactive primitives and their internal integration boundary.
timestamp: 2026-11-20
---

# rill

`package:rill/rill.dart` provides signals, computed values, split effects,
synchronous batching, untracked reads, and scopes. The graph adapts the
alien-signals system layer under its [MIT license](LICENSE).

```dart
final scope = Scope();
final count = signal(0);
final doubled = computed(() => count.value * 2);   // owned by no one
scope.effect(() => doubled.value, (value, previous, onCleanup) {
  final timer = Timer(const Duration(seconds: 1), () => print(value));
  onCleanup(timer.cancel);                         // before the next apply
});
count.update((value) => value + 1);
scope.dispose();                                   // stops the effect
```

There is no ambient owner. Derived values (computed, queries) belong to no
one: they hold reverse edges only while observed and go with their last
reference. Effects, Slots and external resources belong to the Scope they
are registered with (`scope.effect`, `scope.slot`, `scope.onDispose`,
`scope.child`); `Scope()` is always a root. A top-level `effect` has no owner
and returns the function that stops it.

An effect computes from its tracked inputs, then applies outside tracking.
Apply and cleanup can write signals. Work scheduled by those writes runs in
the next round. Resources made in an apply are registered with `onCleanup`
when they are made; registered cleanups run last-first before the next apply
and when the effect stops, even if the apply then throws.

Cold computed values retain dependency versions for subsequent reads. The
first subscriber reconnects reverse edges and the last subscriber detaches
them. A computed exception remains cached until its inputs invalidate it.
A failed effect compute cleans up any prior apply during the apply phase and
reports the original error after the other effects settle.

Async derivations (`computedAsync`, `computedStream`) are
`Readable<AsyncState<T>>`: reading one returns a sealed state and never
throws or starts work. A query works only while observed and cools when the
last observer leaves; `settled()` / `refresh()` wait imperatively and
`invalidate()` expires the answer. Inputs and `q.wait` are tracked only
before the first await; `q.wait` after it throws `RILL_READ_AFTER_AWAIT`
(a one-off answer is `source.settled()`). A `computedStream` is an
asynchronous source: its events reach the query a microtask after they are
sent, whatever the controller.

```dart
final user = computedAsync((q) async {
  final id = userId.value;                   // tracked: before the first await
  final token = await q.wait(session);       // tracked: called before it
  return api.profile(id, token, cancel: q.cancelled);
}, retain: const Duration(seconds: 30));

switch (user.value) {
  case AsyncData(:final value, :final refreshing): show(value, busy: refreshing);
  case AsyncLoading(): spinner();
  case AsyncError(:final error): retry(error, user.invalidate);
}
```

`package:rill/internal.dart` provides the revision clock and node revisions
for publication, the subscriber and post-flush callback for bindings, and
graph and diagnostic hooks for verification.

See the [verification workspace](../../README.md) for the test commands.
