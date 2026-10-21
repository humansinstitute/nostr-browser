import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:wingman_app/src/features/setup/setup_screen.dart';

class _StatusRuntime implements FipsAndroidRuntimeChannel {
  _StatusRuntime(this.state);
  final String state;

  @override
  Future<Map<String, dynamic>> inspect() async => {
        'state': state,
        'detail': state == 'running'
            ? 'FIPS is ready for private connections.'
            : 'FIPS needs attention before private connections can open.',
        if (state == 'running') 'nodeNpub': 'npub1diagnosticfixture',
      };
  @override
  Future<Map<String, dynamic>> start({bool repair = false}) async => inspect();
  @override
  Future<Map<String, dynamic>> stop() async => inspect();
  @override
  Future<Map<String, dynamic>> peerStatus() async => const {};
  @override
  Future<Map<String, dynamic>> probe(String npub) async => const {};
  @override
  Future<Map<String, dynamic>> exportDiagnostics() async => const {};
  @override
  Future<Map<String, dynamic>> clearDiagnostics() async => const {};
  @override
  Future<Map<String, dynamic>> journalEvent(String eventCode) async => const {};
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  FipsRuntimeService runtime(String state) => FipsRuntimeService(
        isMacOS: false,
        isLinux: false,
        isAndroid: true,
        androidRuntime: _StatusRuntime(state),
      );

