import 'dart:convert';

class FipsAppTarget {
  const FipsAppTarget({
    required this.nodeNpub,
    required this.port,
    required this.uri,
  });

  final String nodeNpub;
  final int port;
  final Uri uri;

  String get origin => 'http://${uri.host}:$port';

  static FipsAppTarget parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Enter a FIPS app URL or descriptor.');
    }

    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('The FIPS descriptor must be an object.');
      }
      final descriptor = decoded['fips'] is Map<String, dynamic>
          ? decoded['fips'] as Map<String, dynamic>
          : decoded;
      final url = descriptor['url']?.toString().trim() ?? '';
      final target = _parseUrl(url);
      final nodeNpub = descriptor['nodeNpub']?.toString().trim() ??
          descriptor['node_npub']?.toString().trim() ??
          '';
      final portValue = descriptor['port'];
      if (nodeNpub.isNotEmpty && nodeNpub != target.nodeNpub) {
        throw const FormatException(
          'The descriptor node npub does not match its URL.',
        );
      }
      if (portValue != null) {
        final descriptorPort =
            portValue is int ? portValue : int.tryParse(portValue.toString());
        if (descriptorPort != target.port) {
          throw const FormatException(
            'The descriptor port does not match its URL.',
          );
        }
      }
      return target;
    }

    return _parseUrl(trimmed);
  }

  static FipsAppTarget _parseUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException(
        'Use http://<node-npub>.fips:<port>/.',
      );
    }
    final hostParts = uri.host.split('.');
    if (hostParts.length != 2 ||
        hostParts.last != 'fips' ||
        !_isNpub(hostParts.first)) {
      throw const FormatException(
        'The host must be one exact FIPS node npub followed by .fips.',
      );
    }
    return FipsAppTarget(
      nodeNpub: hostParts.first,
      port: uri.port,
      uri: uri,
    );
  }

  static bool _isNpub(String value) {
    return RegExp(
      r'^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$',
    ).hasMatch(value);
  }
}
