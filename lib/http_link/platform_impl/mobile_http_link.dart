import 'package:gql_http_link/gql_http_link.dart';
import 'package:v_gql/http_link/platform_impl/base_http_link.dart';

class HttpLinkImpl extends BaseHttpLink {
  @override
  HttpLink createClient(String url) {
    return HttpLink(url);
  }
}
