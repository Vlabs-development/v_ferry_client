import 'package:gql_http_link/gql_http_link.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:v_gql/http_link/platform_impl/base_http_link.dart';

class HttpLinkImpl extends BaseHttpLink {
  @override
  HttpLink createClient(String url) {
    final httpClient = http.Client();

    if (httpClient is BrowserClient) {
      httpClient.withCredentials = true;
    }

    return HttpLink(url, httpClient: httpClient);
  }
}
