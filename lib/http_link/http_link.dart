import 'package:v_gql/http_link/platform_impl/stub_http_link.dart'
    if (dart.library.io) 'package:v_gql/http_link/platform_impl/mobile_http_link.dart'
    if (dart.library.html) 'package:v_gql/http_link/platform_impl/web_http_link.dart';
import 'package:gql_http_link/gql_http_link.dart';

class CrossPlatformHttpLink {
  CrossPlatformHttpLink() : _impl = HttpLinkImpl();
  final HttpLinkImpl _impl;

  HttpLink createClient({required String url}) {
    return _impl.createClient(url);
  }
}
