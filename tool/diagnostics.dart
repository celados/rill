// Checks that every RILL_* code in the packages has a diagnostics page, that
// every page belongs to a code still raised, and that each page is complete.
import 'dart:io';

const docs = 'docs/diagnostics';
const sections = ['## 原因', '## 触发', '## 修法', '## 相关规则'];
final codePattern = RegExp(r'\bRILL_[A-Z]+(?:_[A-Z]+)*\b');

void main() {
  final used = <String, Set<String>>{};
  for (final package in Directory(
    'packages',
  ).listSync().whereType<Directory>()) {
    final lib = Directory('${package.path}/lib');
    if (!lib.existsSync()) continue;
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in codePattern.allMatches(file.readAsStringSync())) {
        (used[match[0]!] ??= {}).add(file.path);
      }
    }
  }

  final problems = <String>[];
  final pages = {
    for (final file in Directory(docs).listSync().whereType<File>())
      if (RegExp(r'/RILL_[A-Z_]+\.md$').hasMatch(file.path))
        file.uri.pathSegments.last.replaceAll('.md', ''): file,
  };
  for (final code in used.keys.toList()..sort()) {
    if (!pages.containsKey(code)) {
      problems.add(
        '$code has no page ($docs/$code.md); used in ${used[code]!.join(', ')}',
      );
    }
  }
  final index = File('$docs/README.md').readAsStringSync();
  for (final MapEntry(key: code, value: file) in pages.entries) {
    if (!used.containsKey(code)) {
      problems.add('${file.path} documents $code, which no package raises');
    }
    final text = file.readAsStringSync();
    final front = RegExp(r'^---\n([\s\S]*?)\n---\n').firstMatch(text)?[1];
    if (front == null) {
      problems.add('${file.path} has no frontmatter');
      continue;
    }
    for (final key in [
      'type',
      'title',
      'description',
      'when',
      'severity',
      'rules',
    ]) {
      if (!RegExp('^$key:', multiLine: true).hasMatch(front)) {
        problems.add('${file.path} frontmatter lacks $key');
      }
    }
    if (!RegExp('^code: $code\$', multiLine: true).hasMatch(front)) {
      problems.add('${file.path} frontmatter code is not $code');
    }
    for (final section in sections) {
      if (!text.contains('\n$section\n'))
        problems.add('${file.path} lacks $section');
    }
    if (!index.contains('($code.md)')) {
      problems.add('$docs/README.md does not link $code');
    }
  }

  if (problems.isEmpty) {
    stdout.writeln('${pages.length} diagnostic codes documented.');
    return;
  }
  stderr.writeln(problems.join('\n'));
  exitCode = 1;
}
