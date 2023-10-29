import 'package:gql_http_link/gql_http_link.dart';

abstract class BaseHttpLink {
  HttpLink createClient(String url);
}
