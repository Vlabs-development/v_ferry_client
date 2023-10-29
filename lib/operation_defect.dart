import 'package:gql_exec/gql_exec.dart';

sealed class OperationDefect<T> {
  OperationDefect({
    required this.exception,
    required this.stackTrace,
    required this.graphqlErrors,
  });

  final Object? exception;
  final StackTrace stackTrace;
  final List<GraphQLError> graphqlErrors;

  @override
  String toString() => '$runtimeType $exception $graphqlErrors';
}

class ResponseDefect<T> extends OperationDefect<T> {
  ResponseDefect({required super.exception, required super.graphqlErrors, required super.stackTrace});
}

class RequiredDataDefect<T> extends OperationDefect<T> {
  RequiredDataDefect({required super.exception, required super.graphqlErrors, required super.stackTrace});
}

class FormatDefect<T> extends OperationDefect<T> {
  FormatDefect({required super.exception, required super.graphqlErrors, required super.stackTrace});
}

class ExtensionDefect<T> extends OperationDefect<T> {
  ExtensionDefect({
    required super.exception,
    required super.graphqlErrors,
    required super.stackTrace,
    required this.defects,
  });

  List<T> defects;

  @override
  String toString() => '$defects';
}
