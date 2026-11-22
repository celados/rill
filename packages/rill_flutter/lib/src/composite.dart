part of '../rill_flutter.dart';

/// Composite-level reads: a render object that reads a
/// [Readable] and applies it as a layer property. Subscribes on attach,
/// unsubscribes on detach, swaps when the Readable is replaced and syncs to
/// the current value when it is attached again.
///
/// The widget's Element is the reader's host: visibility (TickerMode, reduced motion) and the
/// WidgetInput subtree check are asked of it. A render object made without
/// the widget has none and counts as a native listener.
mixin _CompositeReader on RenderObject {
  _Observer? _compositeObserver;
  _VisibilityHost? _host;

  /// Reads the source with tracking and applies it.
  void _readSource();

  void _sync() {
    final observer = _compositeObserver;
    if (observer == null) return;
    observer.read(_readSource);
  }

  void _subscribe() {
    _compositeObserver?.dispose();
    _compositeObserver = _Observer(
      _sync,
      reader: this,
      host: _host,
      frameBound: true,
    );
    _sync();
  }

  void _sourceChanged() {
    if (attached) _subscribe();
  }

  /// The host's dependencies changed: a decorative source that asked it for
  /// motion asks again.
  void _hostChanged() {
    final observer = _compositeObserver;
    if (observer != null && observer.motionQueried) observer.hostChanged();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _subscribe();
  }

  @override
  void detach() {
    _compositeObserver?.dispose();
    _compositeObserver = null;
    super.detach();
  }
}

/// The Element of [ReactiveOpacity] and [ReactiveTransform]: the host its
/// render object's reader asks.
class _CompositeElement extends SingleChildRenderObjectElement
    implements _VisibilityHost {
  _CompositeElement(super.widget);

  bool _active = false;

  /// As in a reactive Element: reconciled in [performRebuild], not inside
  /// InheritedElement.notifyClients.
  bool _dependenciesChanged = false;

  @override
  Element? get visibilityElement => _active ? this : null;

  @override
  void mount(Element? parent, Object? newSlot) {
    _active = true;
    _installGuards(parent?.owner);
    super.mount(parent, newSlot);
  }

  @override
  void activate() {
    _active = true;
    super.activate();
    _installGuards(owner);
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dependenciesChanged = true;
  }

  void _reconcile() {
    if (!_dependenciesChanged) return;
    _dependenciesChanged = false;
    (renderObject as _CompositeReader)._hostChanged();
  }

  @override
  void performRebuild() {
    _reconcile();
    super.performRebuild();
  }

  /// RenderObjectElement.update rebuilds without [performRebuild]: a parent
  /// that rebuilds this widget in the frame its dependency changed would
  /// skip the reconcile.
  @override
  void update(SingleChildRenderObjectWidget newWidget) {
    super.update(newWidget);
    _reconcile();
  }
}

/// An [Opacity] whose value is a [Readable]: a change updates the opacity
/// layer and nothing below it builds, lays out or paints.
///
/// The render object is a [RenderOpacity], so crossing zero follows Flutter's
/// own order: compositing bits and, without [alwaysIncludeSemantics],
/// semantics update; at zero the child is neither painted nor in the
/// semantics tree.
class ReactiveOpacity extends SingleChildRenderObjectWidget {
  const ReactiveOpacity({
    super.key,
    required this.opacity,
    this.alwaysIncludeSemantics = false,
    super.child,
  });

  /// 0 to 1.
  final Readable<double> opacity;
  final bool alwaysIncludeSemantics;

  @override
  SingleChildRenderObjectElement createElement() => _CompositeElement(this);

  @override
  RenderReactiveOpacity createRenderObject(BuildContext context) =>
      RenderReactiveOpacity(
        opacity,
        alwaysIncludeSemantics: alwaysIncludeSemantics,
      ).._host = _hostOf(context);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderReactiveOpacity renderObject,
  ) {
    renderObject
      ..source = opacity
      ..alwaysIncludeSemantics = alwaysIncludeSemantics;
  }
}

/// The render object of [ReactiveOpacity].
class RenderReactiveOpacity extends RenderOpacity with _CompositeReader {
  RenderReactiveOpacity(
    Readable<double> source, {
    super.alwaysIncludeSemantics,
    super.child,
  }) : _source = source,
       super(opacity: source.peek().clamp(0.0, 1.0));

  Readable<double> _source;
  Readable<double> get source => _source;
  set source(Readable<double> value) {
    if (identical(value, _source)) return;
    _source = value;
    _sourceChanged();
  }

  @override
  void _readSource() => opacity = _source.value.clamp(0.0, 1.0);
}

/// A [Transform] whose matrix is a [Readable]: a change updates one
/// [TransformLayer] and nothing below it builds, lays out or paints.
///
/// It is a repaint boundary: the child paints once into its own layer and
/// every later frame only moves that layer. Hit tests and semantics geometry
/// follow the same matrix ([RenderTransform]'s rules).
///
/// [origin] and [alignment] place the matrix's origin as [Transform]'s do,
/// resolved against the size at paint, hit test and semantics time, so a
/// scale about the centre or an edge is right on the first frame. They are
/// plain configuration: changing one updates the render object, not the
/// subtree; a `Readable` origin is a non-goal.
class ReactiveTransform extends SingleChildRenderObjectWidget {
  const ReactiveTransform({
    super.key,
    required Readable<Matrix4> this.transform,
    this.origin,
    this.alignment,
    this.transformHitTests = true,
    super.child,
  }) : offset = null;

