import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

const _rill = 'package:rill/';
const _flutter = 'package:flutter/src/';
const _binding = 'package:rill_flutter/';
const _mutable = {'Signal'};
const _readonly = {'Readable', 'Computed', 'AsyncComputed'};

bool _declaredIn(Element? element, String library) =>
    element?.library?.uri.toString().startsWith(library) ?? false;

bool _isType(DartType? type, Set<String> names) {
  if (type is TypeParameterType) return _isType(type.bound, names);
  return type is InterfaceType &&
      (_rillClass(type.element, names) ||
          type.element.allSupertypes.any((t) => _rillClass(t.element, names)));
}

bool _rillClass(InterfaceElement? element, Set<String> names) =>
    _declaredIn(element, _rill) && names.contains(element?.name);

bool isReadOnly(DartType? type) =>
    _isType(type, _readonly) && !_isType(type, _mutable);

bool isSignal(DartType? type) => _isType(type, _mutable);

bool _rillMember(Element? element, String name, Set<String> owners) {
  final owner = element?.enclosingElement;
  return element?.name == name &&
      owner is InterfaceElement &&
      _rillClass(owner, owners);
}

bool isValueWrite(AssignmentExpression node) =>
    _rillMember(node.writeElement, 'value', _mutable);

bool isUpdate(Element? element) => _rillMember(element, 'update', _mutable);

/// rill's `transact(`: a synchronous multi-field write without a task's
/// right to publish, checked like a bare write.
bool isTransact(Element? element) =>
    element is TopLevelFunctionElement &&
    element.name == 'transact' &&
    _declaredIn(element, _rill);

/// rill_flutter's `WidgetInput.sync(`: a frame write that is legal only in
/// its owner's `didUpdateWidget` / `didChangeDependencies`. Checked like a bare write in compute callbacks and frame
/// bodies, and also in a widget builder closure ([inBuild]).
bool isWidgetInputSync(Element? element) {
  final owner = element?.enclosingElement;
  return element is MethodElement &&
      element.name == 'sync' &&
      owner is InterfaceElement &&
      owner.name == 'WidgetInput' &&
      _declaredIn(owner, _binding);
}

bool isValueRead(SimpleIdentifier node) =>
    node.inGetterContext() &&
    node.element is GetterElement &&
    _rillMember(node.element, 'value', const {..._readonly, ..._mutable});

/// rill's state factories: the lowercase functions, `linger` from the
/// binding, the constructors of the classes that have no factory
/// (`Events`, `Wire`), and what makes owners and effects: `Scope(`,
/// `scope.child(`, `scope.effect(`, `scope.slot(`, and a
/// `ReactiveState`'s `input(`: each call is a new node its earlier
/// readers never see.
bool isCreator(Element? element) => switch (element) {
  MethodElement(:final name) =>
    const {'child', 'effect', 'slot'}.contains(name) &&
            _rillMember(element, name!, const {'Scope'}) ||
        name == 'input' && _isWidgetInputFactory(element),
  TopLevelFunctionElement(:final name) =>
    _declaredIn(element, _rill) &&
            const {
              'signal',
              'computed',
              'computedAsync',
              'computedStream',
            }.contains(name) ||
        _declaredIn(element, _binding) && name == 'linger',
  ConstructorElement(:final enclosingElement) => _rillClass(
    enclosingElement,
    const {'Events', 'Wire', 'Scope'},
  ),
  _ => false,
};

/// The `async` / `async*` function literal passed to `computedStream`.
FunctionExpression? asyncStreamBody(Element? element, ArgumentList arguments) {
  if (element is! TopLevelFunctionElement ||
      element.name != 'computedStream' ||
      !_declaredIn(element, _rill)) {
    return null;
  }
  for (final argument in arguments.arguments) {
    if (argument is! Expression) continue;
    Expression expression = argument;
    while (expression is ParenthesizedExpression) {
      expression = expression.expression;
    }
    if (expression is FunctionExpression && expression.body.isAsynchronous) {
      return expression;
    }
  }
  return null;
}

FunctionBody? enclosingBody(AstNode node) =>
    node.thisOrAncestorOfType<FunctionBody>();

FormalParameterElement? _callbackParameter(FunctionExpression closure) {
  Expression expression = closure;
  while (expression.parent is ParenthesizedExpression) {
    expression = expression.parent! as ParenthesizedExpression;
  }
  final parent = expression.parent;
  return parent is NamedArgument
      ? parent.correspondingParameter
      : expression.correspondingParameter;
}

