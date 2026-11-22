import 'dart:convert';
import 'dart:io';

import 'package:rill_conformance/adapter.dart';
import 'package:rill_conformance/suite.dart';

Future<void> main(List<String> filters) async {
  final records = <Map<String, Object?>>[];
  for (final name in adapterNames) {
    for (final fixture in fixtures) {
      if (filters.isNotEmpty && !filters.contains('${fixture.id}')) continue;
      final result = await observe(name, fixture);
      records.add({
        'adapter': name,
        'id': fixture.id,
        'title': fixture.title,
        'status': result.outcome.name,
        'detail': result.detail,
      });
    }
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(records));
}
