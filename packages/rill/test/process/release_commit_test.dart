@Tags(['process'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('reentrant_write_in_release_returns_false', () async {
    final run = await Process.run(Platform.resolvedExecutable, [
      '--no-enable-asserts',
      'test/process/fixtures/release_commit.dart',
    ]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final result =
        jsonDecode((run.stdout as String).trim()) as Map<String, Object?>;
    expect(result, {
      'reentrant': false,
      'target': 2,
      'other': 0,
      'kept': true,
      'broken': false,
      'a': 0,
      'b': 0,
    });
  });
}
