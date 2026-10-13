import 'dart:io';

class RuntimeEnvironment {
  static String? get wingmanSecret =>
      _readFirst(['WINGMAN_NSEC', 'WINGMAN_PRIV', 'AGENT_NSEC']);

  static String? _readFirst(List<String> keys) {
    for (final key in keys) {
      final value = Platform.environment[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
}
