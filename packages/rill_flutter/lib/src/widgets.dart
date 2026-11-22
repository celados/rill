part of '../rill_flutter.dart';

abstract class ReactiveWidget extends StatelessWidget {
  const ReactiveWidget({super.key});

  @override
  StatelessElement createElement() => _ReactiveStatelessElement(this);
}

abstract class ReactiveStatefulWidget extends StatefulWidget {
  const ReactiveStatefulWidget({super.key});

  @override
  StatefulElement createElement() => _ReactiveStatefulElement(this);
}

class Reactive extends ReactiveWidget {
  const Reactive({super.key, required this.builder});
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => builder(context);
}

class _ReactiveStatelessElement extends StatelessElement with _ReactiveElement {
  _ReactiveStatelessElement(ReactiveWidget super.widget);
}

class _ReactiveStatefulElement extends StatefulElement with _ReactiveElement {
  _ReactiveStatefulElement(ReactiveStatefulWidget super.widget);
}

/// A reactive Element only tracks: its build is the reader. It owns no
/// Scope; components that own effects use [ReactiveState].
mixin _ReactiveElement on ComponentElement implements _VisibilityHost {
  _Observer? _observer;
  bool _active = false;

  @override
  Element? get visibilityElement => _active ? this : null;

  @override
  void mount(Element? parent, Object? newSlot) {
    _active = true;
    _installGuards(parent?.owner);
    super.mount(parent, newSlot);
  }

  /// A dependency changed since the last build. Element.didChangeDependencies
  /// runs inside InheritedElement.notifyClients, which iterates the
  /// dependents: asking another host for motion there would register a
  /// dependency mid-iteration. The host reconciles in
  /// performRebuild instead, in the same frame.
  bool _dependenciesChanged = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dependenciesChanged = true;
  }

  @override
  void performRebuild() {
    if (_dependenciesChanged) {
      _dependenciesChanged = false;
      // A decorative time source asked this host for motion: let it ask
      // again.
      final observer = _observer;
      if (observer != null && observer.motionQueried) observer.hostChanged();
    }
    super.performRebuild();
  }

  @override
  void activate() {
    _active = true;
    super.activate();
    _installGuards(owner);
    // deactivate released the observer. A StatelessElement is not marked
    // dirty on activate unless it had dependencies, and a reader no longer
    // has any of its own.
    markNeedsBuild();
  }

  @override
  void deactivate() {
    _active = false;
    _disposeObserver();
    super.deactivate();
  }

  void _disposeObserver() {
    final observer = _observer;
    _observer = null;
    observer?.dispose();
  }

  @override
  void unmount() {
    _disposeObserver();
    super.unmount();
  }

  @override
  Widget build() {
    final observer = _observer ??= _Observer(
      () {
        if (mounted && _active) markNeedsBuild();
      },
      reader: this,
      host: this,
      frameBound: true,
    );
    // Async state is a value the builder switches on. A
    // throwing read follows Flutter's usual path to ErrorWidget.
    return observer.read(super.build);
  }
}

class EventListener<T> extends StatefulWidget {
  const EventListener({
    super.key,
    required this.events,
    required this.onEvent,
    required this.child,
  });
  final Events<T> events;
  final void Function(BuildContext, T) onEvent;
  final Widget child;

  @override
  State<EventListener<T>> createState() => _EventListenerState<T>();
}

class _EventListenerState<T> extends State<EventListener<T>> {
  VoidCallback? _stop;

  /// Events handed over while subscribing (held by `Events(hold: true)`).
  /// Subscribing happens during build, so they are delivered after the frame,
  /// in order, ahead of anything emitted later: the queue stays until it is
  /// empty, and what arrives while it drains joins its end.
  ListQueue<T>? _pending;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final pending = _pending = ListQueue<T>();
    _stop = widget.events.listen(_receive);
    if (pending.isEmpty) {
      _pending = null;
      return;
    }
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!identical(_pending, pending)) return;
        try {
          while (mounted && pending.isNotEmpty) {
            _deliver(pending.removeFirst());
          }
        } finally {
          if (identical(_pending, pending)) _pending = null;
        }
      })
      ..ensureVisualUpdate();
  }

  /// One event to [EventListener.onEvent]. A callback that throws is
  /// reported as a Flutter error and does not keep the next event back.
  void _deliver(T event) {
    try {
      widget.onEvent(context, event);
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'rill_flutter',
          context: ErrorDescription(
            'while delivering a held event to EventListener',
          ),
        ),
      );
    }
  }

  void _receive(T event) {
    if (_pending case final pending?) {
      pending.add(event);
    } else {
      widget.onEvent(context, event);
    }
  }

  @override
  void didUpdateWidget(EventListener<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.events, widget.events)) {
      _stop?.call();
      _listen();
    }
  }

  @override
  void deactivate() {
    _stop?.call();
    _stop = null;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _listen();
  }

  @override
  void dispose() {
    _stop?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
