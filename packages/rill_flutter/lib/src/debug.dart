part of '../rill_flutter.dart';

void _installDebugSections() => debugActiveSection('pulses', _pulseSnapshot);

List<Map<String, Object?>> _pulseSnapshot() => [
  for (final source in _pulses)
    {
      ...?RillDebug.describe(source._state)?.toJson(),
      'periodMs': source.interval.inMicroseconds / 1000,
      'decorative': source.decorative,
      'running': source._timer != null,
      'readers': subscriberCount(source._state),
    },
];
