import '../../adapter.dart';

final class Fixture {
  Fixture(
    this.id,
    this.title,
    this.run, {
    this.variants = const [],
    this.mayNotTerminate = false,
  });

  final int id;
  final String title;
  final Function(ReactiveAdapter) run;
  final List<String> variants;
  final bool mayNotTerminate;
}

enum _Undefined { value }

const undefined = _Undefined.value;

dynamic jsOptionalProperty(Map<String, dynamic>? object, String key) =>
    object == null ? undefined : object[key];

bool jsTruthy(Object? value) => switch (value) {
  null || false || _Undefined.value => false,
  num() => value != 0 && !value.isNaN,
  String() => value.isNotEmpty,
  _ => true,
};

bool jsStrictEqual(Object? a, Object? b) => switch ((a, b)) {
  (num(), num()) || (String(), String()) => a == b,
  _ => identical(a, b),
};

// rft's toBe uses Object.is, including NaN and signed zero.
bool _sameValue(Object? a, Object? b) {
  if (a is num && b is num) {
    if (a.isNaN && b.isNaN) return true;
    if (a == 0 && b == 0) return a.isNegative == b.isNegative;
  }
  return jsStrictEqual(a, b);
}

bool _deepEqual(Object? a, Object? b) {
  if (_sameValue(a, b)) return true;
  if (a is List && b is List && a.length == b.length) {
    for (var i = 0; i < a.length; i++) {
      if (!_deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map && a.length == b.length) {
    return a.keys.every((k) => b.containsKey(k) && _deepEqual(a[k], b[k]));
  }
  return false;
}

final class FixtureError implements Exception {
  FixtureError(this.message);
  final String message;

  @override
  String toString() => message;
}

void _require(bool condition, String message) {
  if (!condition) throw FixtureError(message);
}

RftExpectation expect(Object? actual) => RftExpectation(actual);

final class RftExpectation {
  RftExpectation(this.actual);

  final Object? actual;

  void toBe(Object? expected) => _require(
    _sameValue(actual, expected),
    'Expected $expected but got $actual',
  );

  void toEqual(Object? expected) => _require(
    _deepEqual(actual, expected),
    'Expected deep equal $expected but got $actual',
  );

  void toThrow([String? message]) {
    final callback = actual as Function();
    try {
      callback();
    } on Object catch (error) {
      _require(
        message == null || error.toString().contains(message),
        'Expected error containing "$message" but got "$error"',
      );
      return;
    }
    throw FixtureError('Expected function to throw but it did not');
  }

  NeverExpectation get not => NeverExpectation(actual as Function());

  void toBeGreaterThan(num value) =>
      _require((actual as num) > value, 'Expected $actual > $value');
  void toBeGreaterThanOrEqual(num value) =>
      _require((actual as num) >= value, 'Expected $actual >= $value');
  void toBeLessThan(num value) =>
      _require((actual as num) < value, 'Expected $actual < $value');
  void toBeLessThanOrEqual(num value) =>
      _require((actual as num) <= value, 'Expected $actual <= $value');

  void toHaveLength(int expected) {
    final length = (actual as List).length;
    _require(length == expected, 'Expected length $expected but got $length');
  }

  void toContain(Object? expected) => _require(
    (actual as List).any(
      (item) =>
          jsStrictEqual(item, expected) ||
          (item is num && expected is num && item.isNaN && expected.isNaN),
    ),
    'Expected $actual to contain $expected',
  );
}

final class NeverExpectation {
  NeverExpectation(this.callback);

  final Function() callback;

  void toThrow() {
    try {
      callback();
    } on Object catch (error) {
      throw FixtureError('Expected function not to throw: $error');
    }
  }
}
