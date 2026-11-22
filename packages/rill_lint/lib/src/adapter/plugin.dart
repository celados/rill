import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'fix.dart';
import 'rules.dart';

class RillLintPlugin extends Plugin {
  @override
  String get name => 'rill_lint';

  @override
  void register(PluginRegistry registry) {
    for (final kind in RillLint.values) {
      registry.registerLintRule(RillRule(kind));
    }
    registry.registerFixForRule(
      RillLint.untrackedRead.code,
      WrapInReactive.new,
    );
  }
}
