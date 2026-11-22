import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Looks backward within one executable body. Earlier siblings can have
/// suspended execution, but sibling branches of the same decision cannot.
bool followsAwait(Expression write, FunctionBody body) {
  // A setter runs after its RHS, and update runs after argument evaluation.
  if (write.childEntities.whereType<AstNode>().any(_hasAwait)) return true;
  AstNode child = write;
  while (child != body) {
    final parent = child.parent!;
    if (parent is ForLoop &&
        parent.body == child &&
        parent.awaitKeyword != null) {
      return true;
    }
    if (_before(parent, child).any(_hasAwait)) return true;
    child = parent;
  }
  return false;
}

Iterable<AstNode> _before(AstNode parent, AstNode child) sync* {
  switch (parent) {
    case IfStatement(
      :final expression,
      :final caseClause,
      :final elseStatement,
    ):
      if (child == elseStatement) {
        yield expression;
        if (caseClause != null) yield caseClause;
      } else {
        yield* _precedingChildren(parent, child);
      }
    case IfElement(:final expression, :final caseClause, :final elseElement):
      if (child == elseElement) {
        yield expression;
        if (caseClause != null) yield caseClause;
      } else {
        yield* _precedingChildren(parent, child);
      }
    case ConditionalExpression(:final condition, :final elseExpression)
        when child == elseExpression:
      yield condition;
    case SwitchStatement(:final expression) when child is SwitchMember:
      yield expression;
    case SwitchExpression(:final expression) when child is SwitchExpressionCase:
      yield expression;
    case TryStatement(:final body) when child is CatchClause:
      yield body;
    case ForLoop(:final forLoopParts, :final body):
      if (child == body) {
        yield* _precedingChildren(forLoopParts, null).where(
          (part) =>
              forLoopParts is! ForParts ||
              !forLoopParts.updaters.contains(part),
        );
      }
    case ForParts(:final updaters) when updaters.contains(child):
      final loop = parent.parent;
      yield loop.body;
      yield* _precedingChildren(parent, child);
    default:
      yield* _precedingChildren(parent, child);
  }
}

Iterable<AstNode> _precedingChildren(AstNode parent, AstNode? child) => parent
    .childEntities
    .whereType<AstNode>()
    .takeWhile((node) => node != child);

bool _hasAwait(AstNode node) => node.accept(_AwaitFinder()) ?? false;

class _AwaitFinder extends GeneralizingAstVisitor<bool> {
  @override
  bool visitNode(AstNode node) =>
      (node is ForLoop && node.awaitKeyword != null) ||
      node.childEntities.whereType<AstNode>().any(_hasAwait);

  @override
  bool visitAwaitExpression(AwaitExpression node) => true;

  @override
  bool visitFunctionExpression(FunctionExpression node) => false;
}
