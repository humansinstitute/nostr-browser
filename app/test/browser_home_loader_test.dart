import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/browser_screen.dart';

void main() {
  test('native home loader remains Android-only', () {
    expect(
      useAndroidHomeHtmlLoader(
        isAndroid: true,
        nativeWebViewIdentifier: 42,
      ),
      isTrue,
    );
    expect(
      useAndroidHomeHtmlLoader(
        isAndroid: false,
        nativeWebViewIdentifier: 42,
      ),
      isFalse,
      reason: 'WebKit identifiers must use WebViewController.loadHtmlString',
    );
    expect(
      useAndroidHomeHtmlLoader(
        isAndroid: true,
        nativeWebViewIdentifier: null,
      ),
      isFalse,
    );
  });
}
