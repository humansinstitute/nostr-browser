import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wingman_app/src/core/fips_runtime_service.dart';

class FakeAndroidFipsRuntime implements FipsAndroidRuntimeChannel {
  Map<String, dynamic> status = const {
    'state': 'consentRequired',
    'detail': 'VPN consent required.',
  };
  Map<String, dynamic> startStatus = const {
    'state': 'running',
    'detail': 'Embedded FIPS is running.',
    'nodeNpub': 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq',
  };
  bool bootstrapConnected = true;
  int inspectCalls = 0;
  int startCalls = 0;
  int peerCalls = 0;
  int probeCalls = 0;
  int exportCalls = 0;
  String? lastProbeNpub;
  final journalEvents = <String>[];
  Completer<void>? startGate;
  Object? inspectError;
  Object? startError;
  Object? exportError;
  Completer<void>? exportGate;
  Map<String, dynamic> exportResult = const {
    'outcome': 'success',
    'detail': 'FIPS diagnostics exported.'
  };

  @override
  Future<Map<String, dynamic>> inspect() async {
    inspectCalls += 1;
    inspectError?.letThrow();
    return status;
  }

  @override
  Future<Map<String, dynamic>> start({bool repair = false}) async {
    startCalls += 1;
    await startGate?.future;
    startError?.letThrow();
    status = startStatus;
    return startStatus;
  }

  @override
  Future<Map<String, dynamic>> peerStatus() async {
    peerCalls += 1;
    return {
      'connected': bootstrapConnected,
      'detail': bootstrapConnected ? 'connected' : 'waiting',
    };
  }

  @override
  Future<Map<String, dynamic>> probe(String npub) async {
    probeCalls += 1;
    lastProbeNpub = npub;
    return const {
      'ok': true,
      'detail': 'Probe completed: ok.',
    };
  }

  @override
  Future<Map<String, dynamic>> stop() async {
    status = const {'state': 'notInstalled', 'detail': 'Stopped.'};
    return status;
  }

  @override
  Future<Map<String, dynamic>> exportDiagnostics() async {
    exportCalls += 1;
    await exportGate?.future;
    exportError?.letThrow();
    return exportResult;
  }

  @override
  Future<Map<String, dynamic>> clearDiagnostics() async =>
      const {'outcome': 'success', 'detail': 'FIPS diagnostics cleared.'};

  @override
  Future<Map<String, dynamic>> journalEvent(String eventCode) async {
    journalEvents.add(eventCode);
    return const {'outcome': 'success', 'detail': 'recorded'};
  }
}

extension on Object {
  Never letThrow() => throw this;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  FipsRuntimeService service(FakeAndroidFipsRuntime channel) =>
      FipsRuntimeService(
        isMacOS: false,
        isLinux: false,
        isAndroid: true,
        androidRuntime: channel,
      );

  test('off/on waits for stale native start cleanup before a new owner',
      () async {
    final channel = FakeAndroidFipsRuntime()..startGate = Completer<void>();
    final runtime = service(channel);
    final starting = runtime.installOrRepair();
    await Future<void>.delayed(Duration.zero);
    expect(channel.startCalls, 1);
    await runtime.stop();
    final enabling = runtime.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(await runtime.isEnabled, isFalse);
    channel.startGate!.complete();
    expect((await starting).state, FipsRuntimeState.disabled);
    await enabling;
    expect(await runtime.isEnabled, isTrue);
    expect(channel.status['state'], 'notInstalled');
    channel.startGate = null;
    expect((await runtime.ensureReadyForAppAccess()).isRunning, isTrue);
    expect(channel.startCalls, 2);
  });

  test('maps Android VPN consent state without desktop process inspection',
      () async {
    final channel = FakeAndroidFipsRuntime();
    final status = await service(channel).inspect();

    expect(status.state, FipsRuntimeState.consentRequired);
    expect(channel.inspectCalls, 1);
  });

  test('coalesces exact app-link startup into one VPN consent operation',
      () async {
    final channel = FakeAndroidFipsRuntime()..startGate = Completer<void>();
    final runtime = service(channel);

    final first = runtime.ensureReadyForAppAccess();
    final second = runtime.ensureReadyForAppAccess();
    await Future<void>.delayed(Duration.zero);
    expect(channel.startCalls, 1);

    channel.startGate!.complete();
    final statuses = await Future.wait([first, second]);
    expect(statuses.every((status) => status.isRunning), isTrue);
    expect(channel.startCalls, 1);
    expect(channel.peerCalls, 1);
  });

