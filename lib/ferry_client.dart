import 'dart:async';
import 'dart:convert';

import 'package:ferry/ferry.dart';
import 'package:fpdart/fpdart.dart';
import 'package:gql/ast.dart';
import 'package:gql_error_link/gql_error_link.dart';
import 'package:gql_http_link/gql_http_link.dart';
import 'package:gql_transform_link/gql_transform_link.dart';
import 'package:gql_websocket_link/gql_websocket_link.dart';
import 'package:v_gql/http_link/http_link.dart';
import 'package:v_gql/http_link/retry_link.dart';
import 'package:http/http.dart' as http;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:v_gql/operation_defect.dart';

// Because of this issue: https://github.com/gql-dart/gql/issues/258#issuecomment-948692131
// if ErrorLink is in the link chain then unsubscribing from a subscription isn't happening
// if there is some errors this flag can be turned on for debug purposes.
const _isDebuggingErrors = false;

const _verboseLog = true;

bool _isNullable<T>() => null is T;

extension on dynamic {
  V? tryCast<V>() {
    try {
      return this as V;
    } catch (_) {
      return null;
    }
  }
}

extension OperationResponseX on OperationResponse<dynamic, dynamic> {
  List<GraphQLError> get errors {
    final serverException = linkException.tryCast<ServerException>();
    return [
      ...serverException?.parsedResponse?.errors ?? [],
      ...graphqlErrors ?? [],
    ];
  }
}

extension RequestX on Request {
  OperationType get operationType {
    final operationDefinitionNodes = operation.document.definitions.whereType<OperationDefinitionNode>();
    assert(operationDefinitionNodes.length == 1, 'Must have exactly one OperationDefinitionNode');

    final operationFromDefinition = operationDefinitionNodes.firstOrNull?.type;
    return operationFromDefinition ?? OperationType.query;
  }
}

abstract class LinkResolver {
  Link call();
}

class FerryClient<ExtensionDefectType> extends Client {
  LinkResolver linkResolver;
  ExtensionDefect<ExtensionDefectType>? Function(
    LinkException? linkException,
    List<GraphQLError> errors,
  )? convertToExtensionDefect;

  FerryClient(
    this.linkResolver, {
    super.defaultFetchPolicies = const {
      OperationType.query: FetchPolicy.NoCache,
      OperationType.mutation: FetchPolicy.NoCache,
      OperationType.subscription: FetchPolicy.NoCache,
    },
    super.typePolicies = const {},
    super.updateCacheHandlers = const {},
    super.cache,
    super.addTypename = true,
    super.requestController,
    this.convertToExtensionDefect,
  }) : super(link: linkResolver());

  factory FerryClient.create({
    Map<String, TypePolicy> typePolicies = const {},
    Map<String, Function> updateCacheHandlers = const {},
    Map<OperationType, FetchPolicy> defaultFetchPolicies = const {},
    bool addTypename = true,
    Cache? cache,
    StreamController<OperationRequest<dynamic, dynamic>>? requestController,
    //
    required String url,
    String? Function()? getAuthToken,
    Map<String, dynamic> httpHeaders = const {},
    Map<String, dynamic> initialPayload = const {},
    String? webServiceUrl,
    dynamic Function(ConnectionState)? onWebSocketConnectionStateChanged,
    ExtensionDefect<ExtensionDefectType>? Function(
      LinkException? linkException,
      List<GraphQLError> errors,
    )? convertToExtensionDefect,
  }) {
    return FerryClient(
      LinkResolverImplementation(
        url: url,
        getAuthToken: getAuthToken,
        httpHeaders: httpHeaders,
        initialPayload: initialPayload,
        onWebSocketConnectionStateChanged: onWebSocketConnectionStateChanged,
        webServiceUrl: webServiceUrl,
      ),
      addTypename: addTypename,
      cache: cache,
      defaultFetchPolicies: defaultFetchPolicies,
      requestController: requestController,
      typePolicies: typePolicies,
      updateCacheHandlers: updateCacheHandlers,
      convertToExtensionDefect: convertToExtensionDefect,
    );
  }

