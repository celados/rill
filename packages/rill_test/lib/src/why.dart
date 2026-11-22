part of '../rill_test.dart';

/// The effect runs, observer rebuilds and query re-asks recorded while
/// [during] runs, oldest first. Needs asserts, like every rill diagnostic.
Future<List<RillWhy>> recordWhy(FutureOr<void> Function() during) async {
  if (!RillDebug.enabled) {
    throw StateError('recordWhy needs asserts; rill records nothing without.');
  }
  final start = RillDebug.lastSeq;
  await during();
  return [
    for (final record in RillDebug.why())
      if (record.seq > start) record,
  ];
}

/// Matches a [RillWhy] or [RillCause] whose causes reach a write of [source]
/// through the computeds in [via], listed in data-flow order:
/// `causedBy(count, via: [doubled, label])` is count → doubled → label.
Matcher causedBy(
  Readable<Object?> source, {
  List<Readable<Object?>> via = const [],
}) => _CausedBy(source, via);

final class _CausedBy extends Matcher {
  _CausedBy(this.source, this.via);
  final Readable<Object?> source;
  final List<Readable<Object?>> via;

  int _id(Readable<Object?> node) => RillDebug.describe(node)!.id;

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) {
    final roots = switch (item) {
      RillWhy(:final causes) => causes,
      RillCause(:final causes) => causes,
      _ => null,
    };
    if (roots == null) return false;
    final path = [for (final node in via.reversed) _id(node), _id(source)];
    bool walk(List<RillCause> causes, int depth) {
      for (final cause in causes) {
        if (cause.node.id != path[depth]) continue;
        if (depth == path.length - 1) {
          if (cause.change == 'write') return true;
        } else if (walk(cause.causes, depth + 1)) {
          return true;
        }
      }
      return false;
    }

    return walk(roots, 0);
  }

  @override
  Description describe(Description description) {
    final chain = [
      for (final node in [source, ...via]) RillDebug.describe(node)!.label,
    ];
    return description.add('caused by a write of ${chain.join(' → ')}');
  }

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<Object?, Object?> matchState,
    bool verbose,
  ) => mismatchDescription.add('has the chain\n$item');
}
