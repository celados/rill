part of '../rill_flutter.dart';

/// Reactive resources owned by a [State]'s lifetime.
///
/// [watch] is the effect to create from `initState`, `didUpdateWidget` and
/// the other lifecycle methods: those run while the framework builds, and a
/// plain `effect` applies synchronously, inside that build. [watch] runs its
/// compute at once, so tracking starts at mount, and holds its first apply
/// until after the frame (Solid's "effects run after render"); later applies
/// run synchronously, as a plain effect's do, except those a frame write
/// (a bridged notifier set in build, a Pulse calibration) wakes: those wait
/// for the post-frame callback too. The effects, Slots and
/// resources registered with [scope] stop with the State; derived values
/// (computed, linger, Pulse) belong to no one and need no registration.
///
/// It is not named `effect`: Dart resolves a bare name to an imported
/// top-level function before an inherited member, so a mixin `effect` would
/// silently lose to rill's inside the State.
///
/// ```dart
/// class _RegionState extends State<Region> with ReactiveState {
///   @override
///   void initState() {
///     super.initState();
///     watch(() => widget.toasts.value, (toasts, previous, onCleanup) {
///       _entries.value = _reconcile(toasts);   // after the first frame
///     });
///   }
/// }
/// ```
///
/// To follow a widget input that the parent can swap, stop the watch and
/// create it again in `didUpdateWidget`; the new one starts over, with its
/// first apply after the frame and `previous == null`.
mixin ReactiveState<W extends StatefulWidget> on State<W> {
  Scope? _lifetime;
  bool _ending = false;

  /// The Scope this State owns: created on first use, disposed when the
  /// State is. It is a root: the Element tree already orders component
  /// lifetimes, so it is not parented to any other Scope.
  ///
  /// Its identity is fixed for the State's life, teardown included: a
  /// cleanup that asks for it gets the Scope being disposed, so a new
  /// registration fails with `RILL_DISPOSED` instead of founding a second
  /// root that outlives the State. Asked first after [dispose] began, it is
  /// a Scope born disposed.
  @protected
  Scope get scope => _lifetime ??= _ending
      ? (Scope(name: '${widget.runtimeType}')..dispose())
      : Scope(name: '${widget.runtimeType}');

  /// An effect owned by [scope]: [compute] runs now, the first [apply]
  /// after the frame (with `previous == null`), later ones synchronously.
  /// Until the first apply, recomputes only replace the value it will see.
  /// The returned function stops it early; [dispose] stops it anyway.
  @protected
  void Function() watch<T>(
    T Function() compute,
    void Function(T value, T? previous, OnCleanup onCleanup) apply, {
    String? name,
  }) {
    _installGuards(context.owner);
    return deferredEffect(
      compute,
      apply,
      schedule: _afterFrame,
      owner: scope,
      name: name,
    );
  }

  /// Widget configuration as a source the graph can follow: [initial] now, then whatever
  /// [WidgetInput.sync] is handed in `didUpdateWidget` /
  /// `didChangeDependencies`. Create one per configuration, once: in
  /// `initState` or a `late final` field, not in `build`. [equals] keeps a
  /// freshly built but equal configuration object from propagating.
  ///
  /// ```dart
  /// late final _items = input(widget.items, equals: Equality.deep);
  /// late final _controller = ListboxController(items: _items.readable);
  ///
  /// @override
  /// void didUpdateWidget(Listbox old) {
  ///   super.didUpdateWidget(old);
  ///   _items.sync(widget.items);   // readers below update in this frame
  /// }
  /// ```
  @protected
  WidgetInput<T> input<T>(T initial, {Equals<T>? equals, String? name}) {
    _installGuards(context.owner);
    return WidgetInput._(this, signal(initial, equals: equals, name: name));
  }

  /// Debug: open from the `super` call of [didUpdateWidget] /
  /// [didChangeDependencies] until the frame ends.
  bool _inputWindow = false;

  bool _openInputWindow() {
    if (_inputWindow) return true;
    _inputWindow = true;
    _binding()?.addPostFrameCallback(
      (_) => _inputWindow = false,
      debugLabel: 'rill.inputWindow',
    );
    return true;
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(_openInputWindow());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    assert(_openInputWindow());
  }

  @override
  void dispose() {
    _ending = true;
    _lifetime?.dispose();
    super.dispose();
  }
}

/// R3b: a managed binding write made on behalf of a frame. The effects it
/// wakes apply in the post-frame callback, not inside build or layout.
void _frameWrite(void Function() write) =>
    frameBindingWrite(_afterFrame, write);

void _afterFrame(void Function() release) {
  final binding = _binding();
  if (binding == null) {
    // No binding, no frame to wait for: release once this write settles.
    scheduleMicrotask(release);
    return;
  }
  binding
    ..addPostFrameCallback((_) => release(), debugLabel: 'rill.effect')
    ..ensureVisualUpdate();
}

/// Installs rill_flutter's debug read and write guards for [owner]. A
/// reactive Element installs them when it mounts and a ReactiveState when it
/// first watches; a test that mounts neither (rill_test's mountApp) calls
/// this first. No-op in release.
void debugInstallRillGuards(BuildOwner owner) => _installGuards(owner);