  Stream<Either<OperationDefect<ExtensionDefectType>, TResult>> reqStream<TData, TVars, TResponse, TResult>({
    required OperationRequest<TData, TVars> req,
    required TResponse? Function(TData data) require,
    required Future<TResult> Function(TResponse data) map,
    ExtensionDefect<ExtensionDefectType>? Function(
      LinkException? linkException,
      List<GraphQLError> errors,
    )? convertToExtensionDefect,
  }) {
    final isSubscription = req.execRequest.operationType == OperationType.subscription;
    final flatVarsString = req.vars.toString().replaceAll('\n', ' ').replaceAll(RegExp(' +'), ' ');
    if (_verboseLog && isSubscription) {
      timedDebugPrint('🧨 ${req.operation.operationName} -> $flatVarsString');
    }
    final stackTrace = Chain.current();

    return request(req).asyncMap(
      (response) async {
        if (_verboseLog) {
          if (response.dataSource == DataSource.Link) {
            if (isSubscription) {
              timedDebugPrint('🔥 ${req.operation.operationName} -> $flatVarsString');
            } else {
              if (response.hasErrors) {
                if (response.data == null) {
                  timedDebugPrint('🔁🔴 ${req.operation.operationName} -> $flatVarsString');
                } else {
                  timedDebugPrint('🔁🟠 ${req.operation.operationName} -> $flatVarsString');
                }
              } else {
                timedDebugPrint('🔁🟢 ${req.operation.operationName} -> $flatVarsString');
              }
            }
          } else {
            timedDebugPrint('🔁🟡 ${req.operation.operationName} -> $flatVarsString');
          }
        }
        return _handleResponse(
          req: req,
          require: require,
          map: map,
          response: response,
          stackTrace: stackTrace,
          convertToExtensionDefect: convertToExtensionDefect ?? this.convertToExtensionDefect,
        );
      },
    );
  }

  Future<Either<OperationDefect<ExtensionDefectType>, TResult>> req<TData, TVars, TResponse, TResult>({
    required OperationRequest<TData, TVars> req,
    required TResponse? Function(TData data) require,
    required FutureOr<TResult> Function(TResponse data) map,
    void Function(
      OperationResponse<TData, TVars> response,
      TResponse? requiredResponse,
      TResult? mappedResponse,
    )? onResponse,
    ExtensionDefect<ExtensionDefectType>? Function(
      LinkException? linkException,
      List<GraphQLError> errors,
    )? convertToExtensionDefect,
  }) async {
    final stackTrace = Chain.current();

    final response = await request(req).first;
    if (_verboseLog) {
      if (response.dataSource == DataSource.Link) {
        if (response.hasErrors) {
          if (response.data == null) {
            debugPrint('🔰🔴 ${req.operation.operationName}');
          } else {
            debugPrint('🔰🟠 ${req.operation.operationName}');
          }
        } else {
          debugPrint('🔰🟢 ${req.operation.operationName}');
        }
      } else {
        debugPrint('🔰🟡 ${req.operation.operationName}');
      }
    }

    return _handleResponse(
      req: req,
      require: require,
      map: map,
      response: response,
      stackTrace: stackTrace,
      convertToExtensionDefect: convertToExtensionDefect ?? this.convertToExtensionDefect,
    );
  }