bool isComputeBody(FunctionBody? body) {
  final closure = body?.parent;
  if (closure is! FunctionExpression) return false;
  final parameter = _callbackParameter(closure);
  final owner = parameter?.enclosingElement;
  if (owner is MethodElement &&
      owner.name == 'watch' &&
      _declaredIn(owner, _binding) &&
      owner.enclosingElement?.name == 'ReactiveState') {
    return parameter?.name == 'compute';
  }
  if (_rillMember(owner, 'effect', const {'Scope'})) {
    return parameter?.name == 'compute';
  }
  if (owner is! TopLevelFunctionElement || !_declaredIn(owner, _rill)) {
    return false;
  }
  return switch (owner.name) {
    'computed' ||
    'computedAsync' ||
    'computedStream' => parameter?.name == 'fn',
    'effect' => parameter?.name == 'compute',
    _ => false,
  };
}

bool isFrameBody(FunctionBody? body) {
  final declaration = body?.parent;
  if (declaration is! MethodDeclaration) return false;
  final method = declaration.declaredFragment?.element;
  final owner = method?.enclosingElement;
  if (method is! MethodElement ||
      method.isStatic ||
      owner is! InterfaceElement) {
    return false;
  }

  bool isFrameOwner(InterfaceElement element) => switch (method.name) {
    'build' =>
      _declaredIn(element, '${_flutter}widgets/framework.dart') &&
          const {'Widget', 'State'}.contains(element.name),
    'paint' =>
      _isCustomPainter(element) ||
          _declaredIn(element, _binding) && element.name == 'ReactivePainter',
    _ => false,
  };

  return isFrameOwner(owner) ||
      owner.allSupertypes.any((type) => isFrameOwner(type.element));
}

bool _isCustomPainter(InterfaceElement element) =>
    _declaredIn(element, '${_flutter}rendering/custom_paint.dart') &&
    element.name == 'CustomPainter';

/// The `paint` method of a plain [CustomPainter] subclass: it runs during
/// paint and nothing tracks it. A ReactivePainter is not one.
bool isPlainPaint(FunctionBody? body) {
  final declaration = body?.parent;
  if (declaration is! MethodDeclaration) return false;
  final method = declaration.declaredFragment?.element;
  final owner = method?.enclosingElement;
  return method is MethodElement &&
      !method.isStatic &&
      method.name == 'paint' &&
      owner is InterfaceElement &&
      owner.allSupertypes.any((type) => _isCustomPainter(type.element));
}

bool _isFrameworkClass(InterfaceElement? element, String name) =>
    element?.name == name && _declaredIn(element, _flutter);

bool _isSubtypeOf(DartType? type, bool Function(InterfaceElement) test) {
  if (type is TypeParameterType) return _isSubtypeOf(type.bound, test);
  return type is InterfaceType &&
      (test(type.element) ||
          type.element.allSupertypes.any((t) => test(t.element)));
}

bool _isWidget(DartType? type) =>
    _isSubtypeOf(type, (e) => _isFrameworkClass(e, 'Widget'));

/// `Widget`, `Widget?`, or a list / iterable of widgets.
bool _buildsWidgets(DartType type) {
  if (_isWidget(type)) return true;
  return type is InterfaceType &&
      (type.isDartCoreList || type.isDartCoreIterable) &&
      type.typeArguments.length == 1 &&
      _isWidget(type.typeArguments.single);
}

/// A widget builder by type: a function whose first parameter is a
/// BuildContext and that returns widgets (WidgetBuilder,
/// IndexedWidgetBuilder, TransitionBuilder, RoutePageBuilder, …).
bool _isWidgetBuilder(DartType? type) {
  if (type is! FunctionType) return false;
  final positional = type.formalParameters.where((p) => p.isPositional);
  if (positional.isEmpty) return false;
  final first = positional.first.type;
  return first is InterfaceType &&
      _isFrameworkClass(first.element, 'BuildContext') &&
      _buildsWidgets(type.returnType);
}

/// Types whose constructors keep a builder to run later, in another
/// Element's build: widgets, routes, overlay entries and delegates.
bool _defersBuilder(InterfaceElement element) =>
    _isFrameworkClass(element, 'Widget') ||
    _isFrameworkClass(element, 'Route') ||
    _isFrameworkClass(element, 'OverlayEntry') ||
    (element.name?.endsWith('Delegate') ?? false);

/// Return types of functions that hand a builder to a route or an overlay
/// and come back before it runs.
bool _returnsDeferred(DartType type) =>
    type.isDartAsyncFuture ||
    type.isDartAsyncFutureOr ||
    _isSubtypeOf(
      type,
      (e) =>
          _isFrameworkClass(e, 'Route') ||
          _isFrameworkClass(e, 'OverlayEntry') ||
          _isFrameworkClass(e, 'PersistentBottomSheetController'),
    );

