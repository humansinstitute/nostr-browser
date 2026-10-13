import '../../core/fips_app_target.dart';

/// A single authentication request, never an origin or event-kind grant.
class MeshAuthRequest {
  const MeshAuthRequest(this.target, this.operation);

  final String target;
  final String operation;

  static MeshAuthRequest? parse(String method, Map<String, dynamic> params) {
    String? target;
    String? operation;
    var relay = false;
    if (method == 'signNip98') {
      if (params['url'] is! String) return null;
      target = params['url'] as String;
      operation = params['httpMethod']?.toString() ?? 'GET';
    } else if (method == 'signEvent') {
      final kind = params['kind'];
      if (kind != 27235 && kind != 22242) return null;
      if (params['content'] != '' || params['created_at'] is! int) return null;
      final tags = params['tags'];
      if (tags is! List) return null;
      final values = <String, String>{};
      relay = kind == 22242;
      final allowed = relay
          ? {'relay', 'challenge'}
          : {'u', 'method', 'payload', 'workspace', 'share', 'nonce'};
      for (final tag in tags) {
        if (tag is! List ||
            tag.length != 2 ||
            tag[0] is! String ||
            tag[1] is! String ||
            !allowed.contains(tag[0]) ||
            values.containsKey(tag[0])) {
          return null;
        }
        values[tag[0] as String] = tag[1] as String;
      }
      target = values[relay ? 'relay' : 'u'];
      operation = relay ? 'Relay authentication' : values['method'];
      if (relay && (values['challenge']?.isEmpty ?? true)) return null;
    }
    if (target == null || operation == null) return null;
    if (!relay &&
        !{'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'}
            .contains(operation)) {
      return null;
    }
    final uri = Uri.tryParse(target);
    if (uri == null ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        RegExp(r'[\x00-\x20\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(target) ||
        uri.scheme != (relay ? 'ws' : 'http')) {
      return null;
    }
    try {
      FipsAppTarget.parse(uri.replace(scheme: 'http').toString());
    } on FormatException {
      return null;
    }
    return MeshAuthRequest(target, operation);
  }
}
