part of '../rill_flutter.dart';

/// Paints [ReactivePainter]s: reads made in their [ReactivePainter.paint]
/// are tracked and repaint (only) this layer, and the time sources they read
/// follow this subtree's TickerMode and reduced motion.
class ReactivePaint extends StatefulWidget {
  const ReactivePaint({
    super.key,
    this.painter,
    this.foregroundPainter,
    this.size = Size.zero,
    this.isComplex = false,
    this.willChange = false,
    this.child,
  }) : assert(
         painter != null ||
             foregroundPainter != null ||
             (!isComplex && !willChange),
       );

  final ReactivePainter? painter;
  final ReactivePainter? foregroundPainter;
  final Size size;
  final bool isComplex;
  final bool willChange;
  final Widget? child;

  @override
  State<ReactivePaint> createState() => _ReactivePaintState();
}

class _ReactivePaintState extends State<ReactivePaint>
    implements _VisibilityHost {
  _PainterSlot? _background;
  _PainterSlot? _foreground;
  bool _active = true;

  @override
  Element? get visibilityElement =>
      _active && mounted ? context as Element : null;

  _PainterSlot? _adapt(ReactivePainter? painter, _PainterSlot? previous) {
    if (painter == null) return null;
    return identical(previous?.painter, painter)
        ? previous
        : _PainterSlot(painter, this);
  }

  @override
  void initState() {
    super.initState();
    // A ReactivePaint may be the only reader on an independent BuildOwner.
    _installGuards(context.owner);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // RenderCustomPaint keeps the same delegate across this rebuild and so
    // does not repaint: the slots ask their time sources to look again.
    _background?.repaint.hostChanged();
    _foreground?.repaint.hostChanged();
  }

  @override
  void activate() {
    _active = true;
    super.activate();
    _installGuards(context.owner);
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    _background = _adapt(widget.painter, _background);
    _foreground = _adapt(widget.foregroundPainter, _foreground);
    return CustomPaint(
      painter: _background,
      foregroundPainter: _foreground,
      size: widget.size,
      isComplex: widget.isComplex,
      willChange: widget.willChange,
      child: widget.child,
    );
  }
}

/// A painter whose [paint] is a tracked reader. It is not a
/// [CustomPainter]: mount it with [ReactivePaint], which gives every render
/// slot its own observer, even when two slots share one painter. Static
/// painters stay Flutter [CustomPainter]s in a [CustomPaint].
abstract class ReactivePainter {
  const ReactivePainter();

  void paint(Canvas canvas, Size size);

  bool? hitTest(Offset position) => null;

  SemanticsBuilderCallback? get semanticsBuilder => null;

  bool shouldRebuildSemantics(covariant ReactivePainter oldDelegate) => true;
}

/// The CustomPainter a [ReactivePaint] slot hands to the render object.
class _PainterSlot extends CustomPainter {
  _PainterSlot(ReactivePainter painter, _VisibilityHost host)
    : this._(painter, _Repaint(painter, host));

  _PainterSlot._(this.painter, this.repaint) : super(repaint: repaint);

  final ReactivePainter painter;
  final _Repaint repaint;

  @override
  void paint(Canvas canvas, Size size) =>
      repaint.paint(() => painter.paint(canvas, size));

  @override
  bool? hitTest(Offset position) => painter.hitTest(position);

  @override
  SemanticsBuilderCallback? get semanticsBuilder => painter.semanticsBuilder;

  @override
  bool shouldRepaint(covariant _PainterSlot oldDelegate) => true;

  @override
  bool shouldRebuildSemantics(covariant _PainterSlot oldDelegate) {
    // Painters without semantics on either side have nothing to rebuild:
    // a new instance each parent build must not mark semantics dirty.
    if (painter.semanticsBuilder == null &&
        oldDelegate.painter.semanticsBuilder == null) {
      return false;
    }
    return painter.runtimeType != oldDelegate.painter.runtimeType ||
        painter.shouldRebuildSemantics(oldDelegate.painter);
  }
}

class _Repaint extends ChangeNotifier {
  _Repaint(this.reader, this.host);

  final ReactivePainter reader;
  final _VisibilityHost host;
  _Observer? _observer;
  bool _hasPainted = false;

  void hostChanged() {
    final observer = _observer;
    if (observer != null && observer.motionQueried) observer.hostChanged();
  }

  void paint(VoidCallback draw) {
    final observer = _observer;
    if (observer == null) {
      draw();
    } else {
      observer.read(draw);
    }
    _hasPainted = true;
  }

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) {
      _observer = _Observer(
        notifyListeners,
        reader: reader,
        host: host,
        frameBound: true,
      );
      // RenderCustomPaint may keep its layer across a GlobalKey move.
      if (_hasPainted) notifyListeners();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _observer?.dispose();
      _observer = null;
    }
  }
}