/// The closure around [node] when it is a widget builder handed directly to
/// a callee known to run it later, outside any rill reader.
///
/// The lint only gives early hints that are never wrong; the runtime guard
/// (G2) is the authority (docs/lint.md#分层). So only the closure that
/// immediately encloses the read counts: a read inside a nested closure
/// (`map`, `forEach`, `List.generate`, a local helper) runs at a time the
/// lint does not follow, and is left to the guard. And only Flutter's own deferring APIs are known callees: a
/// widget, route, overlay entry or delegate constructor declared in Flutter,
/// or a Flutter function that returns a Future or route before the builder
/// runs (`showDialog` and its family). A constructor or function declared
/// anywhere else may run the builder at once (an initializer list, a body
/// before its return), and a `Reactive` subclass tracks it; the lint cannot
/// tell, so it does not report them.
FunctionExpression? untrackedBuilder(AstNode node) {
  final closure = enclosingBody(node)?.parent;
  if (closure is! FunctionExpression) return null;
  final parameter = _callbackParameter(closure);
  if (parameter == null || !_isWidgetBuilder(parameter.type)) return null;
  return _defers(parameter) ? closure : null;
}

/// Whether [node] sits directly in a closure passed where a widget builder
/// is expected (`Builder`, `LayoutBuilder`, an item builder …), deferred or
/// not: such a closure runs in a build or a layout, never in the owner's
/// `didUpdateWidget`. Only the immediately enclosing closure counts, as for
/// [untrackedBuilder].
bool _inWidgetBuilder(AstNode node) {
  final closure = enclosingBody(node)?.parent;
  if (closure is! FunctionExpression) return false;
  return _isWidgetBuilder(_callbackParameter(closure)?.type);
}

/// "In build" for what must not happen once per frame — creating state
/// (`rill_create_in_build`) and `WidgetInput.sync(` (`rill_write_in_build`):
/// a frame body ([isFrameBody]) or directly in a widget builder closure
/// ([_inWidgetBuilder]). One predicate, so the two rules cannot disagree.
bool inBuild(AstNode node) =>
    isFrameBody(enclosingBody(node)) || _inWidgetBuilder(node);

bool _defers(FormalParameterElement parameter) =>
    switch (parameter.enclosingElement) {
      final ConstructorElement constructor =>
        _declaredIn(constructor.enclosingElement, _flutter) &&
            (_defersBuilder(constructor.enclosingElement) ||
                constructor.enclosingElement.allSupertypes.any(
                  (type) => _defersBuilder(type.element),
                )),
      final ExecutableElement callee =>
        _declaredIn(callee, _flutter) && _returnsDeferred(callee.returnType),
      _ => false,
    };

bool isPublishStage(FunctionBody body) {
  final closure = body.parent;
  if (closure is! FunctionExpression) return false;
  final stage = _callbackParameter(closure);
  if (stage?.name != 'stage' ||
      !_rillMember(stage?.enclosingElement, 'publish', {'Task'})) {
    return false;
  }

  final enclosingClosure = closure.parent
      ?.thisOrAncestorOfType<FunctionBody>()
      ?.parent;
  if (enclosingClosure is! FunctionExpression) return false;
  final taskBody = _callbackParameter(enclosingClosure);
  return taskBody?.name == 'body' &&
      _rillMember(taskBody?.enclosingElement, 'run', {'Slot'});
}

/// rill's top-level `effect`, which applies synchronously when created.
bool isPlainEffect(Element? element) =>
    element is TopLevelFunctionElement &&
    element.name == 'effect' &&
    _declaredIn(element, _rill);

bool _extendsFramework(InterfaceElement element, String name) =>
    [element, ...element.allSupertypes.map((type) => type.element)].any(
      (type) =>
          type.name == name &&
          _declaredIn(type, '${_flutter}widgets/framework.dart'),
    );

/// rill's `Scope.effect`, which applies synchronously too.
bool isScopeEffect(Element? element) =>
    element is MethodElement && _rillMember(element, 'effect', const {'Scope'});

/// Code that runs while the framework builds or paints: any instance member
/// of a State (lifecycle methods and the helpers they call, field
/// initializers), a widget's build and a painter's paint. Closures inside
/// them run later (events, callbacks) and are not lifecycle sites.
bool isLifecycleSite(AstNode node) {
  final body = enclosingBody(node);
  if (isFrameBody(body)) return true;
  if (body == null) {
    final field = node.thisOrAncestorOfType<FieldDeclaration>();
    final owner = node
        .thisOrAncestorOfType<ClassDeclaration>()
        ?.declaredFragment
        ?.element;
    return field != null &&
        !field.isStatic &&
        owner != null &&
        _extendsFramework(owner, 'State');
  }
  final parent = body.parent;
  if (parent is MethodDeclaration) {
    final method = parent.declaredFragment?.element;
    final owner = method?.enclosingElement;
    if (method == null || method.isStatic || owner is! InterfaceElement) {
      return false;
    }
    return _extendsFramework(owner, 'State') ||
        (method.name == 'build' && _extendsFramework(owner, 'Widget'));
  }
  return false;
}

bool _isWidgetInputFactory(MethodElement element) {
  final owner = element.enclosingElement;
  return owner is InterfaceElement &&
      owner.name == 'ReactiveState' &&
      _declaredIn(owner, _binding);
}
