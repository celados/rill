part of '../rill_flutter.dart';

extension ReadableListenable<T> on Readable<T> {
  /// A new adapter on every call: create it once, where its listeners live,
  /// not in `build`. Native listeners count as visible. Use a
  /// [ReactiveWidget] or [ReactivePaint] when a Pulse must follow subtree
  /// visibility.
  ValueListenable<T> toListenable() => _ReadableListenable(this);
}

class _ReadableListenable<T> extends ChangeNotifier
    implements ValueListenable<T> {
  _ReadableListenable(this.source);
  final Readable<T> source;
  _Observer? _observer;

  @override
  T get value => source.peek();

  void _collect() {
    // Failed reads still link to their source. The consumer's value getter
    // handles presentation or throws the original error when it next runs.
    _observer!.read(() {
      try {
        source.value;
      } on Object {
        // Keep listening for recovery.
      }
    });
  }

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) {
      _observer = _Observer(() {
        _collect();
        try {
          notifyListeners();
        } finally {
          _releaseIfIdle();
        }
      }, frameBound: true);
      _collect();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _releaseIfIdle();
  }

  void _releaseIfIdle() {
    if (hasListeners) return;
    final observer = _observer;
    _observer = null;
    observer?.dispose();
  }

  @override
  void dispose() {
    _observer?.dispose();
    _observer = null;
    super.dispose();
  }
}

extension ListenableReadable<T> on ValueListenable<T> {
  /// A new bridge on every call: create it once, where its readers live,
  /// not in `build`.
  Readable<T> toReadable() => _fromListenable(this);
}

Readable<T> _fromListenable<T>(ValueListenable<T> listenable) {
  late final Signal<T> state;
  // Flutter notifies from build, didUpdateWidget and layout as readily as
  // from events, and the bridge cannot tell which without sniffing the
  // phase: every mirrored change is a frame write (R3b).
  void synchronize() =>
      _frameWrite(() => writeBindingSignal(state, listenable.value));

  state = bindingSignal(
    listenable.value,
    sample: () => listenable.value,
    watched: () {
      listenable.addListener(synchronize);
      synchronize();
    },
    unwatched: () => listenable.removeListener(synchronize),
  );
  return state;
}

class ReactiveLayoutBuilder extends StatelessWidget {
  const ReactiveLayoutBuilder({super.key, required this.builder});
  final LayoutWidgetBuilder builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) =>
        Reactive(builder: (context) => builder(context, constraints)),
  );
}

class ReactiveAnimatedBuilder extends StatelessWidget {
  const ReactiveAnimatedBuilder({
    super.key,
    required this.animation,
    required this.builder,
    this.child,
  });

  final Listenable animation;
  final TransitionBuilder builder;
  final Widget? child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (_, child) =>
        Reactive(builder: (context) => builder(context, child)),
  );
}
