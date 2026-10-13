import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const _filePickerChannel = MethodChannel(
  'com.wingmanbefree.wingman_app/webview_file_picker',
);

/// Installs the platform-specific file-input path without changing navigation.
Future<void> configureWebViewFilePicker(
  WebViewController controller, {
  MethodChannel channel = _filePickerChannel,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  final platformController = controller.platform;
  if (platformController is! AndroidWebViewController) return;

  await platformController.setOnShowFileSelector(
    (params) => pickAndroidWebViewFiles(params, channel: channel),
  );
}

@visibleForTesting
Future<List<String>> pickAndroidWebViewFiles(
  FileSelectorParams params, {
  required MethodChannel channel,
}) async {
  final request = AndroidFilePickerRequest.fromSelectorParams(params);
  try {
    final selected = await channel.invokeListMethod<String>(
      'pickFiles',
      request.toChannelArguments(),
    );
    return selected ?? const <String>[];
  } on PlatformException {
    return const <String>[];
  }
}

@immutable
class AndroidFilePickerRequest {
  const AndroidFilePickerRequest({
    required this.acceptTypes,
    required this.allowsMultipleSelection,
    this.filenameHint,
  });

  factory AndroidFilePickerRequest.fromSelectorParams(
    FileSelectorParams params,
  ) {
    return AndroidFilePickerRequest(
      acceptTypes: normalizeAndroidAcceptTypes(params.acceptTypes),
      allowsMultipleSelection: params.mode == FileSelectorMode.openMultiple,
      filenameHint: params.filenameHint,
    );
  }

  final List<String> acceptTypes;
  final bool allowsMultipleSelection;
  final String? filenameHint;

  Map<String, Object?> toChannelArguments() => {
        'acceptTypes': acceptTypes,
        'allowsMultipleSelection': allowsMultipleSelection,
        'filenameHint': filenameHint,
      };
}

List<String> normalizeAndroidAcceptTypes(Iterable<String> rawTypes) {
  final normalized = <String>{};
  for (final rawType in rawTypes) {
    for (final part in rawType.split(',')) {
      final candidate = part.trim().toLowerCase();
      if (candidate.isEmpty) continue;
      final mimeType = _extensionMimeTypes[candidate] ?? candidate;
      if (_validMimeType.hasMatch(mimeType)) normalized.add(mimeType);
    }
  }
  return normalized.isEmpty
      ? const ['*/*']
      : normalized.toList(growable: false);
}

final _validMimeType = RegExp(r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+*-]+$');

const _extensionMimeTypes = <String, String>{
  '.csv': 'text/csv',
  '.gif': 'image/gif',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
  '.jpeg': 'image/jpeg',
  '.jpg': 'image/jpeg',
  '.json': 'application/json',
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain',
  '.webp': 'image/webp',
  '.zip': 'application/zip',
};
