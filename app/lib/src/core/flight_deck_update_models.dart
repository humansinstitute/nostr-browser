import 'package:flutter/foundation.dart';

enum FlightDeckUpdatePhase {
  disabled,
  idle,
  checking,
  available,
  downloading,
  verifying,
  activating,
  active,
  incompatible,
  rollingBack,
  failed,
}

@immutable
class FlightDeckUpdateSnapshot {
  const FlightDeckUpdateSnapshot({
    required this.phase,
    required this.packagedVersion,
    required this.activeVersion,
    required this.previousVersion,
    required this.availableVersion,
    required this.failedVersion,
    required this.message,
    required this.error,
    required this.lastCheckAt,
    required this.lastSuccessAt,
    required this.lastFailureAt,
    required this.enabled,
    required this.busy,
  });

  factory FlightDeckUpdateSnapshot.disabled(
      {String message = 'Packaged Flight Deck only'}) {
    return FlightDeckUpdateSnapshot(
      phase: FlightDeckUpdatePhase.disabled,
      packagedVersion: 'packaged',
      activeVersion: 'packaged',
      previousVersion: '',
      availableVersion: '',
      failedVersion: '',
      message: message,
      error: '',
      lastCheckAt: null,
      lastSuccessAt: null,
      lastFailureAt: null,
      enabled: false,
      busy: false,
    );
  }

  final FlightDeckUpdatePhase phase;
  final String packagedVersion;
  final String activeVersion;
  final String previousVersion;
  final String availableVersion;
  final String failedVersion;
  final String message;
  final String error;
  final DateTime? lastCheckAt;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final bool enabled;
  final bool busy;

  bool get canCheck => enabled && !busy;
  bool get canApply => enabled && !busy && availableVersion.isNotEmpty;
  bool get canRollback => enabled && !busy && previousVersion.isNotEmpty;
}

abstract class FlightDeckUpdateController extends ChangeNotifier {
  FlightDeckUpdateSnapshot get snapshot;

  /// Absolute verified on-device root, or null to use packaged Flutter assets.
  String? get activeRootPath;

  Future<void> initialize();

  Future<void> checkForUpdates({bool applyAutomatically = false});

  Future<void> applyAvailable();

  Future<void> rollback();

  /// Called by the loopback server if the active downloaded build cannot be read.
  Future<void> reportServeFailure(String message);
}
