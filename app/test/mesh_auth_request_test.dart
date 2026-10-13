import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/mesh_auth_request.dart';

const node = 'npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98';
const httpTarget = 'http://$node.fips:41007/synthetic.git';
const relayTarget = 'ws://$node.fips:41007/';
Map<String, dynamic> authEvent({bool relay = false, String? target}) => {
      'kind': relay ? 22242 : 27235,
      'created_at': 1,
      'content': '',
      'tags': [
        [relay ? 'relay' : 'u', target ?? (relay ? relayTarget : httpTarget)],
        [relay ? 'challenge' : 'method', relay ? 'test-challenge' : 'GET']
      ],
    };
void main() {
  test('derives exact HTTP and relay target without widening scheme port path',
      () {
    expect(MeshAuthRequest.parse('signEvent', authEvent())!.target, httpTarget);
    expect(MeshAuthRequest.parse('signEvent', authEvent(relay: true))!.target,
        relayTarget);
    expect(MeshAuthRequest.parse('signNip98', {'url': httpTarget})!.target,
        httpTarget);
  });
  test('rejects ambiguous deceptive and non-mesh auth targets', () {
    for (final target in [
      'https://public.example/repo',
      'http://user@$node.fips:41007/repo',
      '$httpTarget#fragment',
      '$httpTarget\n',
      'http://arbitrary.fips:41007/repo',
      'http://$node.fips/repo',
      relayTarget
    ]) {
      expect(
          MeshAuthRequest.parse('signEvent', authEvent(target: target)), isNull,
          reason: target);
    }
    for (final extra in [
      ['u', httpTarget],
      ['u', 'garbage'],
      ['method', 'POST'],
      ['relay', relayTarget],
      ['unknown', 'value']
    ]) {
      final event = authEvent();
      (event['tags'] as List).add(extra);
      expect(MeshAuthRequest.parse('signEvent', event), isNull);
    }
    expect(MeshAuthRequest.parse('signEvent', {...authEvent(), 'kind': 1}),
        isNull);
    expect(
        MeshAuthRequest.parse(
            'signEvent', {...authEvent(), 'content': 'publish'}),
        isNull);
    expect(
        MeshAuthRequest.parse(
            'signEvent', authEvent(relay: true, target: httpTarget)),
        isNull);
  });
}
