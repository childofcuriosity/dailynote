/// VPS API 地址
/// 开发时用 localhost；手机连接时在 secrets.dart 里配置公网地址
import 'secrets.dart';

class ApiConfig {
  static String get baseUrl =>
      Secrets.vpsBaseUrl.isEmpty ? 'http://localhost:8080' : Secrets.vpsBaseUrl;
}
