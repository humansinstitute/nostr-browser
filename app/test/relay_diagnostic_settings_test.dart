import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wingman_app/src/features/browser/relay_diagnostic_settings.dart';
import 'package:wingman_app/src/features/browser/relay_diagnostics.dart';

class _SupportPathProvider extends PathProviderPlatform {
  _SupportPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    RelayDiagnostics.enabled = false;
  });
  tearDown(() => RelayDiagnostics.enabled = false);

  test('missing and corrupt saved settings fail closed; choice persists',
      () async {
    final settings = RelayDiagnosticSettings();
    expect(await settings.load(), isFalse);
    await SharedPreferencesAsync()
        .setString(RelayDiagnosticSettings.key, 'not-a-boolean');
    expect(await settings.load(), isFalse);
    await settings.save(true);
    expect(await RelayDiagnosticSettings().load(), isTrue);
    await settings.save(false);
    expect(await RelayDiagnosticSettings().load(), isFalse);
  });

  test('wrong stored type fails closed', () async {
    await SharedPreferencesAsync().setBool(RelayDiagnosticSettings.key, true);
    expect(await RelayDiagnosticSettings().load(), isFalse);
  });

  test(
      'recording uses launch snapshot, writes nothing when off, and clears old files',
      () async {
    final root =
        await Directory.systemTemp.createTemp('relay-diagnostics-test-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _SupportPathProvider(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
    final file = File('${root.path}/wmapp-relay-diagnostics.jsonl');
    final settings = RelayDiagnosticSettings();
    final launchChoice = await settings.load();
    RelayDiagnostics.enabled = launchChoice;
    RelayDiagnostics.record('abcd1234', 'efgh5678', 'auth_sent');
    await RelayDiagnostics.pending;
    expect(await file.exists(), isFalse);

    await settings.save(true);
    expect(RelayDiagnostics.enabled, isFalse,
        reason: 'saving does not change the running process');
    RelayDiagnostics.record('abcd1234', 'efgh5678', 'auth_sent');
    await RelayDiagnostics.pending;
    expect(await file.exists(), isFalse);

    RelayDiagnostics.enabled = await RelayDiagnosticSettings().load();
    RelayDiagnostics.record('abcd1234', 'efgh5678', 'auth_sent');
    RelayDiagnostics.record('sensitive-url', 'efgh5678', 'auth_sent');
    await RelayDiagnostics.pending;
    expect(await file.exists(), isTrue);
    final trace = await file.readAsString();
    expect(trace, contains('auth_sent'));
    expect(trace, isNot(contains('sensitive-url')));
    expect(trace.trim().split('\n'), hasLength(1));

    await settings.save(false);
    expect(RelayDiagnostics.enabled, isTrue);
    RelayDiagnostics.enabled = await RelayDiagnosticSettings().load();
    RelayDiagnostics.record('abcd1234', 'efgh5678', 'eose_received');
    await RelayDiagnostics.pending;
    expect(await file.readAsString(), trace);
    await RelayDiagnostics.clear();
    expect(await file.exists(), isFalse);
  });
}