  /// A translation only: the cheapest source for a sheet or a drag. A
  /// translation has no origin, so, like [Transform.translate], it takes
  /// neither [origin] nor [alignment].
  const ReactiveTransform.translate({
    super.key,
    required Readable<Offset> this.offset,
    this.transformHitTests = true,
    super.child,
  }) : transform = null,
       origin = null,
       alignment = null;

  final Readable<Matrix4>? transform;
  final Readable<Offset>? offset;

  /// The origin of the matrix in the child's coordinates, added to
  /// [alignment]'s point ([Transform.origin]).
  final Offset? origin;

  /// The origin of the matrix as a point in the child's size: `center`
  /// scales about the middle, `topCenter` about the top edge. An
  /// [AlignmentDirectional] resolves with the ambient [Directionality]
  /// ([Transform.alignment]).
  final AlignmentGeometry? alignment;
  final bool transformHitTests;

  @override
  SingleChildRenderObjectElement createElement() => _CompositeElement(this);

  @override
  RenderReactiveTransform createRenderObject(BuildContext context) =>
      RenderReactiveTransform(
        transform: transform,
        offset: offset,
        origin: origin,
        alignment: alignment,
        textDirection: Directionality.maybeOf(context),
        transformHitTests: transformHitTests,
      ).._host = _hostOf(context);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderReactiveTransform renderObject,
  ) {
    renderObject
      ..setSource(transform: transform, offset: offset)
      ..origin = origin
      ..alignment = alignment
      ..textDirection = Directionality.maybeOf(context)
      ..transformHitTests = transformHitTests;
  }
}

/// The render object of [ReactiveTransform].
class RenderReactiveTransform extends RenderProxyBox with _CompositeReader {
  RenderReactiveTransform({
    Readable<Matrix4>? transform,
    Readable<Offset>? offset,
    Offset? origin,
    AlignmentGeometry? alignment,
    TextDirection? textDirection,
    this.transformHitTests = true,
    RenderBox? child,
  }) : assert((transform == null) != (offset == null)),
       _transformSource = transform,
       _offsetSource = offset,
       _origin = origin,
       _alignment = alignment,
       _textDirection = textDirection,
       super(child) {
    _matrix = _peekSource();
  }

  Readable<Matrix4>? _transformSource;
  Readable<Offset>? _offsetSource;
  late Matrix4 _matrix;
  bool transformHitTests;

  /// The matrix shown now: a copy. Changing it in place would bypass the
  /// layer and semantics updates. It is the source's matrix, before
  /// [origin] and [alignment].
  Matrix4 get matrix => _matrix.clone();

  Offset? _origin;
  Offset? get origin => _origin;
  set origin(Offset? value) {
    if (value == _origin) return;
    _origin = value;
    _placementChanged();
  }

  AlignmentGeometry? _alignment;
  AlignmentGeometry? get alignment => _alignment;
  set alignment(AlignmentGeometry? value) {
    if (value == _alignment) return;
    _alignment = value;
    _placementChanged();
  }

  /// Resolves an [AlignmentDirectional] [alignment].
  TextDirection? _textDirection;
  TextDirection? get textDirection => _textDirection;
  set textDirection(TextDirection? value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _placementChanged();
  }

  /// Same syncs as a matrix change. A new size reaches the layer through the
  /// repaint that layout already schedules.
  void _placementChanged() {
    markNeedsCompositedLayerUpdate();
    markNeedsSemanticsUpdate();
  }

  /// The matrix about [origin] plus [alignment]'s point in the current size:
  /// [RenderTransform]'s order. Used by the layer, hit tests and
  /// [applyPaintTransform] alike.
  Matrix4 get _effective {
    final alignment = _alignment?.resolve(_textDirection);
    final origin = _origin;
    if (origin == null && alignment == null) return _matrix;
    var pivot = origin ?? Offset.zero;
    if (alignment != null) pivot += alignment.alongSize(size);
    return Matrix4.translationValues(pivot.dx, pivot.dy, 0)
      ..multiply(_matrix)
      ..multiply(Matrix4.translationValues(-pivot.dx, -pivot.dy, 0));
  }

  void setSource({Readable<Matrix4>? transform, Readable<Offset>? offset}) {
    assert((transform == null) != (offset == null));
    if (identical(transform, _transformSource) &&
        identical(offset, _offsetSource)) {
      return;
    }
    _transformSource = transform;
    _offsetSource = offset;
    _sourceChanged();
  }

  Matrix4 _peekSource() {
    final offset = _offsetSource;
    if (offset != null) {
      final o = offset.peek();
      return Matrix4.translationValues(o.dx, o.dy, 0);
    }
    return _transformSource!.peek().clone();
  }

  @override
  void _readSource() {
    final offset = _offsetSource;
    final Matrix4 next;
    if (offset != null) {
      final o = offset.value;
      next = Matrix4.translationValues(o.dx, o.dy, 0);
    } else {
      next = _transformSource!.value.clone();
    }
    if (next == _matrix) return;
    _matrix = next;
    markNeedsCompositedLayerUpdate();
    markNeedsSemanticsUpdate();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  OffsetLayer updateCompositedLayer({
    required covariant TransformLayer? oldLayer,
  }) {
    final layer = oldLayer ?? TransformLayer();
    layer.transform = _effective;
    return layer;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      hitTestChildren(result, position: position);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!transformHitTests) {
      return super.hitTestChildren(result, position: position);
    }
    return result.addWithPaintTransform(
      transform: _effective,
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_effective);
  }
}

_VisibilityHost? _hostOf(BuildContext context) =>
    context is _VisibilityHost ? context as _VisibilityHost : null;
