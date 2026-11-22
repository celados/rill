/// Values fed from a wire format (JSON) without a usable `==`: decode only
/// when the wire shape changed, and only while staging a commit.
///
/// Built from the public API alone: the core has no support for
/// it. It imports nothing from rill but `package:rill/rill.dart`, which a
/// test in the gate asserts.
library;

import 'dart:typed_data';

import 'package:rill/rill.dart';

final _forgotten = Object();

/// A value decoded from wire data. [stage] decodes a payload only when it
/// differs from the last one installed ([equals], deep equality by default)
/// and stages the value together with its ledger, the wire it came from, in
/// the same commit: when the commit fails or its part is dropped, neither
/// installs, so the ledger never records a wire whose value was dropped.
///
/// Not a [Signal]: expose [readable] and write only through a commit.
final class Wire<T> {
  Wire(
    T initial,
    T Function(Object? wire) decode, {
    Equals<Object?> equals = Equality.deep,
    String? name,
  }) : _decode = decode,
       _equals = equals,
       _value = signal(initial, name: name),
       // An internal node: named after the wire so debug graphs show whose
       // ledger it is.
       _ledger = signal<Object?>(
         _forgotten,
         equals: Equality.identity,
         name: name == null ? 'wire.ledger' : '$name.ledger',
       );

  final T Function(Object?) _decode;
  final Equals<Object?> _equals;
  final Signal<T> _value;
  final Signal<Object?> _ledger;

  Readable<T> get readable => _value;

  /// Stages the value decoded from [wire], unless [wire] equals the last
  /// installed one. A throwing decoder throws here, while staging: nothing
  /// installs and the next stage decodes again.
  ///
  /// The comparison is against the ledger as last installed, not against
  /// what this commit has staged so far: within one commit, stage a Wire
  /// once, and do not mix [set] and [stage] on it (a [stage] after a [set]
  /// that matches the installed ledger stages nothing, and the [set] wins).
  void stage(Tx tx, Object? wire) {
    final last = _ledger.peek();
    if (!identical(last, _forgotten) && _equals(last, wire)) return;
    final value = _decode(wire);
    tx.set(_value, value);
    tx.set(_ledger, _snapshot(wire));
  }

  /// Stages [value] directly and forgets the ledger: the next [stage]
  /// decodes whatever arrives.
  void set(Tx tx, T value) {
    tx.set(_value, value);
    tx.set(_ledger, _forgotten);
  }
}

/// An unmodifiable deep copy, so a caller mutating its JSON later does not
/// change the ledger. A comparator sees the types the wire came in: a JSON
/// object stays a `Map<String, dynamic>` and a JSON array a `List<dynamic>`,
/// so a typed field reader shared with the decoder still applies; typed data is not turned into a `List<Object?>`.
Object? _snapshot(Object? wire) => switch (wire) {
  TypedDataList() => wire.sublist(0),
  TypedData() => wire,
  Map<String, dynamic>() => Map<String, dynamic>.unmodifiable(
    wire.map((key, value) => MapEntry(key, _snapshot(value))),
  ),
  Map() => Map<Object?, Object?>.unmodifiable(
    wire.map((key, value) => MapEntry(key, _snapshot(value))),
  ),
  List() => List<dynamic>.unmodifiable(wire.map(_snapshot)),
  _ => wire,
};
