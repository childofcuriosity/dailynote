/// Web defaults to same-origin /api; can be overridden via --dart-define=API_BASE_URL=...
/// Do not import secrets.dart, to avoid bringing service keys into browser builds.
class ApiConfig {
  static const _override = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl {
    final value = _override.isEmpty
        ? Uri.base.resolve('/api').toString()
        : _override;
    return value.replaceFirst(RegExp(r'/+$'), '');
  }
}
