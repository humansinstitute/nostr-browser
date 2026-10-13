import 'package:flutter/services.dart';

/// Routes frame-verified native messages without addJavascriptInterface.
/// Install before loading the first page; a false result must fail closed.
abstract final class GraspAndroidChannel {
  static const _channel = MethodChannel('wingman/grasp_android');
  static final _receivers = <int, void Function(String, String)>{};
  static bool _listening = false;

  static Future<bool> install({
    required int webViewIdentifier,
    required void Function(String channel, String message) onMessage,
  }) async {
    if (!_listening) {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'message' || call.arguments is! Map) return;
        final args = call.arguments as Map;
        final id = args['webViewIdentifier'];
        final name = args['channel'];
        final message = args['message'];
        if (id is int && name is String && message is String) {
          _receivers[id]?.call(name, message);
        }
      });
      _listening = true;
    }
    _receivers[webViewIdentifier] = onMessage;
    try {
      final supported = await _channel.invokeMethod<bool>('install', {
            'webViewIdentifier': webViewIdentifier,
          }) ??
          false;
      if (!supported && identical(_receivers[webViewIdentifier], onMessage)) {
        _receivers.remove(webViewIdentifier);
      }
      return supported && identical(_receivers[webViewIdentifier], onMessage);
    } on PlatformException {
      _receivers.remove(webViewIdentifier);
      return false;
    } on MissingPluginException {
      _receivers.remove(webViewIdentifier);
      return false;
    }
  }

  /// Load native-generated home content with a fixed native-owned origin and
  /// history URL, so WebView's frame and current-origin metadata agree.
  static Future<void> loadHomeHtml({
    required int webViewIdentifier,
    required String html,
  }) =>
      _channel.invokeMethod<void>('loadHomeHtml', {
        'webViewIdentifier': webViewIdentifier,
        'html': html,
      });

  static Future<void> remove(int webViewIdentifier) async {
    _receivers.remove(webViewIdentifier);
    try {
      await _channel.invokeMethod<void>('remove', {
        'webViewIdentifier': webViewIdentifier,
      });
    } on PlatformException {
      // A detached engine cannot deliver further native messages.
    } on MissingPluginException {
      // Unsupported hosts never registered a listener.
    }
  }
}
