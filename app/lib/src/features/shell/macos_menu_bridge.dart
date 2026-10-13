import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const macOSMenuChannelName = 'au.com.otherstuff.wingman/menu';
const showWingmanMenuMethod = 'showWingmanMenu';

class MacOSMenuBridge {
  MacOSMenuBridge({
    this.channel = const MethodChannel(macOSMenuChannelName),
  });

  final MethodChannel channel;
  bool _listening = false;

  void listen(VoidCallback onShowWingmanMenu) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == showWingmanMenuMethod) {
        onShowWingmanMenu();
      }
    });
  }

  void dispose() {
    if (!_listening) return;
    channel.setMethodCallHandler(null);
    _listening = false;
  }
}
