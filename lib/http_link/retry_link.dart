import 'package:async/async.dart';
import 'package:ferry/ferry.dart';
import 'package:gql/ast.dart';
import 'package:gql_error_link/gql_error_link.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_exec/gql_exec.dart' as gql_exec;
import 'package:gql_exec/gql_exec.dart';

// Taken from https://gist.github.com/knaeckeKami/cea6f62971ce7210f9708d7ea2070055
// Got this from: https://discord.com/channels/559455668810153989/705439370513088649/1034862140969996318

/// A handler of Link Exceptions.

/// a [Link] that handles Exceptions transparently and retries them
/// [RetryLink.maxRetries] times.
class RetryLink extends RecursiveErrorLink {
  RetryLink({
    required this.shouldRetry,
    this.maxRetryCount = 3,
    this.log,
  }) : super();

  final int maxRetryCount;

  final bool Function(LinkException) shouldRetry;
  final void Function(String)? log;

  @override
  ExceptionHandler get onException => (
        Request request,
        NextLink forward,
        LinkException exception,
      ) =>
          _retry(request, forward, exception, log);

  // We'll want to handle timeouts ourselves, so we can retry the request
  Stream<gql_exec.Response>? _retry(
    gql_exec.Request request,
    NextLink forward,
    LinkException exception,
    void Function(String)? log,
  ) {
    bool shouldRetryResult;

    try {
      shouldRetryResult = shouldRetry(exception);
    } catch (e) {
      shouldRetryResult = false;
    }

    if (shouldRetryResult) {
      // If we've already retried [maxRetryCount] times, give up
      final currentRetryCount = request.context.entry<_RequestRetryCount>()?.count ?? 0;
      if (currentRetryCount >= maxRetryCount) {
        log?.call('RetryLink: Giving up after $maxRetryCount retries');
        return null;
      }

      final bool requestHasOnlyQueries = request.operation.document.definitions.every((definition) {
        if (definition is OperationDefinitionNode) {
          // this definition is an operation (query, mutation, subscription)
          // check if it is a query, because we only retry queries, not mutations
          return definition.type == OperationType.query;
        }
        // currently the other only possible definition is a fragmentDefinition
        // assert that this is the case, so if this changes, this will throw assert errors
        // and we are forced to evaluate the code above ;)
        assert(definition is FragmentDefinitionNode);
        return true;
      });

      // request contains a mutation or a subscription, we don't retry those
      if (!requestHasOnlyQueries) {
        log?.call('RetryLink: Not retrying request with mutation or subscription');
        return null;
      }

      // mark the request as retried so we don't retry it more then maxRetryCount times
      final updatedRequest =
          request.updateContextEntry<_RequestRetryCount>((retries) => _RequestRetryCount((retries?.count ?? 0) + 1));
      log?.call('RetryLink: Retrying ($currentRetryCount/$maxRetryCount) request ${request.operation.operationName}');
      // And try the request again
      return forward(updatedRequest);
    }
    return null;
  }
}

/// A [gql_exec.ContextEntry] that keeps track of the number of times a request has been retried
class _RequestRetryCount extends gql_exec.ContextEntry {
  const _RequestRetryCount(this.count);

  final int count;

  @override
  List<Object?> get fieldsForEquality => [count];
}

typedef ExceptionHandler = Stream<Response>? Function(
  Request request,
  NextLink forward,
  LinkException exception,
);

/// like [ErrorLink], but with a twist:
/// the given [ExceptionHandler] handles [LinkException]s, like [ErrorLink],
/// but will also recursively forward errors until the given [ExceptionHandler] either
/// returns null or throws an exception (compared to ErrorLink, which can only handle a single error).
abstract class RecursiveErrorLink extends Link {
  ExceptionHandler get onException;

  @override
  Stream<Response> request(
    Request request, [
    NextLink? forward,
  ]) async* {
    assert(forward != null, 'RecursiveErrorLink is not a terminating link, therefore it must be given a forward link');
    // forward the request the forward and check for errors
    await for (final result in Result.captureStream(forward!(request))) {
      if (result.isError) {
        final error = result.asError!.error;

        if (error is LinkException) {
          // here is the recursion -> the [NextLink] of the Exceptionhandler is [this.request] so
          // errors will be handled by this link again (with a potentially updated request)
          final stream = onException(request, (r) => this.request(r, forward), error);

          if (stream != null) {
            yield* stream;
            return;
          }
        }
        yield* Stream.error(error);
      } else {
        assert(result.isValue);

        final response = result.asValue!.value;
        yield response;
      }
    }
  }
}
