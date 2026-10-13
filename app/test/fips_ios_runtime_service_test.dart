import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';
import 'fips_android_runtime_service_test.dart' show FakeAndroidFipsRuntime;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  FipsRuntimeService service(FakeAndroidFipsRuntime native) =>
      FipsRuntimeService(
        isMacOS: false,
        isLinux: false,
        isAndroid: false,
        isIOS: true,
        iosRuntime: native,
        processRunner: (_, __) =>
            throw StateError('iOS must not launch processes'),
      );
  test(
      'iPhone consent, coalesced start, authenticated readiness, stop and restart',
      () async {
    final native = FakeAndroidFipsRuntime()..startGate = Completer<void>();
    final runtime = service(native);
    expect((await runtime.inspect()).state, FipsRuntimeState.consentRequired);
    expect(runtime.authorizationDescription, contains('iPhone'));
    expect(runtime.supportsStop, isTrue);
    final first = runtime.ensureReadyForAppAccess();
    final second = runtime.ensureReadyForAppAccess();
    await Future<void>.delayed(Duration.zero);
    expect(native.startCalls, 1);
    native.startGate!.complete();
    expect((await first).isRunning, isTrue);
    expect((await second).isRunning, isTrue);
    expect(native.peerCalls, 1);
    expect((await runtime.stop()).state, FipsRuntimeState.disabled);
    expect((await runtime.ensureReadyForAppAccess()).state,
        FipsRuntimeState.disabled);
    await runtime.setEnabled(true);
    expect((await runtime.ensureReadyForAppAccess()).isRunning, isTrue);
    expect(native.startCalls, 2);
  });
  test('consent refusal and platform failure release operation for retry',
      () async {
    final native = FakeAndroidFipsRuntime()
      ..startStatus = {'state': 'failed', 'detail': 'VPN consent declined.'};
    final runtime = service(native);
    expect((await runtime.installOrRepair()).detail, contains('declined'));
    native.startError =
        PlatformException(code: 'startup', message: 'VPN startup failed.');
    expect((await runtime.installOrRepair()).state, FipsRuntimeState.failed);
    native.startError = null;
    native.startStatus = {'state': 'running', 'detail': 'Ready'};
    expect((await runtime.installOrRepair()).isRunning, isTrue);
  });
  test('iPhone diagnostics export and stale runtime inspection', () async {
    final native = FakeAndroidFipsRuntime();
    final runtime = service(native);
    expect(runtime.supportsDiagnosticsExport, isTrue);
    expect((await runtime.exportDiagnostics()).outcome,
        FipsDiagnosticsExportOutcome.success);
    native.inspectError = StateError('native extension exited');
    expect((await runtime.inspect()).state, FipsRuntimeState.failed);
  });
  test('iPhone running runtime routes probe through native channel', () async {
    final native = FakeAndroidFipsRuntime()
      ..status = const {
        'state': 'running',
        'detail': 'FIPS VPN is connected.',
      };
    final runtime = service(native);
    final npub = 'npub1${List.filled(58, 'q').join()}';

    final result = await runtime.probe(npub);

    expect(result.ok, isTrue);
    expect(result.detail, 'Probe completed: ok.');
    expect(native.probeCalls, 1);
    expect(native.lastProbeNpub, npub);
  });
}
