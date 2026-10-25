/// The retired embedded browser server owned this exact endpoint. Never infer
/// a built-in entry from its title or from an external application's URL.
bool isRetiredBundledAppUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri?.scheme == 'http' &&
      uri?.host == '127.0.0.1' &&
      uri?.port == 47831;
}
