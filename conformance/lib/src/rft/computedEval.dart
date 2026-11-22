// Port of rft computedEval.ts at 745e6eb. See LICENSE in this directory.
import 'dart:math' as math;

import '../../adapter.dart';
import 'fixture.dart';

final computedEvalCases = <Fixture>[
  /**
   *  S(a) → C(b)
   *
   * Reading a computed twice without changing its dep must not
   * re-evaluate the compute function (result is cached).
   */
  Fixture(18, "cached — not re-evaluated if deps unchanged", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var calls = 0;
    final b = fw.computed<dynamic>(() {
      calls++;
      return a.read();
    });
    expect(b.read()).toBe(0);
    expect(calls).toBe(1);
    // Read again without changing dep
    expect(b.read()).toBe(0);
    expect(calls).toBe(1);
  }),

  /**
   *  S(a) → C(b)
   *
   * After the source signal changes, the computed must return the
   * new derived value on the next read.
   */
  Fixture(19, "returns updated value after dep change", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read() * 2);
    expect(b.read()).toBe(0);
    a.write(1);
    expect(b.read()).toBe(2);
    a.write(5);
    expect(b.read()).toBe(10);
  }),

  /**
   *  S(a)  S(b)
   *    |      |
   *    |    C(c) ← c reads a
   *     \  /
   *     C(d)     ← d reads b when a===0, else reads c
   *
   * Dynamic dep switch: when a changes from 0 to 1, d drops b and
   * picks up c. Subsequent writes to b must not affect d.
   */
  Fixture(21, "chained computed dirty reallocation after trigger", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() => a.read());
    final d = fw.computed<dynamic>(() {
      if (jsStrictEqual(a.read(), 0)) {
        return b.read();
      }
      return c.read();
    });
    expect(d.read()).toBe(0);
    a.write(1);
    expect(d.read()).toBe(1);
    b.write(10);
    expect(d.read()).toBe(1);
  }),

  /**
   *  S(a) → C(b) → C(c) → C(d)
   *
   * Linear chain with call counters. After one source change,
   * each computed in the chain must re-evaluate exactly once.
   */
  Fixture(22, "chained computed avoids redundant re-compute", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var bCalls = 0;
    final b = fw.computed<dynamic>(() {
      bCalls++;
      return a.read();
    });
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return b.read();
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return c.read();
    });
    expect(d.read()).toBe(0);
    bCalls = 0;
    cCalls = 0;
    dCalls = 0;
    a.write(1);
    expect(d.read()).toBe(1);
    expect(bCalls).toBe(1);
    expect(cCalls).toBe(1);
    expect(dCalls).toBe(1);
  }),

  /**
   *  S(a) → C(b) → C(c)
   *                  |
   *                E(eff)
   *
   * An effect subscribes to the tail of a chain. A synchronous
   * read of c after writing a must trigger the effect.
   */
  Fixture(23, "sync access of invalidated chained computed runs effect", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() => b.read());
    var effectRuns = 0;
    fw.effect(() {
      c.read();
      effectRuns++;
    });
    expect(effectRuns).toBe(1);
    a.write(1);
    expect(c.read()).toBe(1);
    expect(effectRuns).toBe(2);
  }),

  /**
   *       S(a)
   *      /    \
   *    C(b)  C(c)
   *
   * Two computeds share one source. After a write, both must
   * re-evaluate (order is implementation-defined but both must run).
   */
  Fixture(24, "dependency evaluation order consistent with last access", (
    ReactiveAdapter fw,
  ) {
    final order = <dynamic>[];
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() {
      order.add("b");
      return a.read();
    });
    final c = fw.computed<dynamic>(() {
      order.add("c");
      return a.read();
    });
    // Access b then c
    b.read();
    c.read();
    order.length = 0;
    a.write(1);
    b.read();
    c.read();
    final bIdx = order.indexOf("b");
    final cIdx = order.indexOf("c");
    expect(bIdx).toBeGreaterThanOrEqual(0);
    expect(cIdx).toBeGreaterThanOrEqual(0);
    expect(bIdx).toBeLessThan(cIdx);
  }),

  /**
   *  C(a)   (no deps)
   *
   * A computed with no signal dependencies. After the initial
   * evaluation it must never re-compute.
   */
  Fixture(25, "no re-compute if zero dependencies", (ReactiveAdapter fw) {
    var calls = 0;
    final a = fw.computed<dynamic>(() {
      calls++;
      return 42;
    });
    expect(a.read()).toBe(42);
    expect(calls).toBe(1);
    // Read again — no deps means no reason to re-compute
    expect(a.read()).toBe(42);
    expect(calls).toBe(1);
  }),

  /**
   *  S(a) → C(b)
   *           |
   *         E(eff) → dispose
   *
   * A computed is subscribed by an effect, then the effect disposes.
   * The computed must still return correct values on direct read.
   */
  Fixture(26, "computed remains live after losing all subscribers", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() => a.read() * 2);
    // Subscribe then unsubscribe
    final dispose = fw.effect(() {
      b.read();
    });
    dispose();
    // Computed should still work when read directly
    a.write(5);
    expect(b.read()).toBe(10);
    a.write(10);
    expect(b.read()).toBe(20);
  }),

  /**
   *  S(a) → C(c)
   *
   * Computed returns undefined when a===0, else returns a.
   * undefined must be treated as a legitimate cached value,
   * not confused with an uninitialized state.
   */
  Fixture(145, "undefined is a valid computed value (not uninitialized)", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() {
      if (jsStrictEqual(a.read(), 0)) return undefined;
      return a.read();
    });
    expect(c.read()).toBe(undefined);
    a.write(1);
    expect(c.read()).toBe(1);
    a.write(0);
    expect(c.read()).toBe(undefined);
  }),

  /**
   *  S(a) → C(b) → C(c)
   *                  |
   *                E(eff)
   *
   * Inside a batch that writes a, the subsequent propagation must
   * evaluate b before c (topological order preserved).
   */
  Fixture(149, "batch preserves correct evaluation order", (
    ReactiveAdapter fw,
  ) {
    final order = <dynamic>[];
    final a = fw.signal<dynamic>(0);
    final b = fw.computed<dynamic>(() {
      order.add("b");
      return a.read();
    });
    final c = fw.computed<dynamic>(() {
      order.add("c");
      return b.read();
    });
    fw.effect(() {
      c.read();
    });
    order.length = 0;
    fw.batch(() {
      a.write(1);
    });
    expect(order.indexOf("b")).toBeGreaterThanOrEqual(0);
    expect(order.indexOf("c")).toBeGreaterThanOrEqual(0);
    expect(order.indexOf("b")).toBeLessThan(order.indexOf("c"));
  }),

  /**
   *  S(a) → C(c)
   *           |
   *         S(inner)  ← created inside c's compute function
   *
   * Creating a new signal inside a computed body must not throw.
   * The computed derives its value through the inner signal.
   */
  Fixture(115, "signal creation inside computed is allowed", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() {
      final inner = fw.signal<dynamic>(a.read() * 10);
      return inner.read();
    });
    expect(c.read()).toBe(0);
    a.write(3);
    expect(c.read()).toBe(30);
  }),

  /**
   *  S(a) → C(b) → C(c)
   *
   * b clamps a to [0, 10]. When a changes but b's clamped output
   * stays the same, c must NOT re-evaluate (value-equality cut).
   */
  Fixture(27, "downstream not re-evaluated unless value changed", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    // b clamps to [0, 10]
    final b = fw.computed<dynamic>(() => math.min(10, math.max(0, a.read())));
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return b.read();
    });
    expect(c.read()).toBe(0);
    cCalls = 0;
    // a goes negative but b stays 0
    a.write(-1);
    expect(c.read()).toBe(0);
    expect(cCalls).toBe(0);
    // a changes b
    a.write(5);
    expect(c.read()).toBe(5);
    expect(cCalls).toBe(1);
    cCalls = 0;
    // a goes over 10 but b stays 10
    a.write(11);
    expect(c.read()).toBe(10);
    cCalls = 0;
    a.write(20);
    expect(c.read()).toBe(10);
    expect(cCalls).toBe(0);
  }),
];
