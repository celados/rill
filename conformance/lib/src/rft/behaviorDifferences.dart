// Port of rft behaviorDifferences.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

final behaviorDifferencesCases = <Fixture>[
  /**
   *  S(a) ─→ C(b)
   *
   * Determines whether creating a computed eagerly evaluates
   * its body or defers until the first `.read()` call.
   */
  Fixture(17, "computed evaluation timing", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var calls = 0;
    final b = fw.computed<dynamic>(() {
      calls++;
      return a.read();
    });
    final eagerCalls = calls;
    b.read();
    return jsTruthy(jsStrictEqual(eagerCalls, 0)) ? "lazy" : "eager";
  }, variants: <String>["lazy", "eager"]),

  /**
   *  S(a) ─→ C(b)
   *  S(a) ─→ C(c)   (c is never read)
   *
   * Determines whether a computed that is created but never
   * read still subscribes to its source and re-evaluates
   * when the source changes.
   */
  Fixture(15, "unread computed subscription", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>("a");
    final b = fw.computed<dynamic>(() => a.read());
    var cCalls = 0;
    fw.computed<dynamic>(() {
      cCalls++;
      return a.read();
    });
    // c is never read
    b.read();
    final callsBefore = cCalls;
    a.write("aa");
    b.read();
    return jsTruthy(jsStrictEqual(cCalls, callsBefore))
        ? "no subscription"
        : "subscribes eagerly";
  }, variants: <String>["no subscription", "subscribes eagerly"]),

  /**
   *  S(a) ─→ C(c)
   *  S(b) ─→ C(c)
   *
   * Two sources are written before C(c) is read. Checks
   * whether the framework coalesces into a single
   * re-evaluation or evaluates once per dirty source.
   */
  Fixture(146, "recompute count on multiple dep changes", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return a.read() + b.read();
    });
    c.read();
    cCalls = 0;
    a.write(1);
    b.write(1);
    c.read();
    return jsTruthy(cCalls <= 1) ? "single recompute" : "multiple recomputes";
  }, variants: <String>["single recompute", "multiple recomputes"]),

  /**
   *  S(a) ─→ C(c)
   *  a.write(NaN) when a already holds NaN
   *
   * Checks whether the framework uses Object.is (NaN === NaN)
   * or strict === (NaN !== NaN) to decide if a signal value
   * has changed.
   */
  Fixture(29, "NaN equality semantics", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(double.nan);
    var calls = 0;
    final c = fw.computed<dynamic>(() {
      calls++;
      return a.read();
    });
    c.read();
    calls = 0;
    a.write(double.nan);
    c.read();
    return jsTruthy(jsStrictEqual(calls, 0)) ? "Object.is" : "===";
  }, variants: <String>["Object.is", "==="]),

  /**
   *  S(a) ─→ C(c) ─→ C(d)
   *
   * C(c) returns NaN on consecutive evaluations.
   * Similar to #29, but tests equality semantics at the
   * computed-to-computed boundary. If C(c) returns NaN twice,
   * does C(d) skip re-evaluation (Object.is) or re-evaluate
   * (===)?
   */
  Fixture(167, "computed NaN downstream propagation", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(1);
    num value = 5;
    final c = fw.computed<dynamic>(() {
      a.read();
      return value;
    });
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return c.read();
    });
    d.read();
    value = double.nan;
    a.write(2);
    d.read();
    dCalls = 0;
    a.write(3);
    d.read();
    return jsTruthy(jsStrictEqual(dCalls, 0)) ? "Object.is" : "===";
  }, variants: <String>["Object.is", "==="]),

  /**
   *  S(a) ─→ C(c)
   *
   * Writes the same object reference back to a signal
   * (`a.write(obj)` where `obj` is already held).
   * Checks whether the framework treats it as a no-op
   * (skipped) or as a change that triggers downstream
   * re-evaluation.
   */
  Fixture(30, "same-reference signal write", (ReactiveAdapter fw) {
    final obj = <String, dynamic>{"x": 1};
    final a = fw.signal<dynamic>(obj);
    var calls = 0;
    final c = fw.computed<dynamic>(() {
      calls++;
      return a.read();
    });
    c.read();
    calls = 0;
    a.write(obj);
    c.read();
    return jsTruthy(jsStrictEqual(calls, 0)) ? "skips" : "propagates";
  }, variants: <String>["skips", "propagates"]),

  /**
   * Calls `fw.batch(() => 42)` and checks whether `batch`
   * forwards the return value of its callback to the caller.
   */
  Fixture(176, "batch return value", (ReactiveAdapter fw) {
    final result = fw.batch(() => 42);
    return jsTruthy(jsStrictEqual(result, 42))
        ? "returns value"
        : "returns void";
  }, variants: <String>["returns value", "returns void"]),

  /**
   *  S(a) ─→ E(eff1)          eff1: if a, b.write(1)
   *  S(a) ─→ E(eff2)          eff2: if a, read b
   *  S(b)  ─→ E(eff2)
   *
   * Two effects share S(a). When S(a) is set to true, eff1
   * writes to S(b). Does eff2 see the pre-write value of
   * S(b) (isolation) or the post-write value?
   */
  Fixture(173, "mid-propagation read isolation", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(false);
    final b = fw.signal<dynamic>(0);
    dynamic readerSaw = undefined;
    try {
      fw.effect(() {
        if (jsTruthy(a.read())) b.write(1);
      });
      fw.effect(() {
        if (jsTruthy(a.read())) readerSaw = b.read();
      });
      a.write(true);
      if (jsStrictEqual(readerSaw, 0)) return "pre-write";
      if (jsStrictEqual(readerSaw, 1)) return "post-write";
      throw FixtureError("reader saw ${readerSaw}");
    } catch (_) {
      return "throws";
    }
  }, variants: <String>["pre-write", "post-write", "throws"]),

  /**
   *  S(a) ─→ E(eff)
   *  S(b)
   *  eff: b.write(1); then b.read()
   *
   * Inside a single effect run, a signal is written and then
   * immediately read back. Does the read return the old value
   * (pre-write) or the just-written value (post-write)?
   */
  Fixture(174, "intra-run read-after-write", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(false);
    final b = fw.signal<dynamic>(0);
    dynamic readAfterWrite = undefined;
    try {
      fw.effect(() {
        if (jsTruthy(a.read())) {
          b.write(1);
          readAfterWrite = b.read();
        }
      });
      a.write(true);
      if (jsStrictEqual(readAfterWrite, 0)) return "pre-write";
      if (jsStrictEqual(readAfterWrite, 1)) return "post-write";
      throw FixtureError("read after write saw ${readAfterWrite}");
    } catch (_) {
      return "throws";
    }
  }, variants: <String>["pre-write", "post-write", "throws"]),

  /**
   *  S(a) ─→ E(eff)   (eff throws on first run)
   *
   * An effect reads S(a) then throws during its initial
   * execution. Checks whether the framework unsubscribes
   * the effect or keeps it subscribed for future writes.
   */
  Fixture(88, "effect subscription after first-run throw", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    var runs = 0;
    try {
      fw.effect(() {
        runs++;
        a.read();
        throw FixtureError("first run error");
      });
    } catch (_) {}
    runs = 0;
    try {
      a.write(1);
    } catch (_) {}
    return jsTruthy(jsStrictEqual(runs, 0))
        ? "unsubscribes"
        : "keeps subscribed";
  }, variants: <String>["unsubscribes", "keeps subscribed"]),

  /**
   *  S(a) ─→ E(eff1)
   *  S(a) ─→ E(eff2)   (eff2 throws when a===1)
   *  S(a) ─→ E(eff3)
   *
   * Three effects subscribe to S(a). The middle one throws
   * on update. Checks whether the framework continues
   * flushing the remaining effects or halts the entire flush.
   */
  Fixture(106, "effect throw isolation in flush", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var runs1 = 0;
    var runs3 = 0;
    fw.effect(() {
      a.read();
      runs1++;
    });
    try {
      fw.effect(() {
        final v = a.read();
        if (jsStrictEqual(v, 1)) throw FixtureError("effect2 error");
      });
    } catch (_) {}
    fw.effect(() {
      a.read();
      runs3++;
    });
    runs1 = 0;
    runs3 = 0;
    try {
      a.write(1);
    } catch (_) {}
    return jsTruthy(runs1 > 0 && runs3 > 0) ? "continues" : "halts flush";
  }, variants: <String>["continues", "halts flush"]),

  /**
   *  S(a) ─→ C(b)   (b throws when a===0)
   *
   * A computed throws on first evaluation. On the second read
   * (with deps unchanged), does the framework cache the error,
   * re-evaluate the body, or return a stale value?
   */
  Fixture(86, "computed error caching", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var calls = 0;
    final b = fw.computed<dynamic>(() {
      calls++;
      if (jsStrictEqual(a.read(), 0)) throw FixtureError("cached error");
      return a.read();
    });
    try {
      b.read();
    } catch (_) {}
    final callsAfter = calls;
    var secondThrew = false;
    try {
      b.read();
    } catch (_) {
      secondThrew = true;
    }
    if (calls > callsAfter) return "re-evaluates";
    if (secondThrew) return "caches error";
    return "returns stale";
  }, variants: <String>["re-evaluates", "caches error", "returns stale"]),

  /**
   *  S(a) ─→ C(b)   (b throws a string when a===0)
   *
   * Same as #86 but the thrown value is a plain string instead
   * of an Error instance. Tests whether non-Error throw values
   * are handled identically.
   */
  Fixture(107, "non-Error throw caching", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var calls = 0;
    final b = fw.computed<dynamic>(() {
      calls++;
      if (jsStrictEqual(a.read(), 0)) throw "string error";
      return a.read();
    });
    try {
      b.read();
    } catch (_) {}
    final callsAfter = calls;
    var secondThrew = false;
    try {
      b.read();
    } catch (_) {
      secondThrew = true;
    }
    if (calls > callsAfter) return "re-evaluates";
    if (secondThrew) return "caches error";
    return "returns stale";
  }, variants: <String>["re-evaluates", "caches error", "returns stale"]),

  /**
   *  S(s) ─→ C(c) ─→ E(eff)
   *  eff: if c > 0, s.write(0)   (self-correcting write)
   *
   * An effect reads a computed chain and writes back to the
   * root signal when the value is non-zero, creating a
   * feedback loop. Whether the effect re-runs after its own
   * write varies; blocking later writes is a defect (#212).
   */
  Fixture(49, "inner write re-run through computed chain", (
    ReactiveAdapter fw,
  ) {
    final s = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() => s.read());
    var runs = 0;
    try {
      fw.effect(() {
        runs++;
        if (runs > 20) throw FixtureError("bail");
        if (c.read() > 0) s.write(0);
      });
    } catch (_) {}
    runs = 0;
    try {
      s.write(1);
    } catch (_) {}
    final run1 = runs;
    final val1 = s.read();
    runs = 0;
    try {
      s.write(2);
    } catch (_) {}
    final run2 = runs;
    final val2 = s.read();
    if (jsStrictEqual(run1, 0) ||
        !jsStrictEqual(val1, 0) ||
        jsStrictEqual(run2, 0) ||
        !jsStrictEqual(val2, 0)) {
      throw FixtureError("self-correcting write did not settle (see #212)");
    }
    if (!jsStrictEqual(run1, run2))
      throw FixtureError("runs ${run1}x, then ${run2}x");
    if (jsStrictEqual(run1, 1)) return "runs once per write";
    if (jsStrictEqual(run1, 2)) return "runs twice per write";
    throw FixtureError("runs ${run1}x per write");
  }, variants: <String>["runs once per write", "runs twice per write"]),

  /**
   *  S(a) ─→ E(eff)
   *  eff: a.write(a.read() + 1)   (unconditional self-increment)
   *
   * An effect unconditionally reads and increments its source
   * signal, creating an infinite loop. Checks whether the
   * framework detects the cycle (throws), runs without
   * throwing, or requires a manual bail-out.
   */
  Fixture(62, "infinite loop in effect", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var iterations = 0;
    try {
      fw.effect(() {
        if (iterations++ > 200) throw FixtureError("bail");
        a.write(a.read() + 1);
      });
      return "no throw";
    } catch (_) {
      return jsTruthy(iterations <= 200)
          ? "cycle detected"
          : "manual bail (200+)";
    }
  }, variants: <String>["cycle detected", "no throw", "manual bail (200+)"]),

  /**
   *  S(a) ─→ E(eff1)
   *  eff1: b.write(a+1); c.write(a+2)
   *  S(b) ─→ C(d)
   *  S(c) ─→ C(d) ─→ E(eff2)
   *
   * An effect writes to two signals that both feed into a
   * downstream computed. Checks whether the framework batches
   * the two writes so that E(eff2) runs only once.
   */
  Fixture(175, "effect multi-signal write batching", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final c = fw.signal<dynamic>(0);
    fw.effect(() {
      final v = a.read();
      b.write(v + 1);
      c.write(v + 2);
    });
    final d = fw.computed<dynamic>(() => b.read() + c.read());
    var runs = 0;
    fw.effect(() {
      d.read();
      runs++;
    });
    runs = 0;
    a.write(10);
    return jsTruthy(runs <= 1) ? "batched" : "unbatched";
  }, variants: <String>["batched", "unbatched"]),

  /**
   *  run{ E(child ─→ S(source)); throw }
   *
   * A scope/root body creates a child effect then throws before
   * returning. Checks whether the framework disposes child
   * effects created before the throw or leaves them alive.
   */
  Fixture(246, "throwing run body child effect cleanup", (ReactiveAdapter fw) {
    final source = fw.signal<dynamic>(0);
    var childRuns = 0;
    try {
      fw.run(() {
        fw.effect(() {
          childRuns++;
          source.read();
        });
        throw FixtureError("scope setup failed");
      });
    } catch (_) {}
    childRuns = 0;
    try {
      source.write(1);
    } catch (_) {}
    return jsTruthy(jsStrictEqual(childRuns, 0))
        ? "disposes children"
        : "children survive";
  }, variants: <String>["disposes children", "children survive"]),

  /**
   *  E_outer{ E_inner1, E_inner2, E_inner3 } → dispose
   *
   * Probes the cleanup order of sibling effects when their owner
   * disposes. Frameworks with parent-child cascade tend to use
   * either LIFO (reverse creation) or FIFO (creation order). A
   * flat-effect framework (no cascade) reports "no cascade".
   */
  Fixture(244, "sibling cleanup order on dispose", (ReactiveAdapter fw) {
    final order = <dynamic>[];
    final dispose = fw.effect(() {
      fw.effect(() {
        return () => order.add(1);
      });
      fw.effect(() {
        return () => order.add(2);
      });
      fw.effect(() {
        return () => order.add(3);
      });
    });
    dispose();
    if (jsStrictEqual(order.length, 0)) return "no cascade";
    if (order.length < 3) return "partial cascade";
    final asStr = order.join(",");
    if (jsStrictEqual(asStr, "3,2,1")) return "LIFO";
    if (jsStrictEqual(asStr, "1,2,3")) return "FIFO";
    throw FixtureError("unexpected cleanup order ${asStr}");
  }, variants: <String>["LIFO", "FIFO", "partial cascade", "no cascade"]),

  /**
   *  S(a) → C(c) ═→ S(a) [increments a]
   *
   * Computed writes to its own dependency. After the first read, c's
   * value and a agree, so caching c and re-evaluating it on the next
   * read are both consistent; forbidding the write is valid too.
   */
  Fixture(172, "computed writing to own dep: next read", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var computeCalls = 0;
    try {
      final c = fw.computed<dynamic>(() {
        computeCalls++;
        a.write(a.read() + 1);
        return a.read();
      });
      c.read();
      final callsAfterFirst = computeCalls;
      c.read();
      return jsTruthy(computeCalls > callsAfterFirst)
          ? "re-evaluates"
          : "caches";
    } catch (_) {
      return "throws";
    }
  }, variants: <String>["re-evaluates", "caches", "throws"]),

  /**
   *  S(a) ─→ E_outer{ E_middle{ E_inner } }
   *                ✕ dispose outer
   *
   * Three levels of nesting, all reading a. Hierarchical ownership
   * disposes middle and inner with outer; a flat effect model keeps
   * them running (see #244).
   */
  Fixture(209, "three-level nested effect: disposal", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var middleRuns = 0;
    var innerRuns = 0;
    final dispose = fw.effect(() {
      a.read();
      fw.effect(() {
        a.read();
        middleRuns++;
        fw.effect(() {
          a.read();
          innerRuns++;
        });
      });
    });
    if (jsStrictEqual(middleRuns, 0) || jsStrictEqual(innerRuns, 0)) {
      throw FixtureError("nested effects did not run");
    }
    dispose();
    middleRuns = 0;
    innerRuns = 0;
    a.write(1);
    if (jsStrictEqual(middleRuns, 0) && jsStrictEqual(innerRuns, 0))
      return "cascades";
    if (jsStrictEqual(middleRuns, 0) || jsStrictEqual(innerRuns, 0))
      return "partial cascade";
    return "no cascade";
  }, variants: <String>["cascades", "partial cascade", "no cascade"]),

  /**
   *  S(a) ─→ E_outer{ E_b ─→ S(b),  E_c ─→ S(c) }
   *
   * Outer effect creates two inner effects and then re-runs.
   * Hierarchical ownership replaces the old inner effects; a flat
   * effect model keeps them, so each change runs old and new ones.
   */
  Fixture(210, "inner effects on outer re-run", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final c = fw.signal<dynamic>(0);
    var bRuns = 0;
    var cRuns = 0;
    fw.effect(() {
      a.read();
      fw.effect(() {
        b.read();
        bRuns++;
      });
      fw.effect(() {
        c.read();
        cRuns++;
      });
    });
    if (jsStrictEqual(bRuns, 0) || jsStrictEqual(cRuns, 0)) {
      throw FixtureError("inner effects did not run");
    }
    a.write(1);
    bRuns = 0;
    cRuns = 0;
    b.write(1);
    c.write(1);
    if (jsStrictEqual(bRuns, 1) && jsStrictEqual(cRuns, 1)) return "replaced";
    return "accumulates";
  }, variants: <String>["replaced", "accumulates"]),

  /**
   *      S(a)
   *     /    \
   *   *C(b)   C(d)
   *     |
   *   *C(c)
   *     |
   *    E(eff) → dispose
   *
   * b and c are only reachable through the effect. After it is
   * disposed, a write reaches them only under eager evaluation (see
   * #17).
   */
  Fixture(187, "unsubscribed computed after write", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>("a");
    var calls = 0;
    final b = fw.computed<dynamic>(() {
      calls++;
      return a.read();
    });
    final c = fw.computed<dynamic>(() {
      calls++;
      return b.read();
    });
    final d = fw.computed<dynamic>(() => a.read());
    var result = "";
    final dispose = fw.effect(() {
      result = c.read();
    });
    expect(result).toBe("a");
    expect(d.read()).toBe("a");
    calls = 0;
    dispose();
    a.write("aa");
    expect(d.read()).toBe("aa");
    return jsTruthy(jsStrictEqual(calls, 0)) ? "not evaluated" : "evaluated";
  }, variants: <String>["not evaluated", "evaluated"]),

  /**
   *  S(a)  S(b)
   *    |     |
   *    |   C(c)  ← c reads b
   *     \  /
   *     C(d)     ← d reads c only when a === 0
   *
   * One batch makes c stale and unreachable. Lazy evaluation skips
   * it; eager evaluation (see #17) runs it before d drops the edge.
   */
  Fixture(188, "batch + dynamic deps: stale unreachable computed", (
    ReactiveAdapter fw,
  ) {
    var cCalls = 0;
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() {
      b.read();
      cCalls++;
    });
    final d = fw.computed<dynamic>(() {
      if (jsStrictEqual(a.read(), 0)) {
        c.read();
      }
    });
    d.read();
    expect(cCalls).toBe(1);
    fw.batch(() {
      b.write(1);
      a.write(1);
    });
    d.read();
    return jsTruthy(jsStrictEqual(cCalls, 1)) ? "skipped" : "evaluated";
  }, variants: <String>["skipped", "evaluated"]),

  /**
   *  S(a)  S(b)  S(c)
   *    |           |
   *    |         C(d)  ← d reads c
   *    |          /
   *    C(e)      ← e reads b,d when a>0; only b when a≤0
   *
   * Unbatched writes to a, b, c after a≤0 makes d unreachable.
   * Whether d still runs depends on lazy vs eager evaluation (see
   * #17).
   */
  Fixture(248, "multi-signal change: stale unreachable computed", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(1);
    final b = fw.signal<dynamic>(1);
    final c = fw.signal<dynamic>(1);
    var dCalls = 0;
    final d = fw.computed<dynamic>(() {
      dCalls++;
      return c.read();
    });
    final e = fw.computed<dynamic>(() {
      b.read();
      if (a.read() > 0) d.read();
    });
    e.read();
    dCalls = 0;
    a.write(-1);
    b.write(-1);
    c.write(-1);
    e.read();
    return jsTruthy(jsStrictEqual(dCalls, 0)) ? "skipped" : "evaluated";
  }, variants: <String>["skipped", "evaluated"]),

  /**
   *  S(a) ─→ C(b) ─→ C(c)
   *           C(b) ─→ C(d)
   *           C(c) ?─→ C(d)   (when b is truthy)
   *
   * a becomes null, so d skips c although c's dep b changed. A
   * sequential dirty check never reaches c; eager evaluation (see
   * #17) runs it.
   */
  Fixture(193, "branch switch: stale unreachable computed", (
    ReactiveAdapter fw,
  ) {
    var cCalls = 0;
    final a = fw.signal<dynamic>(<String, dynamic>{"v": 1});
    final b = fw.computed<dynamic>(() => a.read());
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return jsOptionalProperty(b.read(), 'v');
    });
    final d = fw.computed<dynamic>(() => (jsTruthy(b.read()) ? c.read() : 0));
    expect(d.read()).toBe(1);
    expect(cCalls).toBe(1);
    a.write(null);
    expect(d.read()).toBe(0);
    return jsTruthy(jsStrictEqual(cCalls, 1)) ? "skipped" : "evaluated";
  }, variants: <String>["skipped", "evaluated"]),

  /**
   *  S(a) → C(c) → E(eff)
   *
   * batch { a.write(5); a.write(0) } — the source ends where it
   * started. Value-snapshot dirty checks see no change and skip c;
   * version-based checks (as in the TC39 polyfill's model) re-run it
   * and the equality cut-off stops propagation. Both are valid; the
   * final value is not a variant (see #125).
   */
  Fixture(132, "batch revert: subscribed computed", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return a.read() * 2;
    });
    fw.effect(() {
      c.read();
    });
    cCalls = 0;
    fw.batch(() {
      a.write(5);
      a.write(0);
    });
    expect(c.read()).toBe(0);
    return jsTruthy(jsStrictEqual(cCalls, 0)) ? "skipped" : "recomputed";
  }, variants: <String>["skipped", "recomputed"]),

  /**
   *  S(a) → C(c)
   *
   * Same as #132 with no subscriber: c is only read directly.
   */
  Fixture(147, "batch revert: unsubscribed computed", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    var cCalls = 0;
    final c = fw.computed<dynamic>(() {
      cCalls++;
      return a.read();
    });
    c.read();
    cCalls = 0;
    fw.batch(() {
      a.write(5);
      a.write(0);
    });
    expect(c.read()).toBe(0);
    return jsTruthy(jsStrictEqual(cCalls, 0)) ? "skipped" : "recomputed";
  }, variants: <String>["skipped", "recomputed"]),

  /**
   *  E_outer{ E_child{ E_grandchild } } → dispose
   *
   * Order of cleanups when the outer effect is disposed. Owner trees
   * may tear down children first (LIFO) or the owner first; flat
   * effect models don't cascade at all.
   */
  Fixture(
    241,
    "nested cleanup order on dispose",
    (ReactiveAdapter fw) {
      final log = <dynamic>[];
      final dispose = fw.effect(() {
        fw.effect(() {
          fw.effect(() {
            return () => log.add("grandchild");
          });
          return () => log.add("child");
        });
        return () => log.add("outer");
      });
      dispose();
      final order = log.join(",");
      if (jsStrictEqual(order, "grandchild,child,outer"))
        return "deepest first";
      if (jsStrictEqual(order, "outer,child,grandchild"))
        return "outermost first";
      if (jsStrictEqual(order, "outer")) return "no cascade";
      if (!log.contains("outer")) {
        throw FixtureError("outer cleanup did not run (see #238)");
      }
      return "partial cascade";
    },
    variants: <String>[
      "deepest first",
      "outermost first",
      "partial cascade",
      "no cascade",
    ],
  ),

  /**
   *  S(a) ← E(eff1)
   *       ← E(eff2)
   *       ← E(eff3)
   *
   * Order in which independent sibling effects run on two successive
   * writes. No library contract fixes it.
   */
  Fixture(216, "sibling effect order on shared signal", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final order = <dynamic>[];
    for (final i in <dynamic>[1, 2, 3]) {
      fw.effect(() {
        a.read();
        order.add(i);
      });
    }
    order.length = 0;
    a.write(1);
    final first = order.join(",");
    order.length = 0;
    a.write(2);
    final second = order.join(",");
    if (<dynamic>[
      first,
      second,
    ].any((o) => !jsStrictEqual((o.split(",")..sort()).join(","), "1,2,3"))) {
      throw FixtureError(
        "each effect must run once per write: ${first}; ${second}",
      );
    }
    if (jsStrictEqual(first, "1,2,3") && jsStrictEqual(second, "1,2,3"))
      return "creation order";
    return "varies";
  }, variants: <String>["creation order", "varies"]),
];
