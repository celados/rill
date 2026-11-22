// Port of rft cycleDetection.ts at 745e6eb. See LICENSE in this directory.
import '../../adapter.dart';
import 'fixture.dart';

const _guardRuns = 1_100_000;

final class _Guard {
  int _runs = 0;
  bool tripped = false;

  void tick() {
    if (tripped || ++_runs > _guardRuns) {
      tripped = true;
      throw FixtureError('test guard: runaway loop');
    }
  }
}

_Guard createGuard() => _Guard();

bool settle(void Function() fn) {
  try {
    fn();
    return false;
  } on StackOverflowError {
    throw FixtureError('stack overflow instead of cycle detection');
  } on Object {
    return true;
  }
}

void expectStillReactive(
  _Guard guard,
  int Function() runs,
  int runsBeforeCycle,
  void Function() write,
) {
  if (runs() > runsBeforeCycle) return;
  final before = runs();
  final threw = settle(write);
  expect(guard.tripped).toBe(false);
  expect(threw || runs() > before).toBe(true);
}

final cycleDetectionCases = <Fixture>[
  /**
   *  S(a) → E(eff) → S(a)  ⟳
   *
   * An effect reads a signal then writes back to it, unconditionally.
   * The framework must either throw or stop the loop by itself.
   */
  Fixture(61, "indirect cycle through effects", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final guard = createGuard();
    var runs = 0;
    final threw = settle(() {
      fw.effect(() {
        guard.tick();
        runs++;
        a.write(a.read() + 1);
      });
    });
    expect(guard.tripped).toBe(false);
    if (threw) return;
    expectStillReactive(guard, () => runs, 1, () => a.write(-1));
  }, mayNotTerminate: true),

  /**
   *  S(cond)  S(a)
   *     |      |
   *     E(eff)─┘
   *       |
   *       └─→ a.write(a.read()+1)  ⟳  (when cond=true)
   *
   * Effect is safe when cond=false. Setting cond=true creates an
   * unbounded read-write cycle on a. The framework must either throw
   * or stop the loop by itself.
   */
  Fixture(63, "cycle from modifying a branch (dynamic cycle creation)", (
    ReactiveAdapter fw,
  ) {
    final cond = fw.signal<dynamic>(false);
    final a = fw.signal<dynamic>(0);
    final guard = createGuard();
    var runs = 0;
    fw.effect(() {
      guard.tick();
      runs++;
      if (jsTruthy(cond.read())) {
        a.write(a.read() + 1);
      } else {
        a.read();
      }
    });
    a.write(1);
    expect(runs).toBe(2);
    final threw = settle(() => cond.write(true));
    expect(guard.tripped).toBe(false);
    if (threw) return;
    expectStillReactive(guard, () => runs, 2, () => a.write(-1));
  }, mayNotTerminate: true),

  /**
   *  S(a) → C(c) ⟳  (when a=0, c reads itself)
   *           |
   *         a.write(1) → C(c) reads a normally
   *
   * When a=0, c tries to read itself (cycle) and catches the error.
   * After setting a=1, c must recover and return a's value.
   */
  Fixture(153, "computed self-dep recovery after catching cycle error", (
    ReactiveAdapter fw,
  ) {
    final a = fw.signal<dynamic>(0);
    late final Readable<dynamic> c;
    c = fw.computed<dynamic>(() {
      if (jsStrictEqual(a.read(), 0)) {
        try {
          return c.read();
        } catch (_) {
          return -1;
        }
      }
      return a.read();
    });
    try {
      c.read();
    } catch (_) {}
    a.write(1);
    expect(c.read()).toBe(1);
  }, mayNotTerminate: true),

  /**
   *  S(a) → E(e1) → S(b) → E(e2) → S(a)  ⟳
   *
   * Two effects ping-pong values between two signals
   * (e1 reads a, writes b; e2 reads b, writes a+1) with no end
   * condition. The framework must cap iterations (throw or stop)
   * instead of looping forever.
   */
  Fixture(64, "max iteration limit reached", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final guard = createGuard();
    var runs = 0;
    final threw = settle(() {
      fw.effect(() {
        guard.tick();
        runs++;
        b.write(a.read());
      });
      fw.effect(() {
        guard.tick();
        a.write(b.read() + 1);
      });
    });
    expect(guard.tripped).toBe(false);
    if (threw) return;
    expectStillReactive(guard, () => runs, 1, () => a.write(-1));
  }, mayNotTerminate: true),

  /**
   *  S(a) → E(e1) → S(b) → E(e2) → S(c) → E(e3) → S(a)  ⟳
   *
   * Three effects forming a longer ping-pong cycle (e1 reads a writes
   * b; e2 reads b writes c; e3 reads c writes a). #64 tests a 2-effect
   * cycle; this variant verifies the framework's bounding holds for
   * longer cycles too — frameworks that detect direct (length-2) loops
   * may miss longer paths.
   */
  Fixture(221, "three-effect cycle stays bounded", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final c = fw.signal<dynamic>(0);
    final guard = createGuard();
    var runs = 0;
    final threw = settle(() {
      fw.effect(() {
        guard.tick();
        runs++;
        b.write(a.read());
      });
      fw.effect(() {
        guard.tick();
        c.write(b.read());
      });
      fw.effect(() {
        guard.tick();
        a.write(c.read() + 1);
      });
    });
    expect(guard.tripped).toBe(false);
    if (threw) return;
    expectStillReactive(guard, () => runs, 1, () => a.write(-1));
  }, mayNotTerminate: true),

  /**
   *  S(a) → E(e1) → S(b) → C(c) → E(e2) → S(a)  ⟳
   *
   * Cycle path goes through an intermediate computed: e1 writes b,
   * c is derived from b, e2 reads c and writes a. Differs from #64
   * (direct effect-effect) and #221 (effect-effect chain) — verifies
   * the bound holds when the cycle passes through a computed.
   */
  Fixture(223, "cycle through computed stays bounded", (ReactiveAdapter fw) {
    final a = fw.signal<dynamic>(0);
    final b = fw.signal<dynamic>(0);
    final c = fw.computed<dynamic>(() => b.read());
    final guard = createGuard();
    var runs = 0;
    final threw = settle(() {
      fw.effect(() {
        guard.tick();
        runs++;
        b.write(a.read());
      });
      fw.effect(() {
        guard.tick();
        a.write(c.read() + 1);
      });
    });
    expect(guard.tripped).toBe(false);
    if (threw) return;
    expectStillReactive(guard, () => runs, 1, () => a.write(-1));
  }, mayNotTerminate: true),
];
