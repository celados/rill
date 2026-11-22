import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import 'await_order.dart';
import 'semantics.dart';

enum RillLint {
  castToSignal(
    LintCode(
      'rill_cast_to_signal',
      'This type check or cast bypasses the read-only rill interface.',
      correctionMessage:
          'Pass a writable signal explicitly when mutation is required.',
    ),
  ),
  writeInComputed(
    LintCode(
      'rill_write_in_computed',
      'A rill compute callback must not write to a signal.',
      correctionMessage:
          'Move the write to a command or to the apply callback of an effect.',
    ),
  ),
  writeInBuild(
    LintCode(
      'rill_write_in_build',
      'Do not write to a rill signal during build or paint.',
      correctionMessage:
          'Move the write to an event handler or an appropriate lifecycle callback; '
          'sync a WidgetInput in didUpdateWidget / didChangeDependencies.',
    ),
  ),
  createInBuild(
    LintCode(
      'rill_create_in_build',
      'Do not create rill state during build or paint.',
      correctionMessage:
          'Create the state in its owning store or lifecycle scope.',
    ),
  ),
  untrackedRead(
    LintCode(
      'rill_untracked_read',
      'This builder or painter runs later, where nothing tracks reads of '
          'rill values.',
      correctionMessage:
          'Wrap the widget expression in Reactive (or use ReactiveLayoutBuilder '
          '/ ReactiveAnimatedBuilder), paint with a ReactivePainter in '
          'ReactivePaint, or use peek() for a snapshot.',
    ),
  ),
  writeAfterAwait(
    LintCode(
      'rill_write_after_await',
      'A bare signal write or transact may run after this async body has '
          'suspended.',
      correctionMessage:
          'Run the operation in a Slot and stage the write with Task.publish. '
          'A Timer or listener callback is an event, not a continuation, and '
          'is not flagged; derive periodic state from Pulse instead of '
          'writing it from a timer.',
    ),
  ),
  effectInLifecycle(
    LintCode(
      'rill_effect_in_lifecycle',
      'An effect created here applies synchronously, inside the build or '
          'paint.',
      correctionMessage:
          'Mix ReactiveState into the State and use watch: it tracks from '
          'mount, applies first after the frame and is disposed with the '
          'State.',
    ),
  ),
  asyncStarStream(
    LintCode(
      'rill_async_star_stream',
      'computedStream tracks inputs only until its function returns the '
          'stream; an async or async* body runs after that, untracked.',
      correctionMessage:
          'Make the function synchronous: read inputs and call q.wait first, '
          'then return the stream, e.g. '
          'Stream.fromFuture(q.wait(token)).asyncExpand((t) => api.watch(t)).',
    ),
  );

  const RillLint(this.code);

  final LintCode code;
}

class RillRule extends AnalysisRule {
  RillRule(this.kind)
    : super(
        name: kind.code.lowerCaseName,
        description: kind.code.problemMessage,
      );

  final RillLint kind;

  @override
  LintCode get diagnosticCode => kind.code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    // Tests write the store between pumps in place of the core: that is the
    // test's job, not a write racing a superseded task.
    if (kind == RillLint.writeAfterAwait && context.isInTestDirectory) return;
    final visitor = _Visitor(this);
    switch (kind) {
      case RillLint.castToSignal:
        registry.addAsExpression(this, visitor);
        registry.addIsExpression(this, visitor);
      case RillLint.untrackedRead:
        registry.addSimpleIdentifier(this, visitor);
      case RillLint.createInBuild:
        registry.addMethodInvocation(this, visitor);
        registry.addFunctionExpressionInvocation(this, visitor);
        registry.addInstanceCreationExpression(this, visitor);
      case RillLint.effectInLifecycle:
      case RillLint.asyncStarStream:
        registry.addMethodInvocation(this, visitor);
      case RillLint.writeInComputed:
      case RillLint.writeInBuild:
      case RillLint.writeAfterAwait:
        registry.addAssignmentExpression(this, visitor);
        registry.addMethodInvocation(this, visitor);
        registry.addFunctionExpressionInvocation(this, visitor);
    }
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final RillRule rule;

  void _checkCast(Expression operand, DartType? target, AstNode node) {
    if (isSignal(target) && isReadOnly(operand.staticType)) {
      rule.reportAtNode(node);
    }
  }

  void _checkWrite(Expression node) {
    final body = enclosingBody(node);
    final violates = switch (rule.kind) {
      RillLint.writeInComputed => isComputeBody(body),
      RillLint.writeInBuild => isFrameBody(body),
      RillLint.writeAfterAwait =>
        body != null &&
            body.isAsynchronous &&
            !isPublishStage(body) &&
            followsAwait(node, body),
      _ => false,
    };
    if (violates) rule.reportAtNode(node);
  }

  void _checkInvocation(InvocationExpression node) {
    final element = switch (node) {
      MethodInvocation(:final methodName) => methodName.element,
      FunctionExpressionInvocation(:final element) => element,
      _ => null,
    };
    if (rule.kind == RillLint.asyncStarStream) {
      final body = asyncStreamBody(element, node.argumentList);
      if (body != null) rule.reportAtNode(body);
    } else if (rule.kind == RillLint.effectInLifecycle) {
      if ((isPlainEffect(element) || isScopeEffect(element)) &&
          isLifecycleSite(node)) {
        rule.reportAtNode(node);
      }
    } else if (rule.kind == RillLint.createInBuild) {
      if (isCreator(element) && inBuild(node)) {
        rule.reportAtNode(node);
      }
    } else if (isUpdate(element) || isTransact(element)) {
      _checkWrite(node);
    } else if (isWidgetInputSync(element)) {
      _checkSync(node);
    }
  }

  /// `WidgetInput.sync(`. In a frame body the runtime sees
  /// the owner's build and refuses it, but not in a builder closure inside
  /// it: the owner's input window is open for the whole frame, and the
  /// closure runs after the owner's build returned. Those the lint reports.
  /// `didUpdateWidget` / `didChangeDependencies` and the helpers they call
  /// are neither, and are not reported.
  void _checkSync(InvocationExpression node) {
    final body = enclosingBody(node);
    final violates = switch (rule.kind) {
      RillLint.writeInComputed => isComputeBody(body),
      RillLint.writeInBuild => inBuild(node),
      _ => false,
    };
    if (violates) rule.reportAtNode(node);
  }

  @override
  void visitAsExpression(AsExpression node) =>
      _checkCast(node.expression, node.type.type, node.type);

  @override
  void visitIsExpression(IsExpression node) =>
      _checkCast(node.expression, node.type.type, node.type);

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (isValueWrite(node)) _checkWrite(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) => _checkInvocation(node);

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) =>
      _checkInvocation(node);

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (isCreator(node.constructorName.element) && inBuild(node)) {
      rule.reportAtNode(node);
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (isValueRead(node) &&
        (untrackedBuilder(node) != null || isPlainPaint(enclosingBody(node)))) {
      rule.reportAtNode(node);
    }
  }
}
