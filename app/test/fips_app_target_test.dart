import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/fips_app_target.dart';

void main() {
  final npub = 'npub1${List.filled(58, 'q').join()}';

  test('accepts an exact HTTP npub.fips URL with a port', () {
    final target = FipsAppTarget.parse('http://$npub.fips:41024/');

    expect(target.nodeNpub, npub);
    expect(target.port, 41024);
    expect(target.origin, 'http://$npub.fips:41024');
    expect(target.uri.path, '/');
  });

  test('accepts a matching Autopilot descriptor', () {
    final target = FipsAppTarget.parse(jsonEncode({
      'nodeNpub': npub,
      'port': 41024,
      'url': 'http://$npub.fips:41024/',
    }));

    expect(target.origin, 'http://$npub.fips:41024');
  });

  test('accepts the FIPS object from an Autopilot app response', () {
    final target = FipsAppTarget.parse(jsonEncode({
      'id': 'example-app',
      'fips': {
        'nodeNpub': npub,
        'port': 41024,
        'url': 'http://$npub.fips:41024/',
      },
    }));

    expect(target.origin, 'http://$npub.fips:41024');
  });

  test('rejects HTTPS, missing ports, nested hosts, and descriptor mismatch',
      () {
    expect(
      () => FipsAppTarget.parse('https://$npub.fips:41024/'),
      throwsFormatException,
    );
    expect(
      () => FipsAppTarget.parse('http://$npub.fips/'),
      throwsFormatException,
    );
    expect(
      () => FipsAppTarget.parse('http://app.$npub.fips:41024/'),
      throwsFormatException,
    );
    expect(
      () => FipsAppTarget.parse(jsonEncode({
        'nodeNpub': 'npub1${List.filled(58, 'p').join()}',
        'port': 41024,
        'url': 'http://$npub.fips:41024/',
      })),
      throwsFormatException,
    );
  });
}