  Future<Either<OperationDefect<ExtensionDefectType>, TResult>> _handleResponse<TData, TVars, TResponse, TResult>({
    required OperationRequest<TData, TVars> req,
    required TResponse? Function(TData data) require,
    required FutureOr<TResult> Function(TResponse data) map,
    required OperationResponse<TData, TVars> response,
    required StackTrace stackTrace,
    ExtensionDefect<ExtensionDefectType>? Function(
      LinkException? linkException,
      List<GraphQLError> errors,
    )? convertToExtensionDefect,
  }) async {
    final extensionDefect = convertToExtensionDefect?.call(response.linkException, response.errors);
    if (extensionDefect != null) {
      return Left(extensionDefect);
    }

    final data = response.data;

    if (data != null) {
      final requiredResponse = require(data);
      if (requiredResponse != null) {
        try {
          return Right(await map(requiredResponse));
        } catch (e, s) {
          return Left(FormatDefect(exception: e, graphqlErrors: response.errors, stackTrace: s));
        }
      } else {
        return Left(
          RequiredDataDefect(
            exception: response.linkException,
            graphqlErrors: response.errors,
            stackTrace: stackTrace,
          ),
        );
      }
    } else {
      if (_isNullable<TResponse>()) {
        return Right(null as TResult);
      } else {
        return Left(
          ResponseDefect(
            exception: response.linkException,
            graphqlErrors: response.errors,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }
}

class LinkResolverImplementation implements LinkResolver {
  final String? Function()? getAuthToken;
  final Map<String, dynamic> httpHeaders;
  final Map<String, dynamic> initialPayload;
  final String? webServiceUrl;
  final String url;
  final dynamic Function(ConnectionState)? onWebSocketConnectionStateChanged;

  final WebSocketLink? webSocketLink;
  final TransformLink appendAuthorizationHttpHeaderLink;
  final ErrorLink errorLink;
  final RetryLink retryLink;
  final HttpLink httpLink;

  LinkResolverImplementation({
    required this.url,
    this.getAuthToken,
    this.httpHeaders = const {},
    this.initialPayload = const {},
    this.webServiceUrl,
    this.onWebSocketConnectionStateChanged,
  })  : httpLink = CrossPlatformHttpLink().createClient(url: url),
        appendAuthorizationHttpHeaderLink = TransformLink(
          requestTransformer: (request) {
            return request.updateContextEntry<HttpLinkHeaders>((httpLinkHeaders) {
              final headers = httpLinkHeaders?.headers ?? <String, String>{};
              final authToken = getAuthToken?.call();

              return HttpLinkHeaders(
                headers: {
                  ...headers,
                  if (authToken != null) 'Authorization': authToken,
                },
              );
            });
          },
        ),
        webSocketLink = webServiceUrl != null
            ? WebSocketLink(
                inactivityTimeout: const Duration(seconds: 30),
                webServiceUrl,
                initialPayload: <String, dynamic>{
                  ...initialPayload,
                  'Authorization': getAuthToken?.call(),
                },
              )
            : null,
        errorLink = ErrorLink(
          onException: (request, forward, exception) {
            if (exception is ServerException) {
            } else {}
            return null;
          },
          onGraphQLError: (request, forward, response) {
            return null;
          },
        ),
        retryLink = RetryLink(
          shouldRetry: (exception) {
            final originalException = exception.originalException;
            if (originalException is http.ClientException) {
              if (originalException.message == 'Connection closed before full header was received') {
                return true;
              }
            }

            return false;
          },
          log: timedDebugPrint,
        ) {
    webSocketLink?.connectionStateStream.listen((event) {
      onWebSocketConnectionStateChanged?.call(event);
    });
  }

  @override
  Link call() => Link.route((request) {
        if (request.operationType == OperationType.subscription) {
          final effectiveWebSocketLink = webSocketLink;

          if (effectiveWebSocketLink == null) {
            return const PassthroughLink();
          }

          return Link.from([
            if (_isDebuggingErrors) errorLink,
            effectiveWebSocketLink,
          ]);
        }

        return Link.from([
          retryLink,
          errorLink,
          httpLink,
        ]);
      });
}

DateTime? _lastTimeDebugPrintDate;

String _formattedCurrentTime() {
  final now = DateTime.now();
  final elapsed = now.difference(_lastTimeDebugPrintDate ?? now);
  _lastTimeDebugPrintDate = now;
  final hours = now.hour.toString().padLeft(2, '0');
  final minutes = now.minute.toString().padLeft(2, '0');
  final seconds = now.second.toString().padLeft(2, '0');
  final milliseconds = now.millisecond.toString().padLeft(3, '0');
  final timestamp = '$hours:$minutes:$seconds.$milliseconds';

  if (elapsed > Duration.zero) {
    return '$timestamp (+${elapsed.inMilliseconds}ms)';
  }

  return timestamp;
}

void timedDebugPrint(String value) => debugPrint('${_formattedCurrentTime()} $value');

String prettyJson(Map<String, dynamic> json) => const JsonEncoder.withIndent('  ').convert(json);