  test('surfaces VPN consent cancellation and does not wait for bootstrap',
      () async {
    final channel = FakeAndroidFipsRuntime()
      ..startStatus = const {
        'state': 'failed',
        'detail': 'Android VPN consent was cancelled.',
      };

    final status = await service(channel).ensureReadyForAppAccess();

    expect(status.state, FipsRuntimeState.failed);
    expect(status.detail, contains('cancelled'));
    expect(channel.peerCalls, 0);
  });

  test('uses Android native probe and stop paths', () async {
    final channel = FakeAndroidFipsRuntime()
      ..status = const {
        'state': 'running',
        'detail': 'Embedded FIPS is running.',
      };
    final runtime = service(channel);
    final npub = 'npub1${List.filled(58, 'q').join()}';

    expect((await runtime.probe(npub)).ok, isTrue);
    expect((await runtime.stop()).state, FipsRuntimeState.disabled);
  });

  test('unexpected Android inspection errors become recoverable failures',
      () async {
    final channel = FakeAndroidFipsRuntime()
      ..inspectError = StateError('private channel payload');
    final runtime = service(channel);

    final first = await runtime.ensureReadyForAppAccess();
    expect(first.state, FipsRuntimeState.failed);
    expect(first.detail, contains('Please retry'));
    expect(first.detail, isNot(contains('private channel payload')));

    channel.inspectError = null;
    channel.status = channel.startStatus;
    final retry = await runtime.ensureReadyForAppAccess();
    expect(retry.state, FipsRuntimeState.running);
  });

  test('unexpected Android start errors clear operation state for retry',
      () async {
    final channel = FakeAndroidFipsRuntime()
      ..startError = ArgumentError('sensitive start detail');
    final runtime = service(channel);

    final first = await runtime.installOrRepair();
    expect(first.state, FipsRuntimeState.failed);
    expect(first.detail, contains('Please retry'));
    expect(first.detail, isNot(contains('sensitive start detail')));

    channel.startError = null;
    final retry = await runtime.installOrRepair();
    expect(retry.state, FipsRuntimeState.running);
    expect(channel.startCalls, 2);
  });

  test('maps diagnostics method-channel success cancellation and failure',
      () async {
    final channel = FakeAndroidFipsRuntime();
    final runtime = service(channel);

    expect((await runtime.exportDiagnostics()).outcome,
        FipsDiagnosticsExportOutcome.success);
    channel.exportResult = const {
      'outcome': 'cancelled',
      'detail': 'Diagnostics export cancelled.',
    };
    expect((await runtime.exportDiagnostics()).outcome,
        FipsDiagnosticsExportOutcome.cancelled);
    channel.exportResult = const {
      'outcome': 'failed',
      'detail': 'Android could not write the diagnostics file. Please retry.',
    };
    final failed = await runtime.exportDiagnostics();
    expect(failed.outcome, FipsDiagnosticsExportOutcome.failed);
    expect(failed.detail, contains('Please retry'));
    expect(channel.journalEvents, everyElement('dart_export_requested'));
  });

  test('unexpected diagnostics method-channel error is private and retryable',
      () async {
    final channel = FakeAndroidFipsRuntime()
      ..exportError = StateError('Authorization: Nostr private-token');
    final runtime = service(channel);

    final failed = await runtime.exportDiagnostics();
    expect(failed.outcome, FipsDiagnosticsExportOutcome.failed);
    expect(failed.detail, contains('unexpectedly'));
    expect(failed.detail, isNot(contains('private-token')));

    channel.exportError = null;
    expect((await runtime.exportDiagnostics()).outcome,
        FipsDiagnosticsExportOutcome.success);
  });

  test('duplicate diagnostics export calls invoke native channel once',
      () async {
    final channel = FakeAndroidFipsRuntime()..exportGate = Completer<void>();
    final runtime = service(channel);
    final first = runtime.exportDiagnostics();
    await Future<void>.delayed(Duration.zero);

    final duplicate = await runtime.exportDiagnostics();
    expect(duplicate.outcome, FipsDiagnosticsExportOutcome.failed);
    expect(duplicate.detail, contains('already in progress'));
    expect(channel.exportCalls, 1);

    channel.exportGate!.complete();
    expect((await first).outcome, FipsDiagnosticsExportOutcome.success);
  });

  test('unsupported platforms do not advertise diagnostics export', () async {
    final runtime = FipsRuntimeService(
      isMacOS: false,
      isLinux: true,
      isAndroid: false,
    );
    expect(runtime.supportsDiagnosticsExport, isFalse);
    expect((await runtime.exportDiagnostics()).outcome,
        FipsDiagnosticsExportOutcome.failed);
  });
}
