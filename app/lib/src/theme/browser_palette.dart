/// Framework-independent brand values shared by Flutter and the new-tab HTML.
abstract final class BrowserPalette {
  static const frame = 0xFF291C3D;
  static const activeTab = 0xFF513568;
  static const lavender = 0xFFF1E8FF;
  static const purple = 0xFF7040AA;
  static const paper = 0xFFFFFBF5;
  static const ink = 0xFF30213F;
  static const orange = 0xFFFFAE68;
  static const outline = 0xFF8C739E;

  static String css(int colour) =>
      '#${(colour & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  static String get cssVariables => {
        'frame': frame,
        'active': activeTab,
        'lavender': lavender,
        'purple': purple,
        'paper': paper,
        'ink': ink,
        'orange': orange,
        'outline': outline,
      }.entries.map((entry) => '--${entry.key}:${css(entry.value)}').join(';');
}