  Future<void> pumpSettings(
    WidgetTester tester, {
    required AppConfig config,
    required ValueChanged<AppConfig> onConfigChanged,
    String fipsState = 'running',
    String localFlightDeckUrl = 'http://localhost:47831',
    Future<void> Function()? onClearBrowserData,
    Size size = const Size(1000, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SetupScreen(
          key: ValueKey('settings-$fipsState'),
          config: config,
          localFlightDeckUrl: localFlightDeckUrl,
          fipsRuntime: runtime(fipsState),
          onConfigChanged: onConfigChanged,
          onClearBrowserData: onClearBrowserData ?? () async {},
          onOpenFipsApp: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings uses browser-focused information architecture',
      (tester) async {
    final config = AppConfig.defaults().copyWith(
      towerUrl: 'https://legacy-tower.example/path',
      appNpub: 'legacy-app',
      workspaceId: 'legacy-workspace',
      workspaceServiceNpub: 'legacy-service',
      channelId: 'legacy-channel',
      registrationSecret: 'legacy-registration-secret',
      deviceNpub: 'npub-device',
      devicePublicKeyHex: 'device-hex',
      rememberNip98Approvals: false,
      displayExperimentalFlightDeckDriveSync: true,
    );
    await pumpSettings(tester, config: config, onConfigChanged: (_) {});

    for (final heading in [
      'Settings',
      'FIPS status',
      'Site permissions',
      'Privacy & browser data',
      'Advanced diagnostics',
    ]) {
      expect(find.text(heading), findsOneWidget);
    }
    for (final removed in [
      'Tower URL',
      'Flight Deck App npub',
      'Workspace ID',
      'Workspace service npub',
      'Default Channel ID',
      'Registration signer key',
      'Register device',
      'Validate channel',
      'Device npub',
      'Device public key hex',
      'Remember NIP-98 approvals',
      'Display experimental future Flight Deck Drive sync',
    ]) {
      expect(find.text(removed), findsNothing);
    }
    expect(find.text('https://legacy-tower.example'), findsOneWidget);
    expect(find.textContaining('Legacy site permission'), findsOneWidget);
  });

  testWidgets('site permissions explain exact origins and revoke one safely',
      (tester) async {
    var config = AppConfig.defaults().copyWith(
      trustedOrigins: [
        'https://alpha.example/path',
        'https://beta.example',
      ],
    );
    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return Scaffold(
          body: SetupScreen(
            config: config,
            localFlightDeckUrl: 'http://localhost:47831',
            fipsRuntime: runtime('running'),
            onConfigChanged: (next) => rebuild(() => config = next),
            onClearBrowserData: () async {},
            onOpenFipsApp: (_) {},
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();

    expect(find.text('http://localhost:47831'), findsOneWidget);
    expect(find.text('https://alpha.example'), findsOneWidget);
    expect(find.text('https://beta.example'), findsOneWidget);
    expect(find.textContaining('exact origins'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('revoke-site-permission-http://localhost:47831'),
      ),
      findsNothing,
    );

    final revoke = find.byKey(
      const ValueKey('revoke-site-permission-https://alpha.example'),
    );
    await reveal(tester, revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    expect(find.text('Revoke site permission?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();

    expect(config.trustedOrigins, ['https://beta.example']);
    expect(find.text('https://alpha.example'), findsNothing);
    expect(find.text('https://beta.example'), findsOneWidget);
  });

  testWidgets('empty permissions state is clear', (tester) async {
    await pumpSettings(
      tester,
      config: AppConfig.defaults(),
      localFlightDeckUrl: '',
      onConfigChanged: (_) {},
    );
    expect(find.text('No sites have permission yet.'), findsOneWidget);
  });

  testWidgets('FIPS normal state is concise and action state offers repair',
      (tester) async {
    await pumpSettings(
      tester,
      config: AppConfig.defaults(),
      onConfigChanged: (_) {},
    );
    expect(find.text('running'), findsOneWidget);
    expect(find.text('Node: npub1diagnosticfixture'), findsNothing);
    expect(find.text('Refresh'), findsNothing);
    expect(find.text('Install or repair'), findsNothing);

    await pumpSettings(
      tester,
      config: AppConfig.defaults(),
      onConfigChanged: (_) {},
      fipsState: 'failed',
    );
    expect(find.text('failed'), findsOneWidget);
    expect(find.text('Install or repair'), findsOneWidget);
  });

  testWidgets('privacy reset keeps destructive confirmation', (tester) async {
    var clears = 0;
    await pumpSettings(
      tester,
      config: AppConfig.defaults(),
      onConfigChanged: (_) {},
      onClearBrowserData: () async => clears += 1,
      size: const Size(390, 800),
    );
    await reveal(tester, find.byKey(const ValueKey('reset-browser-data')));
    await tester.tap(find.byKey(const ValueKey('reset-browser-data')));
    await tester.pumpAndSettle();
    expect(find.text('Reset browser data?'), findsOneWidget);
    expect(find.textContaining('sites may sign out'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(clears, 1);
  });

  testWidgets('advanced disclosure contains controls and revokes old pairing',
      (tester) async {
    var config = AppConfig.defaults().copyWith(
      flightDeckUrl: 'https://old.example/workspace',
      trustedOrigins: ['https://old.example'],
    );
    await pumpSettings(
      tester,
      config: config,
      onConfigChanged: (next) => config = next,
      size: const Size(390, 900),
    );
    await reveal(tester, find.byKey(const ValueKey('advanced-diagnostics')));
    expect(find.text('Private relay diagnostics'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('advanced-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('Private relay diagnostics'), findsOneWidget);
    expect(find.text('Node: npub1diagnosticfixture'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('External Flight Deck URL'), findsOneWidget);

    await reveal(
        tester, find.byKey(const ValueKey('external-flight-deck-url')));
    await tester.enterText(
      find.byKey(const ValueKey('external-flight-deck-url')),
      'https://new.example/workspace',
    );
    await reveal(
      tester,
      find.byKey(const ValueKey('save-external-flight-deck')),
    );
    await tester.tap(find.byKey(const ValueKey('save-external-flight-deck')));
    await tester.pumpAndSettle();

    expect(config.flightDeckUrl, 'https://new.example/workspace');
    expect(config.trustedOrigins, isEmpty);
    expect(
        find.textContaining('Previous pairings were revoked.'), findsOneWidget);
  });
}
