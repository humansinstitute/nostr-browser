import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/grasp_fips_transport.dart';
import 'package:wingman_app/src/features/browser/grasp_fips_browser_bridge.dart';

const node = 'npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98';
const endpoint = 'http://$node.fips:8787';
void main() {
  late HttpServer server;
  late GraspFipsTransport transport;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    transport = GraspFipsTransport(
      endpoint,
      clientFactory: () => HttpClient()
        ..connectionFactory = (_, __, ___) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
    );
  });
  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });
  test(
    'binary HTTP and challenge headers; no cookies or host spoofing',
    () async {
      final bytes = List.generate(180000, (i) => i % 256);
      server.listen((r) async {
        expect(r.headers.value('host'), '$node.fips:8787');
        expect(r.headers.value('cookie'), isNull);
        expect(r.headers.value('origin'), isNull);
        expect(r.headers.value('git-protocol'), 'version=2');
        expect(r.headers.value('authorization'), 'Nostr test');
        final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(body, bytes);
        r.response.statusCode = 401;
        r.response.headers.set('www-authenticate', 'Nostr method="GET"');
        r.response.headers.set('set-cookie', 'secret=1');
        r.response.add(body);
        await r.response.close();
      });
      final r = await transport
          .open('$endpoint/owner/repo.git/git-upload-pack', 'POST', {
        'host': 'other',
        'cookie': 'bad',
        'origin': 'bad',
        'authorization': 'Nostr test',
        'git-protocol': 'version=2',
      });
      for (var i = 0; i < bytes.length; i += 60000) {
        await r.write(
          base64Encode(bytes.sublist(i, (i + 60000).clamp(0, bytes.length))),
        );
      }
      final meta = await r.finish();
      expect(meta['status'], 401);
      expect(meta['headers']['www-authenticate'], 'Nostr method="GET"');
      expect(meta['headers']['set-cookie'], isNull);
      final received = <int>[];
      while (true) {
        final next = await r.pull();
        if (next['done'] == true) break;
        received.addAll(base64Decode(next['chunk']));
      }
      expect(received, bytes);
    },
  );
  test('other service/port/userinfo/fragment and redirects rejected', () async {
    for (final target in [
      '$endpoint.evil/x',
      'http://$node.fips:8788/x',
      '$endpoint/x#bad',
      'http://user@$node.fips:8787/x',
      'https://example.com/x',
    ]) {
      expect(() => transport.open(target, 'GET', {}), throwsFormatException);
    }
    server.listen((r) async {
      r.response.statusCode = 302;
      r.response.headers.set('location', 'http://127.0.0.1/secret');
      await r.response.close();
    });
    final r = await transport.open('$endpoint/redirect', 'GET', {});
    await expectLater(r.finish(), throwsStateError);
  });
  test('real WebSocket handshake, challenge, binary and revoke', () async {
    server.listen((r) async {
      final ws = await WebSocketTransformer.upgrade(r);
      ws.add('["AUTH","fixture-challenge"]');
      ws.listen(ws.add);
    });
    final ws = await transport.socket(
      '${endpoint.replaceFirst('http:', 'ws:')}/',
    );
    expect((await ws.next())['data'], '["AUTH","fixture-challenge"]');
    expect(transport.hasChallenge(ws.url, 'fixture-challenge'), isTrue);
    await ws.send(base64Encode([0, 255, 12]), false);
    expect((await ws.next())['data'], base64Encode([0, 255, 12]));
    final pending = ws.next();
    transport.close();
    await pending.catchError((_) => <String, dynamic>{});
    expect(transport.hasChallenge(ws.url, 'fixture-challenge'), isFalse);
    await expectLater(ws.send('no', true), throwsStateError);
  });
  test(
      'relay diagnostics correlate AUTH, retry, EOSE and revocation without payloads',
      () async {
    server.listen((r) async {
      final ws = await WebSocketTransformer.upgrade(r);
      ws.add('["AUTH","private-challenge"]');
      ws.listen((message) {
        final frame = jsonDecode(message as String) as List;
        if (frame[0] == 'AUTH') {
          ws.add('["OK","test-auth-id",true,""]');
        } else if (frame[0] == 'REQ') {
          ws.add('["EVENT","sub",{"kind":30617,"content":"private-content"}]');
          ws.add('["EOSE","sub"]');
        }
      });
    });
    final stages = <String>[];
    dynamic reply;
    final bridge = GraspFipsBrowserBridge(
      pageOrigin: 'https://app.example',
      approve: (_) async => GraspFipsConsentResult.approved,
      prepare: (_) async => null,
      transportFactory: (_) => transport,
      onDiagnostic: (tab, relay, stage) => stages.add('$tab/$relay/$stage'),
      reply: (script) async {
        reply = (jsonDecode(
          '[${script.substring(script.indexOf('(') + 1, script.length - 1)}]',
        ) as List)[2];
      },
    );
    final token =
        RegExp(r'const token = "([^"]+)"').firstMatch(bridge.script)!.group(1);
    Future<dynamic> rpc(String method, Map<String, dynamic> params) async {
      await bridge.receive(jsonEncode({
        'token': token,
        'id': method,
        'method': method,
        'params': params,
      }));
      return reply;
    }

    final grant = await rpc('connect', {'endpoint': endpoint});
    final id = await rpc('wsOpen', {
      'grantId': grant['grantId'],
      'url': '${endpoint.replaceFirst('http:', 'ws:')}/',
    });
    await rpc('wsNext', {'requestId': id});
    bridge.recordAuthentication(null, 'signer_scope_denied');
    bridge.recordAuthentication(grant['grantId'] as String, 'signer_request');
    bridge.recordAuthentication(grant['grantId'] as String, 'signer_signed');
    await rpc('wsSend', {
      'requestId': id,
      'text': true,
      'data': '["AUTH",{"id":"test-auth-id"}]',
    });
    await rpc('wsNext', {'requestId': id});
    await rpc('wsSend', {
      'requestId': id,
      'text': true,
      'data': '["REQ","sub",{}]',
    });
    await rpc('wsNext', {'requestId': id});
    await rpc('wsNext', {'requestId': id});
    await rpc('disconnect', {'grantId': grant['grantId']});
    final labels = stages.map((s) => s.split('/').last).toList();
    expect(
        labels,
        containsAllInOrder([
          'ws_open_start',
          'ws_open_ok',
          'auth_challenge',
          'signer_scope_denied',
          'signer_request',
          'signer_signed',
          'auth_sent',
          'auth_ok',
          'req_sent',
          'event_received',
          'eose_received',
          'bridge_revoked',
        ]));
    expect(stages.map((s) => s.split('/').take(2).join('/')).toSet(),
        hasLength(1));
    expect(stages.join(), isNot(contains('private-')));
    expect(stages.join(), isNot(contains('test-auth-id')));
    bridge.close();
  });
  test(
    'revocation safely destroys socket during queued and active sends',
    () async {
      server.listen((r) async {
        final ws = await WebSocketTransformer.upgrade(r);
        ws.listen((_) {}).pause();
      });
      final ws = await transport.socket(
        '${endpoint.replaceFirst('http:', 'ws:')}/',
      );
      final data = base64Encode(List.filled(1024 * 1024, 7));
      final pending = List.generate(
        4,
        (_) => ws.send(data, false).catchError((Object _) {}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.close, returnsNormally);
      await Future.wait(pending).timeout(const Duration(seconds: 2));
      expect(ws.closed, isTrue);
    },
  );
  test('cancellation interrupts pending HTTP headers', () async {
    server.listen((r) {});
    final r = await transport.open('$endpoint/hang', 'GET', {});
    final check = expectLater(r.finish(), throwsA(anything));
    r.close();
    await check.timeout(const Duration(seconds: 2));
  });
  test(
    'auth is root GET only and relay challenge belongs to active grant',
    () async {
      server.listen((r) async {
        final ws = await WebSocketTransformer.upgrade(r);
        ws.add('["AUTH","current-challenge"]');
        ws.listen((_) {});
      });
      dynamic result;
      final bridge = GraspFipsBrowserBridge(
        pageOrigin: 'https://app.example',
        approve: (_) async => GraspFipsConsentResult.approved,
        prepare: (_) async => null,
        transportFactory: (_) => transport,
        reply: (s) async {
          if (s.contains('Reply')) {
            result = (jsonDecode(
              '[${s.substring(s.indexOf('(') + 1, s.length - 1)}]',
            ) as List)[2];
          }
        },
      );
      final token = RegExp(
        r'const token = "([^"]+)"',
      ).firstMatch(bridge.script)!.group(1);
      expect(bridge.script, contains('connectDrive'));
      expect(bridge.script, contains('save:true'));
      Future<void> rpc(String method, Map<String, dynamic> params) =>
          bridge.receive(
            jsonEncode({
              'token': token,
              'id': method,
              'method': method,
              'params': params,
            }),
          );
      Map<String, dynamic> event(int kind, List<List<String>> tags) => {
            'kind': kind,
            'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'content': '',
            'tags': tags,
          };
      final http = event(27235, [
        ['u', '$endpoint/owner/repo.git'],
        ['method', 'GET'],
      ]);
      expect(bridge.permitsAuthentication('signEvent', http), isFalse);
      await rpc('connect', {'endpoint': endpoint});
      final epoch = bridge.grantEpoch;
      expect(bridge.permitsAuthentication('signEvent', http), isTrue);
      expect(
        bridge.permitsAuthentication(
          'signEvent',
          event(27235, [
            ['u', '$endpoint/owner/repo.git'],
            ['method', 'POST'],
          ]),
        ),
        isFalse,
      );
      final url = '${endpoint.replaceFirst('http:', 'ws:')}/';
      final auth = event(22242, [
        ['relay', url],
        ['challenge', 'current-challenge'],
      ]);
      expect(bridge.permitsAuthentication('signEvent', auth), isFalse);
      await rpc('wsOpen', {'url': url});
      final id = result;
      await rpc('wsNext', {'requestId': id});
      expect(bridge.permitsAuthentication('signEvent', auth), isTrue);
      expect(
        bridge.permitsAuthentication(
          'signEvent',
          event(22242, [
            ['relay', url],
            ['challenge', 'wrong'],
          ]),
        ),
        isFalse,
      );
      await rpc('disconnect', {});
      expect(bridge.grantEpoch, greaterThan(epoch));
      expect(bridge.permitsAuthentication('signEvent', auth), isFalse);
      expect(bridge.permitsAuthentication('signEvent', http), isFalse);
      bridge.close();
    },
  );
  test('Autopilot NIP-98 auth is bound to its exact active grant', () async {
    final bridge = GraspFipsBrowserBridge(
      pageOrigin: 'https://flightdeck.example',
      approve: (_) async => GraspFipsConsentResult.approved,
      prepare: (_) async => null,
      transportFactory: (_) => transport,
      reply: (_) async {},
    );
    final token = RegExp(
      r'const token = "([^"]+)"',
    ).firstMatch(bridge.script)!.group(1);
    Future<void> rpc(String method, Map<String, dynamic> params) =>
        bridge.receive(
          jsonEncode({
            'token': token,
            'id': method,
            'method': method,
            'params': params,
          }),
        );
    final request = {
      'url': '$endpoint/api/agents/overview',
      'httpMethod': 'GET',
    };

    expect(bridge.authenticationGrant('signNip98', request), isNull);
    await rpc('connect', {
      'endpoint': endpoint,
      'peerNpub': node,
      'purpose': 'autopilot',
    });
    final grant = bridge.authenticationGrant('signNip98', request);
    expect(grant?.endpoint, endpoint);
    expect(grant?.peerNpub, node);
    expect(grant?.purpose, 'autopilot');
    expect(grant?.operation, 'GET');
    expect(
      bridge.authenticationGrant('signNip98', {
        ...request,
        'url': 'http://$node.fips:8788/api/agents/overview',
      }),
      isNull,
    );
    await rpc('disconnect', {});
    expect(bridge.authenticationGrant('signNip98', request), isNull);
    bridge.close();
  });
  test('native request failures return sanitized bridge diagnostics', () async {
    final replies = <String>[];
    final bridge = GraspFipsBrowserBridge(
      pageOrigin: 'https://app.example',
      approve: (_) async => GraspFipsConsentResult.approved,
      prepare: (_) async => null,
      transportFactory: (_) => _FailingOpenTransport(endpoint),
      reply: (script) async => replies.add(script),
    );
    final token = RegExp(
      r'const token = "([^"]+)"',
    ).firstMatch(bridge.script)!.group(1);

    Future<List<dynamic>> rpc(
      String id,
      String method,
      Map<String, dynamic> params,
    ) async {
      await bridge.receive(
        jsonEncode({
          'token': token,
          'id': id,
          'method': method,
          'params': params,
        }),
      );
      final reply = replies.last;
      return jsonDecode(
        '[${reply.substring(reply.indexOf('(') + 1, reply.length - 1)}]',
      ) as List<dynamic>;
    }

    final connected = await rpc('connect', 'connect', {'endpoint': endpoint});
    expect(connected[2], containsPair('version', 2));
    expect(connected[2], containsPair('endpoint', endpoint));
    expect(connected[2], containsPair('purpose', 'service'));
    final failed = await rpc('open', 'open', {
      'url': '$endpoint/drive/v1/share/list?path=',
      'method': 'GET',
      'headers': {'authorization': 'Nostr test'},
    });
    expect(failed[2], isNull);
    expect(failed[3], 'wmapp_grasp_open_socket_failed');
    bridge.close();
  });
  test('denial not reprompted and stale consent cannot activate', () async {
    var prompts = 0;
    final gate = Completer<bool>();
    final bridge = GraspFipsBrowserBridge(
      pageOrigin: 'https://app.example',
      approve: (_) {
        prompts++;
        return gate.future.then(
          (approved) => approved
              ? GraspFipsConsentResult.approved
              : GraspFipsConsentResult.denied,
        );
      },
      prepare: (_) async => null,
      reply: (_) async {},
    );
    final token = RegExp(
      r'const token = "([^"]+)"',
    ).firstMatch(bridge.script)!.group(1);
    final call = bridge.receive(
      jsonEncode({
        'token': token,
        'id': '1',
        'method': 'connect',
        'params': {'endpoint': endpoint},
      }),
    );
    bridge.close();
    gate.complete(true);
    await call;
    expect(bridge.endpoint, isNull);
    expect(prompts, 1);
    final denied = GraspFipsBrowserBridge(
      pageOrigin: 'https://app.example',
      approve: (_) async {
        prompts++;
        return GraspFipsConsentResult.denied;
      },
      prepare: (_) async => null,
      reply: (_) async {},
    );
    final dt = RegExp(
      r'const token = "([^"]+)"',
    ).firstMatch(denied.script)!.group(1);
    for (var i = 0; i < 2; i++) {
      await denied.receive(
        jsonEncode({
          'token': dt,
          'id': '$i',
          'method': 'connect',
          'params': {'endpoint': endpoint},
        }),
      );
    }
    expect(prompts, 2);
    denied.close();
  });
  test(
    'transient unavailable connectDrive consent is not remembered',
    () async {
      var prompts = 0;
      var first = true;
      final errors = <String>[];
      final bridge = GraspFipsBrowserBridge(
        pageOrigin: 'https://app.example',
        approve: (_) async {
          prompts++;
          if (first) {
            first = false;
            return GraspFipsConsentResult.unavailable;
          }
          return GraspFipsConsentResult.approved;
        },
        prepare: (_) async => null,
        transportFactory: (_) => transport,
        reply: (script) async {
          final match = RegExp(r'null,"([^"]+)"\)$').firstMatch(script);
          if (match != null) errors.add(match.group(1)!);
        },
      );
      final token = RegExp(
        r'const token = "([^"]+)"',
      ).firstMatch(bridge.script)!.group(1);
      Future<void> rpc(String id) => bridge.receive(
            jsonEncode({
              'token': token,
              'id': id,
              'method': 'connectDrive',
              'params': {'endpoint': endpoint},
            }),
          );
      await rpc('first');
      expect(bridge.hasDrive, isFalse);
      expect(errors, contains('unavailable'));
      await rpc('second');
      expect(prompts, 2);
      expect(bridge.hasDrive, isTrue);
      bridge.close();
    },
  );
  test('duplicate connectDrive does not cache endpoint denial', () async {
    var prompts = 0;
    final gate = Completer<GraspFipsConsentResult>();
    final bridge = GraspFipsBrowserBridge(
      pageOrigin: 'https://app.example',
      approve: (_) {
        prompts++;
        return gate.future;
      },
      prepare: (_) async => null,
      transportFactory: (_) => transport,
      reply: (_) async {},
    );
    final token = RegExp(
      r'const token = "([^"]+)"',
    ).firstMatch(bridge.script)!.group(1);
    Future<void> rpc(String id) => bridge.receive(
          jsonEncode({
            'token': token,
            'id': id,
            'method': 'connectDrive',
            'params': {'endpoint': endpoint},
          }),
        );
    final first = rpc('first');
    await Future<void>.delayed(Duration.zero);
    await rpc('duplicate');
    expect(prompts, 1);
    gate.complete(GraspFipsConsentResult.approved);
    await first;
    expect(bridge.hasDrive, isTrue);
    bridge.close();
  });
  test('multiple endpoint grants connect concurrently and revoke independently',
      () async {
    const otherNode =
        'npub109684nue495hq240u3dqzyf2kltk23u3mqkk9l44ga6szed4jcysramf74';
    const otherEndpoint = 'http://$otherNode.fips:43100';
    final gates = <String, Completer<GraspFipsConsentResult>>{};
    final transports = <String, _RecordingTransport>{};
    final replies = <String, Map<String, dynamic>>{};
    final bridge = GraspFipsBrowserBridge(
      pageOrigin: 'https://app.example',
      approve: (value) => (gates[value.endpoint] ??=
              Completer<GraspFipsConsentResult>())
          .future,
      prepare: (_) async => null,
      transportFactory: (value) =>
          transports[value] = _RecordingTransport(value),
      reply: (script) async {
        final values = jsonDecode(
          '[${script.substring(script.indexOf('(') + 1, script.length - 1)}]',
        ) as List<dynamic>;
        if (values[2] is Map) {
          replies[values[1] as String] =
              (values[2] as Map).cast<String, dynamic>();
        }
      },
    );
    final token =
        RegExp(r'const token = "([^"]+)"').firstMatch(bridge.script)!.group(1);
    Future<void> connect(String id, String value, String purpose) =>
        bridge.receive(jsonEncode({
          'token': token,
          'id': id,
          'method': 'connect',
          'params': {'endpoint': value, 'purpose': purpose},
        }));

    final first = connect('autopilot', endpoint, 'autopilot');
    final second = connect('git', otherEndpoint, 'git');
    await Future<void>.delayed(Duration.zero);
    expect(gates.keys, containsAll(<String>{endpoint, otherEndpoint}));
    gates[endpoint]!.complete(GraspFipsConsentResult.approved);
    gates[otherEndpoint]!.complete(GraspFipsConsentResult.approved);
    await Future.wait([first, second]);
    expect(replies['autopilot']?['purpose'], 'autopilot');
    expect(replies['git']?['purpose'], 'git');

    await bridge.receive(jsonEncode({
      'token': token,
      'id': 'disconnect-autopilot',
      'method': 'disconnect',
      'params': {'grantId': replies['autopilot']!['grantId']},
    }));
    expect(transports[endpoint]!.wasClosed, isTrue);
    expect(transports[otherEndpoint]!.wasClosed, isFalse);
    bridge.close();
    expect(transports[otherEndpoint]!.wasClosed, isTrue);
  });
  test('connectDrive waits for native consent instead of timing out', () {
    expect(
      bridgeTimerGuard(
        GraspFipsBrowserBridge(
          pageOrigin: 'https://app.example',
          approve: (_) async => GraspFipsConsentResult.approved,
          prepare: (_) async => null,
          reply: (_) async {},
        ).script,
      ),
      isTrue,
    );
  });
}

bool bridgeTimerGuard(String script) {
  final timerLine =
      script.split('\n').firstWhere((line) => line.contains('const timer ='));
  return timerLine.contains("method === 'connectDrive'");
}

class _FailingOpenTransport extends GraspFipsTransport {
  _FailingOpenTransport(super.endpoint);

  @override
  Future<GraspHttpRequest> open(
      String url, String method, Map<String, dynamic> headers) {
    throw const SocketException('private mesh address unavailable');
  }
}

class _RecordingTransport extends GraspFipsTransport {
  _RecordingTransport(super.endpoint);

  bool wasClosed = false;

  @override
  void close() {
    wasClosed = true;
    super.close();
  }
}
