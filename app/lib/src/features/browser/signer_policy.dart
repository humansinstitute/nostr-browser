import '../../core/app_config.dart';

class SignerPolicy {
  SignerPolicy({
    required Iterable<String> trustedOrigins,
    this.maxBodyBytes = 1024 * 1024,
  }) : _trustedOrigins = {
          for (final origin in trustedOrigins)
            if (normalizeOrigin(origin).isNotEmpty) normalizeOrigin(origin),
        };

  factory SignerPolicy.fromConfig(AppConfig config) {
    return SignerPolicy(trustedOrigins: config.effectiveTrustedOrigins());
  }

  final Set<String> _trustedOrigins;
  final int maxBodyBytes;

  List<String> get trustedOrigins => _trustedOrigins.toList(growable: false);

  bool canInject(String pageUrl) {
    final origin = normalizeOrigin(pageUrl);
    return origin.isNotEmpty && isWebUrl(pageUrl);
  }

  bool canSignNip07(String pageUrl) {
    return canInject(pageUrl);
  }

  SignerPolicyDecision validateNip98({
    required String pageUrl,
    required String targetUrl,
    required String method,
    String? body,
  }) {
    final pageOrigin = normalizeOrigin(pageUrl);
    if (pageOrigin.isEmpty || !_trustedOrigins.contains(pageOrigin)) {
      return SignerPolicyDecision.deny(
        reason:
            'untrusted WebView origin: ${pageOrigin.isEmpty ? pageUrl : pageOrigin}',
        pageOrigin: pageOrigin,
        targetOrigin: normalizeOrigin(targetUrl),
      );
    }

    final targetUri = Uri.tryParse(targetUrl);
    if (targetUri == null || !targetUri.hasScheme || targetUri.host.isEmpty) {
      return SignerPolicyDecision.deny(
        reason: 'invalid NIP-98 target URL',
        pageOrigin: pageOrigin,
        targetOrigin: '',
      );
    }

    if (targetUri.scheme != 'http' && targetUri.scheme != 'https') {
      return SignerPolicyDecision.deny(
        reason: 'unsupported NIP-98 target scheme: ${targetUri.scheme}',
        pageOrigin: pageOrigin,
        targetOrigin: normalizeOrigin(targetUrl),
      );
    }

    final targetOrigin = normalizeOrigin(targetUrl);
    if (!_trustedOrigins.contains(targetOrigin)) {
      return SignerPolicyDecision.deny(
        reason: 'untrusted NIP-98 target origin: $targetOrigin',
        pageOrigin: pageOrigin,
        targetOrigin: targetOrigin,
      );
    }

    final normalizedMethod = method.trim().toUpperCase();
    const allowedMethods = {
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'HEAD',
      'OPTIONS',
    };
    if (!allowedMethods.contains(normalizedMethod)) {
      return SignerPolicyDecision.deny(
        reason: 'unsupported NIP-98 method: $method',
        pageOrigin: pageOrigin,
        targetOrigin: targetOrigin,
      );
    }

    final bodyLength = body == null ? 0 : body.length;
    if (bodyLength > maxBodyBytes) {
      return SignerPolicyDecision.deny(
        reason: 'NIP-98 body is too large to sign in the browser bridge',
        pageOrigin: pageOrigin,
        targetOrigin: targetOrigin,
      );
    }

    return SignerPolicyDecision.allow(
      pageOrigin: pageOrigin,
      targetOrigin: targetOrigin,
      method: normalizedMethod,
    );
  }

  static String normalizeOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    if (uri.hasPort) return '${uri.scheme}://${uri.host}:${uri.port}';
    return '${uri.scheme}://${uri.host}';
  }

  static bool isWebUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}

class SignerPolicyDecision {
  const SignerPolicyDecision._({
    required this.allowed,
    required this.reason,
    required this.pageOrigin,
    required this.targetOrigin,
    required this.method,
  });

  factory SignerPolicyDecision.allow({
    required String pageOrigin,
    required String targetOrigin,
    required String method,
  }) {
    return SignerPolicyDecision._(
      allowed: true,
      reason: '',
      pageOrigin: pageOrigin,
      targetOrigin: targetOrigin,
      method: method,
    );
  }

  factory SignerPolicyDecision.deny({
    required String reason,
    required String pageOrigin,
    required String targetOrigin,
  }) {
    return SignerPolicyDecision._(
      allowed: false,
      reason: reason,
      pageOrigin: pageOrigin,
      targetOrigin: targetOrigin,
      method: '',
    );
  }

  final bool allowed;
  final String reason;
  final String pageOrigin;
  final String targetOrigin;
  final String method;
}
