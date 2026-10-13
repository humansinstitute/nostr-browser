import 'package:shared_preferences/shared_preferences.dart';

/// The saved choice is read once at launch. Invalid or unavailable data fails closed.
class RelayDiagnosticSettings {
  RelayDiagnosticSettings({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const key = 'wingman.browser.private_relay_diagnostics.v1';
  final SharedPreferencesAsync _preferences;

  Future<bool> load() async {
    try {
      return await _preferences.getString(key) == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> save(bool enabled) =>
      _preferences.setString(key, enabled ? 'true' : 'false');
}
