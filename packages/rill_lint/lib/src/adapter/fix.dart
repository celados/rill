import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/edit/dart/dart_fix_kind_priority.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';

import 'semantics.dart';

class WrapInReactive extends ResolvedCorrectionProducer {
  static const _kind = FixKind(
    'rill_lint.fix.wrapInReactive',
    DartFixKindPriority.standard,
    'Wrap the widget expression in Reactive',
  );

  WrapInReactive({required super.context});

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => _kind;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    final closure = untrackedBuilder(node);
    if (closure == null || closure.body.isAsynchronous) return;

    final body = closure.body;
    final expression = switch (body) {
      ExpressionFunctionBody(:final expression) => expression,
      _ => node.thisOrAncestorOfType<ReturnStatement>()?.expression,
    };
    if (expression == null ||
        expression.offset > node.offset ||
        expression.end < node.end) {
      return;
    }

    const library = 'package:rill_flutter/rill_flutter.dart';
    final resolved = await unitResult.session.getLibraryByUri(library);
    if (resolved is! LibraryElementResult ||
        resolved.element.exportNamespace.get2('Reactive') == null) {
      return;
    }

    // A fresh prefix also works with local names and existing show/hide imports.
    final source = unitResult.content;
    var prefix = 'rillWidgets';
    while (RegExp('\\b$prefix\\b').hasMatch(source)) {
      prefix += '_';
    }
    await builder.addDartFileEdit(file, (edit) {
      edit.importLibrary(
        Uri.parse(library),
        prefix: prefix,
        showName: 'Reactive',
        useShow: true,
      );
      edit.addSimpleInsertion(
        expression.offset,
        '$prefix.Reactive(builder: (_) => ',
      );
      edit.addSimpleInsertion(expression.end, ')');
    });
  }
}
