import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/drive/drive_host.dart';

void main() {
  test(
      'actual HTTP outage preserves policy age; denial clears it; reconnect restores it',
      () async {
    final owner = NostrCrypto.generateIdentity(),
        service = NostrCrypto.generateIdentity();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final tower = 'http://127.0.0.1:${server.port}';
    final endpoint = 'http://${service.npub}.fips:7345';
    var status = 200, disconnect = false, malformedDenial = false;
    server.listen((req) async {
      if (disconnect) {
        (await req.response.detachSocket()).destroy();
        return;
      }
      req.response.statusCode = status;
      if (malformedDenial) {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html>denied');
        await req.response.close();
        return;
      }
      req.response.write(jsonEncode({
        'workspace_id': 'workspace',
        'share': {
          'id': 'share',
          'host_npub': service.npub,
          'endpoint': endpoint,
          'enabled': true
        },
        'allowed_npubs': [owner.npub]
      }));
      await req.response.close();
    });
    SharedPreferences.setMockInitialValues({
      DriveHost.storageKey: jsonEncode([
        {
          'id': 'share',
          'root': '/tmp',
          'tower': tower,
          'workspace_id': 'workspace',
          'owner_npub': owner.npub,
          'enabled': true
        }
      ])
    });
    var now = DateTime.now();
    Completer<void>? replayGate;
    final host = DriveHost(
        beforeReplay: () async {
          await replayGate?.future;
        },
        identityLoader: () async => service,
        endpointLoader: () async => endpoint,
        listenAddress: InternetAddress.loopbackIPv4,
        listenPort: 0,
        now: () => now);
    final config = AppConfig.defaults().copyWith(
        deviceNpub: owner.npub,
        deviceSecret: owner.nsec,
        towerUrl: tower,
        workspaceId: 'workspace');
    final client = HttpClient();
    var nonce = 0;
    Future<int> check() async {
      const path = '/drive/v1/share/status';
      final event = NostrCrypto.signEvent(secret: owner.nsec, event: {
        'kind': 27235,
        'created_at': now.millisecondsSinceEpoch ~/ 1000,
        'content': '',
        'tags': [
          ['u', '$endpoint$path'],
          ['method', 'GET'],
          ['workspace', 'workspace'],
          ['share', 'share'],
          ['nonce', '${nonce++}'.padLeft(32, 'a')]
        ]
      });
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:${host.listeningPort}$path'));
      req.headers.set('authorization',
          'Nostr ${base64Encode(utf8.encode(jsonEncode(event)))}');
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    try {
      await host.configure(config);
      replayGate = Completer<void>();
      final pending = List.generate(8, (_) => check());
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (host.activeRequests < 8 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(host.activeRequests, 8);
      expect(await check(), 429);
      replayGate.complete();
      replayGate = null;
      expect(await Future.wait(pending), List.filled(8, 200));
      expect(host.activeRequests, 0);
      final original = host.visible.first['fetched_at'];
      expect(await check(), 200);
      for (final code in [500, 502, 503, 429]) {
        status = code;
        now = now.add(const Duration(seconds: 1));
        await host.refreshPolicies();
        expect(host.visible.first['fetched_at'], original);
        expect(await check(), 200);
      }
      disconnect = true;
      await host.refreshPolicies();
      expect(host.visible.first['fetched_at'], original);
      now = now.add(const Duration(minutes: 15));
      expect(await check(), 403);
      disconnect = false;
      status = 200;
      await host.refreshPolicies();
      expect(await check(), 200);
      for (final code in [401, 403, 404]) {
        status = code;
        malformedDenial = true;
        await host.refreshPolicies();
        expect(await check(), 403);
        expect(host.visible.first.containsKey('policy'), false);
        malformedDenial = false;
        status = 200;
        await host.refreshPolicies();
        expect(await check(), 200);
      }
    } finally {
      client.close(force: true);
      await host.stop();
      host.dispose();
      await server.close(force: true);
    }
  });
}
