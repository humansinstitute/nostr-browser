import 'dart:async';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/core/flight_deck_update_manager.dart';
import 'src/core/local_flight_deck_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final flightDeckUpdates = await createFlightDeckUpdateController();
  final flightDeckServer = await LocalFlightDeckServer.start(
    updates: flightDeckUpdates,
  );
  runApp(WingmanApp(
    localFlightDeckUrl: flightDeckServer.url,
    flightDeckUpdates: flightDeckUpdates,
  ));
  unawaited(flightDeckUpdates.checkForUpdates(applyAutomatically: true));
}
