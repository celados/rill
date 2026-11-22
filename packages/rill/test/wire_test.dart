// package:rill/wire.dart: wire dedupe built
// from the public API alone.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rill/debug.dart';
import 'package:rill/rill.dart';
import 'package:rill/wire.dart';
import 'package:test/test.dart';

Wire<int> counted(List<Object?> decoded, {Equals<Object?>? equals}) {
  int decode(Object? wire) {
    decoded.add(wire);
    final value = (wire as Map)['v'];
    if (value is! int) throw const FormatException('v');
    return value;
  }

  return equals == null
      ? Wire<int>(0, decode, name: 'status')
      : Wire<int>(0, decode, equals: equals, name: 'status');
}

void main() {
  test('wire_dedupes_equal_wire', () {
    final decoded = <Object?>[];
    final wire = counted(decoded);
    final revisions = <int>[];
    addTearDown(
      effect(() => wire.readable.value, (v, _, _) => revisions.add(v)),
    );
    transact((p) => wire.stage(p, {'v': 1}));
    transact((p) => wire.stage(p, {'v': 1}));
    expect(decoded, hasLength(1));
    expect(revisions, [0, 1]);
  });

  test('wire_decode_failure_installs_nothing_and_decodes_again', () {
    final decoded = <Object?>[];
    final wire = counted(decoded);
    final other = signal(0);
    for (var i = 0; i < 2; i++) {
      expect(
        () => transact((p) {
          p.set(other, 9);
          wire.stage(p, {'v': 'x'});
        }),
        throwsFormatException,
      );
    }
    expect((other.peek(), wire.readable.peek()), (0, 0));
    expect(decoded, hasLength(2), reason: 'the ledger did not record it');
  });

  test('wire_ledger_rolls_back_with_part', () {
    final decoded = <Object?>[];
    final wire = counted(decoded);
    final source = signal(0);
    final asked = Unchanged(source);
    source.value = 1;
    final committed = transact((p) {
      p.part(() {
        p.require(asked);
        wire.stage(p, {'v': 5});
      });
    });
    expect((committed, wire.readable.peek()), (true, 0));
    transact((p) => wire.stage(p, {'v': 5}));
    expect(decoded, hasLength(2), reason: 'the dropped part kept no ledger');
    expect(wire.readable.peek(), 5);
  });

  test('wire_custom_equals_projection', () {
    final decoded = <Object?>[];
    final wire = counted(
      decoded,
      equals: (a, b) => (a as Map?)?['v'] == (b as Map?)?['v'],
    );
    transact((p) => wire.stage(p, {'v': 1, 'at': 1}));
    transact((p) => wire.stage(p, {'v': 1, 'at': 2}));
    expect(decoded, hasLength(1));
  });

  test('wire_set_forgets_ledger', () {
    final decoded = <Object?>[];
    final wire = counted(decoded);
    transact((p) => wire.stage(p, {'v': 1}));
    transact((p) => wire.set(p, 1));
    transact((p) => wire.stage(p, {'v': 1}));
    expect(decoded, hasLength(2));
  });

  test('wire_ledger_is_an_unmodifiable_snapshot', () {
    final decoded = <Object?>[];
    final wire = counted(decoded);
    final json = <String, Object?>{'v': 2};
    transact((p) => wire.stage(p, json));
    json['v'] = 3;
    transact((p) => wire.stage(p, json));
    expect(wire.readable.peek(), 3);
    expect(decoded, hasLength(2));
  });

  test('unchanged_on_wire_ignores_deduped_json', () {
    final wire = counted([]);
    transact((p) => wire.stage(p, {'v': 1}));
    final asked = Unchanged(wire.readable);
    transact((p) => wire.stage(p, {'v': 1}));
    expect(asked.holds, isTrue);
    transact((p) => wire.stage(p, {'v': 2}));
    expect(asked.holds, isFalse);
  });

  test('wire_ledger_is_named_after_the_wire', () {
    final named = Wire<int>(0, (w) => w! as int, name: 'tick');
    final unnamed = Wire<int>(0, (w) => w! as int);
    // Keep both alive while the weak node registry is read.
    addTearDown(() => [named, unnamed]);
    final names = [
      for (final node in RillDebug.graph()['nodes']! as List)
        (node as Map)['name'],
    ];
    expect(names, containsAll(['tick', 'tick.ledger', 'wire.ledger']));
  });

  test('wire_keeps_typed_data_payloads', () {
    final seen = <Object?>[];
    final wire = Wire<int>(
      0,
      (w) => (w! as Uint8List).length,
      equals: (last, next) {
        seen.add(last);
        return last is Uint8List &&
            next is Uint8List &&
            last.length == next.length;
      },
    );
    final bytes = Uint8List.fromList([1, 2, 3]);
    transact((p) => wire.stage(p, bytes));
    bytes[0] = 9;
    transact((p) => wire.stage(p, bytes));
    expect(seen.single, isA<Uint8List>());
    expect((seen.single! as Uint8List)[0], 1, reason: 'the ledger is a copy');
  });

  test('typed_field_reader_shared_by_decoder_and_comparator', () {
    // A JSON client: the decoder and the comparator read the same field
    // through one typed reader, and each response lands in its own commit.
    String revision(Object? payload) =>
        (payload as Map<String, dynamic>)['revision'] as String;
    final wire = Wire<String>(
      '',
      revision,
      equals: (previous, next) => revision(previous) == revision(next),
    );
    for (final rev in ['v1', 'v1', 'v2']) {
      final json = jsonDecode('{"revision":"$rev","items":[{"id":1}]}');
      expect(transact((tx) => wire.stage(tx, json)), isTrue);
      expect(wire.readable.peek(), rev);
    }
  });

  test('ledger_keeps_json_types_and_stays_unmodifiable', () {
    late Object? seen;
    final wire = Wire<int>(
      0,
      (_) => 1,
      equals: (previous, next) {
        seen = previous;
        return false;
      },
    );
    final json = jsonDecode('{"a":{"b":[1,{"c":2}]}}');
    transact((tx) => wire.stage(tx, json));
    transact((tx) => wire.stage(tx, json));
    final ledger = seen! as Map<String, dynamic>;
    final inner = ledger['a'] as Map<String, dynamic>;
    final list = inner['b'] as List<dynamic>;
    expect(list[1], isA<Map<String, dynamic>>());
    expect(() => ledger['x'] = 1, throwsUnsupportedError);
    expect(() => inner['x'] = 1, throwsUnsupportedError);
    expect(() => list.add(1), throwsUnsupportedError);
    expect(
      () => (list[1] as Map<String, dynamic>)['x'] = 1,
      throwsUnsupportedError,
    );
  });

  test('wire_library_imports_only_public_api', () {
    final source = File('lib/wire.dart').readAsStringSync();
    final imports = RegExp(
      r'''^(?:import|export)\s+'([^']+)';''',
      multiLine: true,
    ).allMatches(source).map((m) => m[1]!).toList();
    expect(imports, isNotEmpty);
    for (final uri in imports) {
      expect(
        uri.startsWith('dart:') || uri == 'package:rill/rill.dart',
        isTrue,
        reason: 'wire.dart imports $uri',
      );
    }
    expect(
      File('lib/rill.dart').readAsStringSync(),
      isNot(contains('wire')),
      reason: 'Wire is not exported from the core',
    );
  });
}
