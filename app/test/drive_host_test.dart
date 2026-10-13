// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/drive/drive_host.dart';
import 'package:wingman_app/src/features/drive/drive_protocol.dart';
import 'package:wingman_app/src/features/drive/drive_screen.dart';

void main() {
  test('FIPS off tears down hosting and on recovers', () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final runtime = _ToggleFipsRuntime();
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    var endpointLoads = 0;
    final host = DriveHost(
      fipsRuntime: runtime,
      identityLoader: () async => owner,
      endpointLoader: () async {
        endpointLoads++;
        return 'http://${service.npub}.fips:7345';
      },
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );
    try {
      await host.configure(config);
      expect(host.listeningPort, isNotNull);
      runtime.change(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.listeningPort, isNull);
      expect(host.endpoint, isNull);
      expect(host.message, contains('FIPS is disabled'));
      await host.configure(config);
      await host.refreshPolicies();
      expect(endpointLoads, 1);
      runtime.change(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.listeningPort, isNotNull, reason: host.message);
      expect(endpointLoads, 2);
    } finally {
      host.dispose();
      await runtime.changes.close();
    }
  });

  test('disable cancels startup before an awaited endpoint can bind', () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final runtime = _ToggleFipsRuntime();
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final pendingEndpoint = Completer<String>();
    final endpointStarted = Completer<void>();
    final host = DriveHost(
      fipsRuntime: runtime,
      identityLoader: () async => owner,
      endpointLoader: () {
        endpointStarted.complete();
        return pendingEndpoint.future;
      },
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final configure = host.configure(AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    ));
    await endpointStarted.future;
    runtime.change(false);
    pendingEndpoint.complete('http://${service.npub}.fips:7345');
    await configure;
    await Future<void>.delayed(Duration.zero);
    expect(host.listeningPort, isNull);
    expect(host.endpoint, isNull);
    expect(host.message, contains('FIPS is disabled'));
    host.dispose();
    await runtime.changes.close();
  });

  test('default host identity storage uses non-data-protection macOS keychain',
      () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final previousStoragePlatform = FlutterSecureStoragePlatform.instance;
    final previousTargetPlatform = debugDefaultTargetPlatformOverride;
    final storage = _RecordingSecureStoragePlatform({});
    FlutterSecureStoragePlatform.instance = storage;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final host = DriveHost(
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );

    try {
      await host.configure(config);

      expect(host.listeningPort, isNotNull, reason: host.message);
      expect(storage.reads, hasLength(1));
      expect(storage.reads.single.key, DriveHost.hostIdentityStorageKey);
      expect(
          storage.reads.single.options['usesDataProtectionKeychain'], 'false');
      expect(storage.writes, hasLength(1));
      expect(storage.writes.single.key, DriveHost.hostIdentityStorageKey);
      expect(
          storage.writes.single.options['usesDataProtectionKeychain'], 'false');
      expect(storage.data[DriveHost.hostIdentityStorageKey], isNotNull);
    } finally {
      await host.stop();
      host.dispose();
      debugDefaultTargetPlatformOverride = previousTargetPlatform;
      FlutterSecureStoragePlatform.instance = previousStoragePlatform;
    }
  });

  test('default host identity storage preserves an existing host key',
      () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final previousStoragePlatform = FlutterSecureStoragePlatform.instance;
    final previousTargetPlatform = debugDefaultTargetPlatformOverride;
    final existing = NostrCrypto.generateIdentity();
    final storage = _RecordingSecureStoragePlatform({
      DriveHost.hostIdentityStorageKey: existing.nsec,
    });
    FlutterSecureStoragePlatform.instance = storage;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final host = DriveHost(
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );

    try {
      await host.configure(config);

      expect(host.listeningPort, isNotNull, reason: host.message);
      expect(storage.writes, isEmpty);
      expect(storage.data[DriveHost.hostIdentityStorageKey], existing.nsec);
    } finally {
      await host.stop();
      host.dispose();
      debugDefaultTargetPlatformOverride = previousTargetPlatform;
      FlutterSecureStoragePlatform.instance = previousStoragePlatform;
    }
  });

  test('publish signs the normalized Tower registration contract', () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    Map<String, dynamic>? capturedPayload;
    String? capturedUrl;
    String? capturedMethod;
    String? capturedSecret;
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
      towerRequest: (url, method, secret, payload) async {
        capturedUrl = url;
        capturedMethod = method;
        capturedSecret = secret;
        capturedPayload = payload;
        return {
          'share': {'revision': 1}
        };
      },
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );
    final share = <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000001',
      'root': '/tmp/root',
      'tower': config.towerUrl,
      'workspace_id': config.workspaceId,
      'owner_npub': owner.npub,
      'name': '  Folder  ',
      'host_name': '  Desktop  ',
      'audience': 'private',
      'enabled': true,
      'published': false,
      'revision': 0,
    };

    try {
      await host.configure(config);
      await host.publish(share);

      final payload = capturedPayload!;
      final registration = Map<String, dynamic>.from(payload)
        ..remove('host_proof');
      expect(capturedUrl,
          'https://tower.example/api/v4/flightdeck-pg/workspaces/workspace/drive/shares/${share['id']}');
      expect(capturedMethod, 'PUT');
      expect(capturedSecret, owner.nsec);
      expect(registration, {
        'name': 'Folder',
        'host_name': 'Desktop',
        'host_npub': service.npub,
        'endpoint': 'http://${service.npub}.fips:7345',
        'audience': 'private',
        'enabled': true,
        'previous_revision': 0,
      });
      final proof = payload['host_proof'] as Map<String, dynamic>;
      expect(proof['kind'], 27235);
      expect(proof['content'], '');
      expect(proof['pubkey'], service.publicKeyHex);
      expect(proof['tags'], [
        ['protocol', 'fips-drive-register-v1'],
        ['u', capturedUrl],
        ['owner', owner.npub],
        [
          'payload',
          sha256.convert(utf8.encode(jsonEncode(registration))).toString()
        ],
      ]);
      expect(share['name'], 'Folder');
      expect(share['host_name'], 'Desktop');
      expect(share['published'], isTrue);
      expect(host.registrationStatus(share), 'Sharing');
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  test('publish preserves selected share and surfaces Tower status code',
      () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
      towerRequest: (url, method, secret, payload) async {
        throw const DriveTowerException(
            400, {'code': 'invalid_host_proof'}, '');
      },
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );
    final share = <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000002',
      'root': '/tmp/root',
      'tower': config.towerUrl,
      'workspace_id': config.workspaceId,
      'owner_npub': owner.npub,
      'name': 'Folder',
      'host_name': 'Desktop',
      'audience': 'private',
      'enabled': true,
      'published': false,
      'revision': 0,
    };

    try {
      await host.configure(config);

      await expectLater(
          host.publish(share),
          throwsA(isA<DriveTowerException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.safeMessage, 'safeMessage',
                  'Tower returned HTTP 400 (invalid_host_proof)')));
      expect(share['published'], isFalse);
      expect(share['last_registration_error'],
          'Tower returned HTTP 400 (invalid_host_proof)');
      expect(host.registrationStatus(share),
          'Registration failed: Tower returned HTTP 400 (invalid_host_proof)');
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  test('publish requires the direct owner identity before Tower mutation',
      () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final other = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    var towerCalls = 0;
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
      towerRequest: (url, method, secret, payload) async {
        towerCalls += 1;
        return {
          'share': {'revision': 1}
        };
      },
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: other.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );
    final share = <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000003',
      'root': '/tmp/root',
      'tower': config.towerUrl,
      'workspace_id': config.workspaceId,
      'owner_npub': owner.npub,
      'name': 'Folder',
      'host_name': 'Desktop',
      'audience': 'private',
      'enabled': true,
      'published': false,
      'revision': 0,
    };

    try {
      await host.configure(config);

      await expectLater(
          host.publish(share),
          throwsA(isA<DriveRegistrationException>().having(
              (e) => e.message,
              'message',
              'Drive registration requires the unlocked owner identity for this workspace.')));
      expect(towerCalls, 0);
      expect(share['published'], isFalse);
      expect(share['last_registration_error'],
          'Drive registration requires the unlocked owner identity for this workspace.');
      expect(host.registrationStatus(share),
          'Registration failed: Drive registration requires the unlocked owner identity for this workspace.');
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  test('startup passively reports missing FIPS identity and retry recovers',
      () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final statuses = <FipsRuntimeStatus>[
      const FipsRuntimeStatus(
        state: FipsRuntimeState.controlAccessPending,
        detail: 'control permission pending',
      ),
      FipsRuntimeStatus(
        state: FipsRuntimeState.running,
        detail: 'FIPS is running.',
        nodeNpub: service.npub,
      ),
    ];
    final host = DriveHost(
      fipsRuntime: _FakeFipsRuntimeService(statuses),
      identityLoader: () async => service,
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );

    try {
      await host.configure(config);
      expect(host.listeningPort, isNull);
      expect(host.endpoint, isNull);
      expect(host.message, contains('cannot read this machine FIPS identity'));
      expect(host.message, contains('Log out and back in, then retry'));
      expect(host.message, isNot(contains('authorization')));

      await host.configure(config, repair: true);
      expect(host.endpoint, 'http://${service.npub}.fips:7345');
      expect(host.listeningPort, isNotNull);
      expect(host.message,
          'Hosting selected folders while Nostr Browser is running and unlocked.');
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  testWidgets('Drive screen disposal stops its owned host', (tester) async {
    final host = _CountingDriveHost();

    await tester.pumpWidget(MaterialApp(
      home: DriveScreen(
        config: AppConfig.defaults(),
        bridge: NativeCoreBridge(),
        host: host,
      ),
    ));
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(host.configureCount, 1);
    expect(host.disposed, isTrue);
  });

  test('refused Tower request records copyable sanitized diagnostics',
      () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'http://127.0.0.1:$port/capability-secret',
      workspaceId: 'workspace-secret-123',
    );
    final share = <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000004',
      'root': '/private/root/must/not/appear',
      'tower': config.towerUrl,
      'workspace_id': config.workspaceId,
      'owner_npub': owner.npub,
      'name': 'Folder',
      'host_name': 'Desktop',
      'audience': 'private',
      'enabled': true,
      'published': false,
      'revision': 0,
    };

    try {
      await host.configure(config);

      await expectLater(host.publish(share), throwsA(isA<SocketException>()));

      final diagnostics = host.diagnosticsText;
      expect(diagnostics, contains('wmapp-drive-diagnostics-v1'));
      expect(diagnostics, contains('stage="connect"'));
      expect(diagnostics, contains('method="PUT"'));
      expect(diagnostics, contains('target_host="127.0.0.1"'));
      expect(diagnostics, contains('target_port=$port'));
      expect(diagnostics, contains('error="connection_refused"'));
      expect(diagnostics, contains('route="<unknown>"'));
      expect(diagnostics, isNot(contains(owner.nsec)));
      expect(diagnostics, isNot(contains('/private/root')));
      expect(diagnostics, isNot(contains('capability-secret')));
      expect(diagnostics, isNot(contains('workspace-secret-123')));
      expect(diagnostics, isNot(contains(share['id'])));
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  test('FIPS Tower request dials the configured FIPS endpoint port', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final tower = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final observed = Completer<HttpRequest>();
    tower.listen((request) async {
      if (!observed.isCompleted) observed.complete(request);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'share': {'revision': 7}
      }));
      await request.response.close();
    });
    final towerOrigin = 'http://${service.npub}.fips:${tower.port}';
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
      socketConnector: (address, port) =>
          Socket.startConnect(InternetAddress.loopbackIPv4, port),
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: towerOrigin,
      workspaceId: 'workspace',
    );
    final share = <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000005',
      'root': '/tmp/root',
      'tower': config.towerUrl,
      'workspace_id': config.workspaceId,
      'owner_npub': owner.npub,
      'name': 'Folder',
      'host_name': 'Desktop',
      'audience': 'private',
      'enabled': true,
      'published': false,
      'revision': 0,
    };

    try {
      await host.configure(config);
      await host.publish(share);

      final request = await observed.future.timeout(const Duration(seconds: 2));
      expect(
          request.headers.value('host'), '${service.npub}.fips:${tower.port}');
      expect(share['published'], isTrue);
      expect(host.diagnosticsText, contains('fips_mesh_port=${tower.port}'));
      expect(host.diagnosticsText, contains('status=200'));
    } finally {
      await host.stop();
      host.dispose();
      await tower.close(force: true);
    }
  });

  test('FIPS Tower URL without explicit port fails before default-port dial',
      () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    var socketCalls = 0;
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
      socketConnector: (address, port) {
        socketCalls += 1;
        return Socket.startConnect(address, port);
      },
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'http://${service.npub}.fips',
      workspaceId: 'workspace',
    );
    final share = <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000006',
      'root': '/tmp/root',
      'tower': config.towerUrl,
      'workspace_id': config.workspaceId,
      'owner_npub': owner.npub,
      'name': 'Folder',
      'host_name': 'Desktop',
      'audience': 'private',
      'enabled': true,
      'published': false,
      'revision': 0,
    };

    try {
      await host.configure(config);

      await expectLater(
          host.publish(share),
          throwsA(isA<DriveRegistrationException>().having(
              (e) => e.message,
              'message',
              'Invalid FIPS Tower URL. Use http://<node-npub>.fips:<port>.')));

      expect(socketCalls, 0);
      expect(share['last_registration_error'],
          'Invalid FIPS Tower URL. Use http://<node-npub>.fips:<port>.');
      expect(host.diagnosticsText, contains('error="invalid_fips_tower_url"'));
      expect(host.diagnosticsText, contains('target_port=80'));
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  test('delayed Tower diagnostics are dropped after workspace change',
      () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final tower = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final release = Completer<void>();
    tower.listen((request) async {
      await release.future;
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'code': 'delayed_secret_code'}));
      await request.response.close();
    });
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () async => 'http://${service.npub}.fips:7345',
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'http://127.0.0.1:${tower.port}',
      workspaceId: 'workspace-a',
    );
    final share = <String, dynamic>{
      'id': '00000000-0000-4000-8000-000000000007',
      'root': '/tmp/root',
      'tower': config.towerUrl,
      'workspace_id': config.workspaceId,
      'owner_npub': owner.npub,
      'name': 'Folder',
      'host_name': 'Desktop',
      'audience': 'private',
      'enabled': true,
      'published': false,
      'revision': 0,
    };

    try {
      await host.configure(config);
      final pending =
          expectLater(host.publish(share), throwsA(isA<HttpException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await host.configure(config.copyWith(workspaceId: 'workspace-b'));
      release.complete();
      await pending;

      expect(host.diagnosticsText, isNot(contains('delayed_secret_code')));
      expect(host.diagnosticsText, isNot(contains('workspace-a')));
      expect(host.diagnosticsText, isNot(contains('status=500')));
    } finally {
      if (!release.isCompleted) release.complete();
      await host.stop();
      host.dispose();
      await tower.close(force: true);
    }
  });

  testWidgets('Drive diagnostics panel copies bounded sanitized text',
      (tester) async {
    final host = _DiagnosticsDriveHost();
    final config = AppConfig.defaults().copyWith(
      deviceNpub: 'npub-owner',
      deviceSecret: 'nsec-secret',
      towerUrl: 'https://tower.example?token=secret',
      workspaceId: 'workspace',
    );
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
        return null;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DriveScreen(
          config: config,
          bridge: NativeCoreBridge(),
          host: host,
        ),
      ),
    ));
    await tester.pump();
    host.seedDiagnostic();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('drive-diagnostics-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('drive-copy-diagnostics')));
    await tester.pump();

    expect(copied, hasLength(1));
    expect(copied.single, contains('stage="connect"'));
    expect(copied.single, contains('target_port=443'));
    expect(copied.single, isNot(contains('nsec-secret')));
    expect(copied.single, isNot(contains('/Users/')));

    await tester.tap(find.byKey(const ValueKey('drive-clear-diagnostics')));
    await tester.pump();
    expect(host.hasDiagnostics, isFalse);
  });

  test('initial configure is passive; explicit retry uses readiness repair',
      () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final runtime = _FakeFipsRuntimeService([
      const FipsRuntimeStatus(
        state: FipsRuntimeState.installRequired,
        detail: 'mesh setup is missing or outdated',
      ),
      FipsRuntimeStatus(
        state: FipsRuntimeState.running,
        detail: 'FIPS is running.',
        nodeNpub: service.npub,
      ),
    ]);
    final host = DriveHost(
      fipsRuntime: runtime,
      identityLoader: () async => service,
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );

    try {
      await host.configure(config);
      expect(runtime.inspectCount, 1);
      expect(runtime.ensureReadyCount, 0);
      expect(host.listeningPort, isNull);
      expect(host.message, contains('FIPS is not ready'));

      await host.configure(config, repair: true);
      expect(runtime.ensureReadyCount, 1);
      expect(host.listeningPort, isNotNull);
      expect(host.message,
          'Hosting selected folders while Nostr Browser is running and unlocked.');
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  test('stale failed configure does not stop a newer active host', () async {
    SharedPreferences.setMockInitialValues({DriveHost.storageKey: '[]'});
    final owner = NostrCrypto.generateIdentity();
    final service = NostrCrypto.generateIdentity();
    final firstEndpoint = Completer<String>();
    var endpointCalls = 0;
    final host = DriveHost(
      identityLoader: () async => service,
      endpointLoader: () {
        endpointCalls += 1;
        if (endpointCalls == 1) return firstEndpoint.future;
        return Future.value('http://${service.npub}.fips:7345');
      },
      listenAddress: InternetAddress.loopbackIPv4,
      listenPort: 0,
    );
    final config = AppConfig.defaults().copyWith(
      deviceNpub: owner.npub,
      deviceSecret: owner.nsec,
      towerUrl: 'https://tower.example',
      workspaceId: 'workspace',
    );

    try {
      final stale = host.configure(config);
      await Future<void>.delayed(Duration.zero);
      await host.configure(config.copyWith(workspaceId: 'workspace-new'));
      final activePort = host.listeningPort;
      expect(activePort, isNotNull);

      firstEndpoint.completeError(const SocketException('stale bind failure'));
      await stale;

      expect(host.listeningPort, activePort);
      expect(host.message,
          'Hosting selected folders while Nostr Browser is running and unlocked.');
    } finally {
      await host.stop();
      host.dispose();
    }
  });

  test(
      'live loopback host reads selected files; denies private members, replay/restart, stale policy and local disable',
      () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    final root = await Directory.systemTemp.createTemp('drive-host-');
    final realRoot = await root.resolveSymbolicLinks();
    final bytes = List.generate(160000, (i) => i % 251);
    await File('$realRoot/file.bin').writeAsBytes(bytes);
    final owner = NostrCrypto.generateIdentity(),
        member = NostrCrypto.generateIdentity(),
        service = NostrCrypto.generateIdentity();
    final endpoint = 'http://${service.npub}.fips:7345';
    var now = DateTime.now();
    var unavailable = false, mismatch = false;
    var endpointReady = false;
    final share = <String, dynamic>{
      'id': 'share',
      'root': realRoot,
      'tower': 'https://tower.example',
      'workspace_id': 'workspace',
      'owner_npub': owner.npub,
      'name': 'Folder',
      'host_name': 'Desktop',
      'audience': 'private',
      'enabled': true,
      'revision': 1
    };
    SharedPreferences.setMockInitialValues({
      DriveHost.storageKey: jsonEncode([share])
    });
    final config = AppConfig.defaults().copyWith(
        deviceNpub: owner.npub,
        deviceSecret: owner.nsec,
        towerUrl: 'https://tower.example',
        workspaceId: 'workspace');
    DriveHost create() => DriveHost(
        identityLoader: () async => service,
        endpointLoader: () async {
          if (!endpointReady) throw StateError('starting');
          return endpoint;
        },
        listenAddress: InternetAddress.loopbackIPv4,
        listenPort: 0,
        helperPath:
            '${Directory.current.parent.path}/target/release/wmapp-drive-fs',
        now: () => now,
        towerRequest: (url, method, secret, payload) async {
          if (unavailable) throw const SocketException('offline');
          if (method == 'PUT') {
            return {
              'share': {'revision': 2}
            };
          }
          return {
            'workspace_id': 'workspace',
            'share': {
              'id': 'share',
              'host_npub': service.npub,
              'endpoint': mismatch ? 'http://different.fips:7345' : endpoint,
              'enabled': true
            },
            'allowed_npubs': [owner.npub],
            'policy_revision': 'one',
            'max_age_seconds': 900
          };
        });
    var host = create();
    await host.configure(config);
    expect(host.listeningPort, isNull);
    endpointReady = true;
    await host.configure(config);
    expect(host.listeningPort, isNotNull, reason: host.message);
    var sequence = 0;
    String auth(String path, NostrIdentity user) {
      final event = NostrCrypto.signEvent(secret: user.nsec, event: {
        'kind': 27235,
        'created_at': now.millisecondsSinceEpoch ~/ 1000,
        'content': '',
        'tags': [
          ['u', '$endpoint$path'],
          ['method', 'GET'],
          ['workspace', 'workspace'],
          ['share', 'share'],
          ['nonce', '${sequence++}'.padLeft(32, 'a')]
        ]
      });
      return 'Nostr ${base64Encode(utf8.encode(jsonEncode(event)))}';
    }

    final client = HttpClient();
    Future<(int, List<int>)> get(String path, String authorization) async {
      final r = await client
          .getUrl(Uri.parse('http://127.0.0.1:${host.listeningPort}$path'));
      r.headers.set('authorization', authorization);
      final response = await r.close();
      final data = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      return (response.statusCode, data);
    }

    try {
      const path = '/drive/v1/share/list?path=';
      final signed = auth(path, owner);
      final listing = await get(path, signed);
      expect(listing.$1, 200);
      final value = jsonDecode(utf8.decode(listing.$2));
      expect(value['entries'][0]['name'], 'file.bin');
      expect((await get(path, auth(path, member))).$1, 403);
      final replayBefore = (await SharedPreferences.getInstance())
          .getString('wingman.drive.replay.v1');
      // Distinct valid-but-unauthorized signatures must not reserve memory/disk
      // entries or deny a subsequent owner request.
      for (var attempt = 0; attempt < 64; attempt++) {
        expect((await get(path, auth(path, member))).$1, 403);
      }
      expect(
          (await SharedPreferences.getInstance())
              .getString('wingman.drive.replay.v1'),
          replayBefore);
      expect((await get(path, auth(path, owner))).$1, 200);

      expect((await get(path, signed)).$1, 401);
      final read =
          '/drive/v1/share/read?path=file.bin&revision=${value['entries'][0]['revision']}';
      expect((await get(read, auth(read, owner))).$2, bytes);
      await File('$realRoot/file.bin').writeAsString('changed');
      expect((await get(read, auth(read, owner))).$1, 409);
      await host.stop();
      host.dispose();
      host = create();
      await host.configure(config);
      expect((await get(path, signed)).$1, 401);
      unavailable = true;
      now = now.add(const Duration(minutes: 15));
      await host.refreshPolicies();
      expect((await get(path, auth(path, owner))).$1, 403);
      unavailable = false;
      await host.refreshPolicies();
      expect((await get(path, auth(path, owner))).$1, 200);
      mismatch = true;
      await host.refreshPolicies();
      expect((await get(path, auth(path, owner))).$1, 403);
      final prefs = await SharedPreferences.getInstance();
      expect(
          (jsonDecode(prefs.getString(DriveHost.storageKey)!)[0] as Map)
              .containsKey('policy'),
          false);
      await host.stop();
      host.dispose();
      unavailable = true;
      host = create();
      await host.configure(config);
      expect((await get(path, auth(path, owner))).$1, 403);
      mismatch = false;
      unavailable = false;
      await host.refreshPolicies();
      expect((await get(path, auth(path, owner))).$1, 200);
      await host.disable(host.visible.first);
      expect((await get(path, auth(path, owner))).$1, 404);
    } finally {
      client.close(force: true);
      await host.stop();
      host.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _SecureStorageCall {
  const _SecureStorageCall(this.key, this.options);

  final String key;
  final Map<String, String> options;

  @override
  String toString() => '_SecureStorageCall($key, $options)';
}

class _RecordingSecureStoragePlatform extends TestFlutterSecureStoragePlatform {
  _RecordingSecureStoragePlatform(super.data);

  final reads = <_SecureStorageCall>[];
  final writes = <_SecureStorageCall>[];

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) {
    reads.add(_SecureStorageCall(key, Map<String, String>.from(options)));
    return super.read(key: key, options: options);
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) {
    writes.add(_SecureStorageCall(key, Map<String, String>.from(options)));
    return super.write(key: key, value: value, options: options);
  }
}

class _CountingDriveHost extends DriveHost {
  var configureCount = 0;
  var disposed = false;

  @override
  Future<void> configure(AppConfig config, {bool repair = false}) async {
    configureCount += 1;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _DiagnosticsDriveHost extends DriveHost {
  var _text = '';

  @override
  bool get supported => true;

  @override
  bool get hasDiagnostics => _text.isNotEmpty;

  @override
  String get diagnosticsText => _text;

  void seedDiagnostic() {
    _text = 'wmapp-drive-diagnostics-v1 os=macos\n'
        'ts="2026-09-12T00:00:00.000Z" stage="connect" '
        'method="PUT" route="/api/v4/flightdeck-pg/workspaces/<workspace>/drive/shares/<share>" '
        'target_host="tower.example" target_port=443 error="connection_refused"';
    notifyListeners();
  }

  @override
  Future<void> configure(AppConfig config, {bool repair = false}) async {}

  @override
  void clearDiagnostics({bool notify = true}) {
    _text = '';
    if (notify) notifyListeners();
  }

  @override
  Future<void> stop() async {}
}

class _FakeFipsRuntimeService extends FipsRuntimeService {
  _FakeFipsRuntimeService(this.statuses)
      : super(
          isMacOS: true,
          fileExists: (_) async => true,
        );

  final List<FipsRuntimeStatus> statuses;
  var inspectCount = 0;
  var ensureReadyCount = 0;

  FipsRuntimeStatus _nextStatus() {
    if (statuses.length > 1) return statuses.removeAt(0);
    return statuses.single;
  }

  @override
  Future<FipsRuntimeStatus> inspect() async {
    inspectCount += 1;
    return _nextStatus();
  }

  @override
  Future<FipsRuntimeStatus> ensureReadyForAppAccess() async {
    ensureReadyCount += 1;
    return _nextStatus();
  }
}

class _ToggleFipsRuntime extends FipsRuntimeService {
  bool enabled = true;
  final changes = StreamController<bool>.broadcast(sync: true);
  @override
  Future<bool> get isEnabled async => enabled;
  @override
  Stream<bool> get enabledChanges => changes.stream;
  void change(bool value) {
    enabled = value;
    changes.add(value);
  }
}
