import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/browser/relay_diagnostics.dart';
import 'package:wingman_app/src/features/setup/setup_screen.dart';

class DiagnosticsAndroidRuntime implements FipsAndroidRuntimeChannel {
  Map<String, dynamic> exportResult = const {
    'outcome': 'success',
    'detail': 'FIPS diagnostics exported.',
  };
  Object? exportError;
  Completer<void>? exportGate;
  int exportCalls = 0;
  int startCalls = 0;
  final journalEvents = <String>[];

  @override
  Future<Map<String, dynamic>> inspect() async => const {
        'state': 'failed',
        'detail': 'Embedded FIPS startup failed. Please retry.',
      };
  @override
  Future<Map<String, dynamic>> start({bool repair = false}) async {
    startCalls += 1;
    return const {
      'state': 'running',
      'detail': 'Embedded FIPS is running.',
    };
  }

  @override
  Future<Map<String, dynamic>> exportDiagnostics() async {
    exportCalls += 1;
    await exportGate?.future;
    if (exportError != null) throw exportError!;
    return exportResult;
  }

  @override
  Future<Map<String, dynamic>> clearDiagnostics() async => const {
        'outcome': 'success',
        'detail': 'FIPS diagnostics cleared.',
      };
  @override
  Future<Map<String, dynamic>> journalEvent(String eventCode) async {
    journalEvents.add(eventCode);
    return const {'outcome': 'success'};
  }

  @override
  Future<Map<String, dynamic>> peerStatus() async => const {'connected': true};
  @override
  Future<Map<String, dynamic>> probe(String npub) async => const {'ok': true};
  @override
  Future<Map<String, dynamic>> stop() async => const {'state': 'notInstalled'};
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  FipsRuntimeService runtime(DiagnosticsAndroidRuntime channel) =>
      FipsRuntimeService(
        isMacOS: false,
        isLinux: false,
        isAndroid: true,
        androidRuntime: channel,
      );

  Future<void> pumpSetup(
    WidgetTester tester,
    DiagnosticsAndroidRuntime channel,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SetupScreen(
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            fipsRuntime: runtime(channel),
            onConfigChanged: (_) {},
            onClearBrowserData: () async {},
            onOpenFipsApp: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Android failed state exposes export and keeps retry usable',
      (tester) async {
    final channel = DiagnosticsAndroidRuntime();
    await pumpSetup(tester, channel);

    expect(find.text('failed'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('fips-export-diagnostics')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('fips-clear-diagnostics')), findsOneWidget);
    expect(find.text('Install or repair'), findsOneWidget);

    await tester.tap(find.text('Install or repair'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(channel.startCalls, 1);
    expect(channel.journalEvents, contains('dart_ui_retry'));
  });

  for (final testCase in <({Map<String, dynamic> result, String feedback})>[
    (
      result: const {
        'outcome': 'success',
        'detail': 'FIPS diagnostics exported.',
      },
      feedback: 'FIPS diagnostics exported.',
    ),
    (
      result: const {
        'outcome': 'cancelled',
        'detail': 'Diagnostics export cancelled.',
      },
      feedback: 'Diagnostics export cancelled.',
    ),
    (
      result: const {
        'outcome': 'failed',
        'detail': 'Android could not write the diagnostics file. Please retry.',
      },
      feedback: 'Android could not write the diagnostics file. Please retry.',
    ),
  ]) {
    testWidgets('export reports ${testCase.result['outcome']} feedback',
        (tester) async {
      final channel = DiagnosticsAndroidRuntime()
        ..exportResult = testCase.result;
      await pumpSetup(tester, channel);
      await tester.tap(find.byKey(const ValueKey('fips-export-diagnostics')));
      await tester.pumpAndSettle();
      expect(find.text(testCase.feedback), findsOneWidget);
    });
  }

  testWidgets('unexpected export error is sanitized and retry remains enabled',
      (tester) async {
    final channel = DiagnosticsAndroidRuntime()
      ..exportError = StateError('nsec1private Authorization token');
    await pumpSetup(tester, channel);
    await tester.tap(find.byKey(const ValueKey('fips-export-diagnostics')));
    await tester.pumpAndSettle();

    expect(find.textContaining('failed unexpectedly'), findsOneWidget);
    expect(find.textContaining('nsec1private'), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('fips-export-diagnostics')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('duplicate export taps invoke native channel only once',
      (tester) async {
    final channel = DiagnosticsAndroidRuntime()..exportGate = Completer<void>();
    await pumpSetup(tester, channel);
    final export = find.byKey(const ValueKey('fips-export-diagnostics'));

    await tester.tap(export);
    await tester.pump();
    await tester.tap(export, warnIfMissed: false);
    await tester.pump();
    expect(channel.exportCalls, 1);
    expect(find.text('Exporting…'), findsOneWidget);

    channel.exportGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('FIPS diagnostics exported.'), findsOneWidget);
    expect(find.text('Install or repair'), findsOneWidget);
  });

  testWidgets('unsupported platform hides diagnostics controls',
      (tester) async {
    final service = FipsRuntimeService(
      isMacOS: false,
      isLinux: true,
      isAndroid: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SetupScreen(
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            fipsRuntime: service,
            onConfigChanged: (_) {},
            onClearBrowserData: () async {},
            onOpenFipsApp: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fips-export-diagnostics')), findsNothing);
  });

  testWidgets('relay switch shows saved choice and restart boundary',
      (tester) async {
    var saved = false;
    RelayDiagnostics.enabled = false;
    addTearDown(() => RelayDiagnostics.enabled = false);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, update) {
          return SetupScreen(
            config: AppConfig.defaults(),
            bridge: NativeCoreBridge(),
            fipsRuntime: runtime(DiagnosticsAndroidRuntime()),
            relayDiagnosticsSaved: saved,
            relayDiagnosticsAtLaunch: false,
            onRelayDiagnosticsChanged: (enabled) async {
              update(() => saved = enabled);
            },
            onConfigChanged: (_) {},
            onClearBrowserData: () async {},
            onOpenFipsApp: (_) {},
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
    final switchFinder =
        find.byKey(const ValueKey('private-relay-diagnostics'));
    await tester.scrollUntilVisible(switchFinder, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    expect(find.text('Restart WMapp to apply'), findsNothing);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
    expect(find.text('Restart WMapp to apply'), findsOneWidget);
    expect(RelayDiagnostics.enabled, isFalse);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    expect(find.text('Restart WMapp to apply'), findsNothing);
  });
}
