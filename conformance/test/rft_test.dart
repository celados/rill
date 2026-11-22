import 'dart:io';

import 'package:rill_conformance/adapter.dart';
import 'package:rill_conformance/suite.dart';
import 'package:test/test.dart';

typedef Entry = ({String observation, String classification, String reason});

Map<int, Map<String, Entry>> _registry() {
  final rows = <int, Map<String, Entry>>{};
  for (final line in File('../docs/conformance.md').readAsLinesSync()) {
    if (!line.startsWith('| #')) continue;
    final cells = line
        .split('|')
        .skip(1)
        .takeWhile((cell) => cell.isNotEmpty)
        .map((cell) => cell.trim())
        .toList();
    if (cells.length != 10) throw FormatException('Expected ten columns', line);
    final id = int.parse(cells.first.substring(1));
    if (rows.containsKey(id)) throw FormatException('Duplicate rft #$id');
    rows[id] = {
      'js': (observation: cells[2], classification: '', reason: ''),
      for (final (index, adapter) in adapterNames.indexed)
        adapter: (
          observation: cells[3 + index * 2],
          classification: cells[4 + index * 2],
          reason: adapter == 'rill' ? cells[9] : '',
        ),
    };
  }
  return rows;
}

void main() {
  final registry = _registry();

  test(
    'registration covers exactly 161 correctness fixtures and 29 probes',
    () {
      expect(
        fixtures.map((fixture) => fixture.id),
        unorderedEquals(registry.keys),
      );
      expect(
        fixtures.where((fixture) => fixture.variants.isEmpty),
        hasLength(161),
      );
      expect(
        fixtures.where((fixture) => fixture.variants.isNotEmpty),
        hasLength(29),
      );
      final mandatory = fixtures.where(
        (fixture) =>
            fixture.variants.isEmpty &&
            registry[fixture.id]!['rill']!.classification == '原样符合',
      );
      expect(mandatory, hasLength(136));
      for (final fixture in fixtures) {
        final entries = registry[fixture.id]!;
        for (final MapEntry(key: engine, value: entry) in entries.entries) {
          if (engine == 'rill' && entry.classification != '原样符合') {
            expect(entry.reason, isNotEmpty, reason: '#${fixture.id}');
            if (entry.classification == '改写后符合') continue;
          }
          final observation = entry.observation;
          final probe = fixture.variants.isNotEmpty;
          final classification = entry.classification;
          if (observation.startsWith('FAIL: ')) {
            expect(classification, '有意偏离', reason: '#${fixture.id}');
          } else if (observation.startsWith('UNSUPPORTED: ')) {
            expect(classification, '不支持', reason: '#${fixture.id}');
          } else {
            if (classification.isNotEmpty) {
              final expected = observation == entries['js']!.observation
                  ? '原样符合'
                  : '有意偏离';
              expect(classification, expected, reason: '#${fixture.id}');
            }
            if (probe) {
              expect(
                observation,
                startsWith('VAR: '),
                reason: '#${fixture.id}',
              );
              expect(
                fixture.variants,
                contains(observation.substring(5)),
                reason: '#${fixture.id}',
              );
            } else {
              expect(observation, 'PASS', reason: '#${fixture.id}');
            }
          }
        }
      }
    },
  );

  for (final adapter in adapterNames) {
    group(adapter, () {
      for (final fixture in fixtures) {
        final row = registry[fixture.id]?[adapter];
        final expected = row?.observation;
        final skip =
            adapter != 'rill' &&
                expected != null &&
                (expected.startsWith('FAIL: ') ||
                    expected.startsWith('UNSUPPORTED: '))
            ? expected
            : null;
        test('#${fixture.id} ${fixture.title}', () async {
          expect(row, isNotNull, reason: 'Missing from the registration table');
          final result = await observe(adapter, fixture);
          final actual = switch (result.outcome) {
            Outcome.pass => 'PASS',
            Outcome.variant => 'VAR: ${result.detail}',
            Outcome.fail => 'FAIL: ${result.detail}',
          };
          if (adapter == 'rill' && expected!.startsWith('FAIL: ')) {
            expect(actual, startsWith(expected));
          } else {
            expect(actual, expected);
          }
        }, skip: skip);
      }
    });
  }
}
