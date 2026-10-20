import 'package:flutter/services.dart';

class BrowserSnapshot {
  static const _channel = MethodChannel('wingman/browser_snapshot');
  static const _maxBytes = 4 * 1024 * 1024;

  static Future<Uint8List?> capture(int webViewIdentifier) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('capture', {
        'webViewIdentifier': webViewIdentifier,
        'width': 480,
      }).timeout(const Duration(seconds: 1), onTimeout: () => null);
      if (bytes == null || bytes.isEmpty || bytes.length > _maxBytes) {
        return null;
      }
      return bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
