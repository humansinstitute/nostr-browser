import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/signer_policy.dart';

void main() {
  group('SignerPolicy', () {
    test('normalizes trusted origins and injects on web pages', () {
      final policy = SignerPolicy(
        trustedOrigins: const ['https://flightdeck.example/app'],
      );

      expect(policy.trustedOrigins, ['https://flightdeck.example']);
      expect(policy.canInject('https://flightdeck.example/tasks'), isTrue);
      expect(policy.canInject('https://unknown.example/tasks'), isTrue);
      expect(policy.canInject('file:///tmp/index.html'), isFalse);
    });

    test('allows NIP-98 only when page and target origins are trusted', () {
      final policy = SignerPolicy(
        trustedOrigins: const [
          'https://flightdeck.example',
          'https://tower.example',
        ],
      );

      final decision = policy.validateNip98(
        pageUrl: 'https://flightdeck.example/app',
        targetUrl: 'https://tower.example/api/v4/flightdeck-pg/service',
        method: 'post',
      );

      expect(decision.allowed, isTrue);
      expect(decision.method, 'POST');
      expect(decision.pageOrigin, 'https://flightdeck.example');
      expect(decision.targetOrigin, 'https://tower.example');
    });

    test('denies untrusted page origins', () {
      final policy = SignerPolicy(
        trustedOrigins: const ['https://tower.example'],
      );

      final decision = policy.validateNip98(
        pageUrl: 'https://evil.example',
        targetUrl: 'https://tower.example/api',
        method: 'GET',
      );

      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('untrusted WebView origin'));
    });

    test('denies untrusted target origins', () {
      final policy = SignerPolicy(
        trustedOrigins: const ['https://flightdeck.example'],
      );

      final decision = policy.validateNip98(
        pageUrl: 'https://flightdeck.example',
        targetUrl: 'https://evil.example/api',
        method: 'GET',
      );

      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('untrusted NIP-98 target origin'));
    });

    test('denies unsupported target schemes and methods', () {
      final policy = SignerPolicy(
        trustedOrigins: const ['https://flightdeck.example'],
      );

      expect(
        policy
            .validateNip98(
              pageUrl: 'https://flightdeck.example',
              targetUrl: 'file:///tmp/secret',
              method: 'GET',
            )
            .allowed,
        isFalse,
      );
      expect(
        policy
            .validateNip98(
              pageUrl: 'https://flightdeck.example',
              targetUrl: 'https://flightdeck.example/api',
              method: 'TRACE',
            )
            .allowed,
        isFalse,
      );
    });

    test('denies oversized request bodies', () {
      final policy = SignerPolicy(
        trustedOrigins: const ['https://flightdeck.example'],
        maxBodyBytes: 4,
      );

      final decision = policy.validateNip98(
        pageUrl: 'https://flightdeck.example',
        targetUrl: 'https://flightdeck.example/api',
        method: 'POST',
        body: '12345',
      );

      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('too large'));
    });

    test('trusts one exact FIPS origin without trusting the suffix', () {
      final npub = 'npub1${List.filled(58, 'q').join()}';
      final origin = 'http://$npub.fips:41024';
      final policy = SignerPolicy(trustedOrigins: [origin]);

      expect(
        policy
            .validateNip98(
              pageUrl: '$origin/',
              targetUrl: '$origin/api/login',
              method: 'POST',
            )
            .allowed,
        isTrue,
      );
      expect(
        policy
            .validateNip98(
              pageUrl: 'http://npub1${List.filled(58, 'p').join()}.fips:41024/',
              targetUrl: '$origin/api/login',
              method: 'POST',
            )
            .allowed,
        isFalse,
      );
    });
  });
}
