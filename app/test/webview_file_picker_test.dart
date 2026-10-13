import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:wingman_app/src/features/browser/webview_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizes comma-separated MIME types and common extensions', () {
    expect(
      normalizeAndroidAcceptTypes(
        const [' image/*, .PNG ', '.jpg', 'application/pdf'],
      ),
      const ['image/*', 'image/png', 'image/jpeg', 'application/pdf'],
    );
  });

  test('falls back to all documents for empty or unusable accept values', () {
    expect(normalizeAndroidAcceptTypes(const []), const ['*/*']);
    expect(
      normalizeAndroidAcceptTypes(const ['', '.unknown', 'not-a-mime']),
      const ['*/*'],
    );
  });

  test('maps WebView multiple-selection policy to native channel arguments',
      () {
    const params = FileSelectorParams(
      isCaptureEnabled: false,
      acceptTypes: ['image/*'],
      filenameHint: 'avatar.png',
      mode: FileSelectorMode.openMultiple,
    );

    final request = AndroidFilePickerRequest.fromSelectorParams(params);

    expect(
      request.toChannelArguments(),
      const {
        'acceptTypes': ['image/*'],
        'allowsMultipleSelection': true,
        'filenameHint': 'avatar.png',
      },
    );
  });

  test('routes picker requests over the native channel and returns URIs',
      () async {
    const channel = MethodChannel('test/webview_file_picker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickFiles');
      expect(call.arguments, {
        'acceptTypes': ['image/*'],
        'allowsMultipleSelection': false,
        'filenameHint': null,
      });
      return ['content://picker/avatar'];
    });

    final result = await pickAndroidWebViewFiles(
      const FileSelectorParams(
        isCaptureEnabled: false,
        acceptTypes: ['image/*'],
        mode: FileSelectorMode.open,
      ),
      channel: channel,
    );

    expect(result, const ['content://picker/avatar']);
  });

  test('maps native picker failure to WebView cancellation', () async {
    const channel = MethodChannel('test/webview_file_picker_failure');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'picker_unavailable'),
    );

    final result = await pickAndroidWebViewFiles(
      const FileSelectorParams(
        isCaptureEnabled: false,
        acceptTypes: [],
        mode: FileSelectorMode.open,
      ),
      channel: channel,
    );

    expect(result, isEmpty);
  });
}
