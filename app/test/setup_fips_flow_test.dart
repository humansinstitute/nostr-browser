import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/setup/setup_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final npub = 'npub1${List.filled(58, 'q').join()}';
  const compatibleAttestation = '{"schema":2,"fipsVersion":"0.5.0",'
      '"rendezvousApp":"wingman-fips-poc-v1",'
      '"nostrShareLocalCandidates":true,"lanEnabled":true,'
      '"lanScope":"wingman-fips-poc-v1","tunEnabled":true,'
      '"dnsEnabled":true,"udpAdvertiseOnNostr":true,'
      '"udpAcceptConnections":true,"udpOutboundOnly":false,'
      '"bootstrapPeerNpub":"${FipsRuntimeService.bootstrapPeerNpub}",'
      '"bootstrapPeerAddress":"${FipsRuntimeService.bootstrapPeerAddress}"}';

  testWidgets('persisted desktop off is shown and HTTPS remains explained',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {FipsRuntimeService.enabledPreferenceKey: false});
    final runtime = FipsRuntimeService(
        isMacOS: true,
        processRunner: (_, __) =>
            throw StateError('disabled must not run processes'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SetupScreen(
      config: AppConfig.defaults(),
      bridge: NativeCoreBridge(),
      fipsRuntime: runtime,
      onConfigChanged: (_) {},
      onClearBrowserData: () async {},
      onOpenFipsApp: (_) {},
    ))));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('fips-enabled'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.text('disabled'), findsOneWidget);
    expect(find.textContaining('HTTPS browsing works when disabled'),
        findsOneWidget);
    expect(find.text('Install or repair'), findsNothing);
  });

  testWidgets(
      'Open FIPS app activates bundled runtime once and remains safe to repeat',
      (tester) async {
    // Reproduce a laptop with upstream v0.5.0 already running but configured
    // by an older WMapp that did not write the versioned mesh attestation.
    var installed = true;
    var attested = false;
    var authorizationRuns = 0;
    final opened = <String>[];
    var config = AppConfig.defaults();
    var browserVisible = false;
    late StateSetter rebuild;
    final runtime = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (path) async =>
          path == '/bundle/fips.pkg' ||
          path.endsWith(FipsRuntimeService.configurationScriptName) ||
          (path == '/usr/local/bin/fipsctl' && installed),
      readTextFile: (_) async => attested ? compatibleAttestation : null,
      processRunner: (executable, arguments) async {
        if (executable == '/usr/bin/osascript') {
          authorizationRuns += 1;
          installed = true;
          attested = true;
          return ProcessResult(1, 0, 'installed', '');
        }
        if (arguments.contains('--version')) {
          return ProcessResult(2, 0, '0.5.0', '');
        }
        if (arguments.first == 'connect') {
          return ProcessResult(3, 0, '{}', '');
        }
        if (arguments == const ['show', 'peers']) {
          return ProcessResult(
            4,
            0,
            '{"peers":[{"npub":"${FipsRuntimeService.bootstrapPeerNpub}",'
                '"connectivity":"connected"}]}',
            '',
          );
        }
        return ProcessResult(
          5,
          0,
          '{"state":"Running","tun_state":"active",'
              '"persistent":true,"npub":"$npub"}',
          '',
        );
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: IndexedStack(
                index: browserVisible ? 1 : 0,
                children: [
                  SetupScreen(
                    config: config,
                    bridge: NativeCoreBridge(),
                    fipsRuntime: runtime,
                    onConfigChanged: (next) => rebuild(() => config = next),
                    onClearBrowserData: () async {},
                    onOpenFipsApp: (url) {
                      opened.add(url);
                      rebuild(() => browserVisible = true);
                    },
                  ),
                  const Center(child: Text('Embedded browser')),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> submitTarget() async {
      if (find.text('Open FIPS app').evaluate().isEmpty) {
        await tester.drag(find.byType(ListView), const Offset(0, 1000));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('Open FIPS app'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open FIPS app'));
      await tester.pumpAndSettle();
      final probe = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'Probe node before opening'),
      );
      expect(probe.value, isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('fips-app-target-field')),
        'http://$npub.fips:41005/',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
    }

    await submitTarget();
    expect(authorizationRuns, 1);
    expect(find.text('Trust this exact FIPS origin?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Trust and open'));
    await tester.pumpAndSettle();

    expect(opened, ['http://$npub.fips:41005/']);
    expect(config.trustedOrigins, ['http://$npub.fips:41005']);
    expect(browserVisible, isTrue);
    expect(tester.takeException(), isNull);

    rebuild(() => browserVisible = false);
    await tester.pumpAndSettle();
    await submitTarget();
    expect(authorizationRuns, 1);
    expect(opened, [
      'http://$npub.fips:41005/',
      'http://$npub.fips:41005/',
    ]);
    expect(browserVisible, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional probe failure can continue to exact-origin trust',
      (tester) async {
    final opened = <String>[];
    var config = AppConfig.defaults();
    late StateSetter rebuild;
    final runtime = FipsRuntimeService(
      bundledPackagePath: '/bundle/fips.pkg',
      isMacOS: true,
      fileExists: (_) async => true,
      readTextFile: (_) async => compatibleAttestation,
      processRunner: (_, arguments) async {
        if (arguments.contains('--version')) {
          return ProcessResult(1, 0, '0.5.0', '');
        }
        if (arguments.firstOrNull == 'probe') {
          return ProcessResult(2, 1, '{"verdict":"failed"}', '');
        }
        return ProcessResult(
          3,
          0,
          '{"state":"Running","tun_state":"active",'
              '"persistent":true,"npub":"$npub"}',
          '',
        );
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: SetupScreen(
                config: config,
                bridge: NativeCoreBridge(),
                fipsRuntime: runtime,
                onConfigChanged: (next) => rebuild(() => config = next),
                onClearBrowserData: () async {},
                onOpenFipsApp: opened.add,
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Open FIPS app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open FIPS app'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('fips-app-target-field')),
      'http://$npub.fips:41005/',
    );
    await tester.tap(
      find.widgetWithText(CheckboxListTile, 'Probe node before opening'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Node not confirmed yet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Open anyway'));
    await tester.pumpAndSettle();
    expect(find.text('Trust this exact FIPS origin?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Trust and open'));
    await tester.pumpAndSettle();

    expect(opened, ['http://$npub.fips:41005/']);
    expect(tester.takeException(), isNull);
  });
}
