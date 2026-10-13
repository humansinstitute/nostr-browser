import 'flight_deck_update_models.dart';

Future<FlightDeckUpdateController> createFlightDeckUpdateController() async {
  return DisabledFlightDeckUpdateController();
}

class DisabledFlightDeckUpdateController extends FlightDeckUpdateController {
  DisabledFlightDeckUpdateController({
    String message =
        'Over-the-wire Flight Deck updates are unavailable on this platform.',
  }) : _snapshot = FlightDeckUpdateSnapshot.disabled(message: message);

  final FlightDeckUpdateSnapshot _snapshot;

  @override
  String? get activeRootPath => null;

  @override
  FlightDeckUpdateSnapshot get snapshot => _snapshot;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> checkForUpdates({bool applyAutomatically = false}) async {}

  @override
  Future<void> applyAvailable() async {}

  @override
  Future<void> rollback() async {}

  @override
  Future<void> reportServeFailure(String message) async {}
}
