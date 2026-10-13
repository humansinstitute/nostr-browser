import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/app_config.dart';
import 'package:wingman_app/src/core/flight_deck_update_models.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';
import 'package:wingman_app/src/features/status/status_screen.dart';

void main() {
  testWidgets(
      'Flight Deck update controls reflect apply, failure, retry, and rollback states',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final updates = _FakeUpdateController(_makeSnapshot(
      phase: FlightDeckUpdatePhase.available,
      active: 'Build 100 (packaged)',
      available: 'Build 101 (ota-test)',
    ));
    var reloads = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatusScreen(
          config: AppConfig.defaults(),
          bridge: _FakeBridge(),
          flightDeckUpdates: updates,
          onFlightDeckChanged: () => reloads++,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Build 101 (ota-test)'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('flight-deck-apply-update')), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('flight-deck-apply-update')));
    await tester.tap(find.byKey(const ValueKey('flight-deck-apply-update')));
    await tester.pumpAndSettle();

    expect(find.text('Build 101 (ota-test)'), findsOneWidget);
    expect(find.byKey(const ValueKey('flight-deck-rollback-update')),
        findsOneWidget);
    expect(reloads, 1);

    updates.fail();
    await tester.pump();
    expect(
        find.byKey(const ValueKey('flight-deck-update-error')), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

    updates.restoreActive();
    await tester.pump();
    await tester.ensureVisible(
        find.byKey(const ValueKey('flight-deck-rollback-update')));
    await tester.tap(find.byKey(const ValueKey('flight-deck-rollback-update')));
    await tester.pumpAndSettle();
    expect(find.text('Roll back Flight Deck?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Roll back'));
    await tester.pumpAndSettle();

    expect(updates.snapshot.activeVersion, 'Build 100 (packaged)');
    expect(reloads, 2);
  });
}

FlightDeckUpdateSnapshot _makeSnapshot({
  required FlightDeckUpdatePhase phase,
  required String active,
  String previous = '',
  String available = '',
  String error = '',
}) {
  return FlightDeckUpdateSnapshot(
    phase: phase,
    packagedVersion: 'Build 100 (packaged)',
    activeVersion: active,
    previousVersion: previous,
    availableVersion: available,
    failedVersion: error.isEmpty ? '' : 'Build 102',
    message: phase.name,
    error: error,
    lastCheckAt: DateTime.utc(2026, 8, 26),
    lastSuccessAt: null,
    lastFailureAt: error.isEmpty ? null : DateTime.utc(2026, 8, 26),
    enabled: true,
    busy: false,
  );
}

class _FakeUpdateController extends FlightDeckUpdateController {
  _FakeUpdateController(this._snapshot);

  FlightDeckUpdateSnapshot _snapshot;

  @override
  String? get activeRootPath => null;

  @override
  FlightDeckUpdateSnapshot get snapshot => _snapshot;

  @override
  Future<void> applyAvailable() async {
    _snapshot = _snapshotCopy(
      phase: FlightDeckUpdatePhase.active,
      active: 'Build 101 (ota-test)',
      previous: 'Build 100 (packaged)',
      available: '',
    );
    notifyListeners();
  }

  void fail() {
    _snapshot = _snapshotCopy(
      phase: FlightDeckUpdatePhase.failed,
      active: 'Build 101 (ota-test)',
      previous: 'Build 100 (packaged)',
      available: '',
      error: 'checksum mismatch',
    );
    notifyListeners();
  }

  void restoreActive() {
    _snapshot = _snapshotCopy(
      phase: FlightDeckUpdatePhase.active,
      active: 'Build 101 (ota-test)',
      previous: 'Build 100 (packaged)',
      available: '',
    );
    notifyListeners();
  }

  @override
  Future<void> rollback() async {
    _snapshot = _snapshotCopy(
      phase: FlightDeckUpdatePhase.active,
      active: 'Build 100 (packaged)',
      previous: 'Build 101 (ota-test)',
      available: '',
    );
    notifyListeners();
  }

  FlightDeckUpdateSnapshot _snapshotCopy({
    required FlightDeckUpdatePhase phase,
    required String active,
    required String previous,
    required String available,
    String error = '',
  }) {
    return _makeSnapshot(
      phase: phase,
      active: active,
      previous: previous,
      available: available,
      error: error,
    );
  }

  @override
  Future<void> checkForUpdates({bool applyAutomatically = false}) async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<void> reportServeFailure(String message) async {}
}

class _FakeBridge extends NativeCoreBridge {
  @override
  Future<CoreStatus> status(AppConfig config) async {
    return const CoreStatus(
      ok: true,
      towerUrl: '',
      appNpub: '',
      workspaceId: '',
      channelId: '',
      deviceNpub: '',
      deviceConfigured: false,
      latestSync: 'not checked',
      message: 'Native status loaded.',
    );
  }
}
