import 'flight_deck_update_models.dart';

class LocalFlightDeckServer {
  static const origin = '';

  static Future<LocalFlightDeckServer> start({
    FlightDeckUpdateController? updates,
  }) async {
    return LocalFlightDeckServer();
  }

  String get url => '';
}
