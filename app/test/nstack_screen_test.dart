import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/features/nstack/nstack_access.dart';
import 'package:wingman_app/src/features/nstack/nstack_discovery.dart';
import 'package:wingman_app/src/features/nstack/nstack_models.dart';
import 'package:wingman_app/src/features/nstack/nstack_recovery.dart';
import 'package:wingman_app/src/features/nstack/nstack_screen.dart';
import 'package:wingman_app/src/features/nstack/nstack_store.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('management surface shows host and revokes origin discovery',
      (tester) async {
    const identity = 'npub-test';
    final registry = NStackRegistryStore();
    await registry.addOrUpdate(
      identity,
      NStackEntry(
        id: 'stack-a',
        name: 'Personal NStack',
        url: 'https://host.example',
        catalogueStatus: NStackCatalogueStatus(
          checkedAt: DateTime.utc(2026, 10, 19),
          catalogue: NStackServiceCatalogue(
            generatedAt: DateTime.utc(2026, 10, 19),
            fetchedAt: DateTime.now().toUtc(),
            cacheTtlSeconds: 3600,
            services: [
              NStackService(
                id: 'tower',
                kind: 'tower',
                endpoint: 'https://host.example',
                version: '1.0.0',
                protocols: const ['https'],
                capabilities: const ['storage.private'],
                availability: NStackServiceAvailability.available,
                checkedAt: DateTime.utc(2026, 10, 19),
                actionable: true,
              ),
              NStackService(
                id: 'relay',
                kind: 'nostr_relay',
                endpoint: 'wss://relay.example',
                version: '0.10.0',
                protocols: const ['nostr-relay'],
                capabilities: const ['events.query'],
                availability: NStackServiceAvailability.unavailable,
                checkedAt: DateTime.utc(2026, 10, 19),
                actionable: true,
              ),
            ],
          ),
        ),
      ),
      makeActive: true,
      makeHost: true,
    );
    final grants = NStackGrantStore();
    final access =
        NStackAccessService(registryStore: registry, grantStore: grants);
    await access.disclose(
      identity: identity,
      origin: 'https://ambulando.example',
      stackInternalIds: const ['stack-a'],
      includeWorkspaces: false,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NStackScreen(
          config: AppConfig.defaults().copyWith(
            deviceNpub: identity,
            devicePublicKeyHex: '1'.padLeft(64, '0'),
            deviceSecret: 'secret-present',
          ),
          registryStore: registry,
          grantStore: grants,
          accessService: access,
          discoveryService: NStackDiscoveryService(registryStore: registry),
          recoveryService: NStackRecoveryService(
            registryStore: registry,
            storage: _NoStorage(),
            relay: _NoRelay(),
          ),
          onRegistryChanged: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Personal NStack'), findsOneWidget);
    expect(find.text('https://host.example\n0 workspace(s)'), findsOneWidget);
    expect(find.textContaining('Tower — available'), findsOneWidget);
    expect(find.textContaining('Relay — unavailable'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('https://ambulando.example'), 300);
    expect(find.textContaining('https://ambulando.example'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Revoke'));
    await tester.pumpAndSettle();
    expect(await grants.list(identity), isEmpty);
    expect(find.text('No website discovery or capability grants.'),
        findsOneWidget);
  });
}

class _NoStorage implements NStackStorageClient {
  @override
  Future<List<int>> fetch(
          {required String hostUrl,
          required String objectId,
          required String secret,
          required String expectedSha256}) =>
      throw UnimplementedError();

  @override
  Future<String> upload(
          {required String hostUrl,
          required String ownerNpub,
          required String secret,
          required List<int> bytes,
          required String sha256}) =>
      throw UnimplementedError();
}

class _NoRelay implements NStackRecoveryRelay {
  @override
  List<String> get relays => const ['wss://relay.example'];

  @override
  Future<List<Map<String, dynamic>>> fetchHints(String publicKeyHex) async =>
      const [];

  @override
  Future<NStackRelayPublishResult> publish(Map<String, dynamic> event) =>
      throw UnimplementedError();
}
