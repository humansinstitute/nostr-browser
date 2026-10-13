import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../core/nostr_crypto.dart';

class AvatarUploadException implements Exception {
  const AvatarUploadException(this.message);
  final String message;
}

class ProfileAvatarUpload {
  static const maxInputBytes = 5 * 1024 * 1024;
  static const maxUploadBytes = 2 * 1024 * 1024;
  static const server = 'blossom.primal.net';

  ProfileAvatarUpload({
    ImagePicker? imagePicker,
    Future<XFile?> Function()? selectFile,
  })  : _imagePicker = imagePicker ?? ImagePicker(),
        _selectFile = selectFile ?? _pickFile;

  final ImagePicker _imagePicker;
  final Future<XFile?> Function() _selectFile;

  Future<Uint8List?> pick({int maxDimension = 512}) async {
    try {
      final file = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
          // Native resizing also converts HEIC to JPEG before Dart validation.
          // Avoid requesting library-wide access or original photo metadata.
          ? await _imagePicker.pickImage(
              source: ImageSource.gallery,
              maxWidth: maxDimension.toDouble(),
              maxHeight: maxDimension.toDouble(),
              imageQuality: 90,
              requestFullMetadata: false,
            )
          : await _selectFile();
      if (file == null) return null;
      if (await file.length() > maxInputBytes) {
        throw const AvatarUploadException(
            'Choose an image no larger than 5 MB.');
      }
      return await prepare(await file.readAsBytes(),
          maxDimension: maxDimension);
    } on AvatarUploadException {
      rethrow;
    } on PlatformException catch (error) {
      if (error.code == 'photo_access_denied' ||
          error.code == 'photo_access_restricted') {
        throw const AvatarUploadException(
          'Photo library access is unavailable. Check Nostr Browser permissions in Settings.',
        );
      }
      throw const AvatarUploadException(
        'Could not open or read the selected photo. Please retry.',
      );
    } on Exception {
      throw const AvatarUploadException(
        'Could not read this image. Try another photo.',
      );
    }
  }

  static Future<XFile?> _pickFile() => openFile(acceptedTypeGroups: const [
        XTypeGroup(label: 'Profile image', extensions: [
          'jpg',
          'jpeg',
          'png',
          'webp'
        ], mimeTypes: [
          'image/jpeg',
          'image/png',
          'image/webp'
        ], uniformTypeIdentifiers: [
          'public.jpeg',
          'public.png',
          'org.webmproject.webp'
        ]),
      ]);

  static Future<Uint8List> prepare(Uint8List bytes,
      {int maxDimension = 512}) async {
    if (maxDimension < 1 || maxDimension > 2048) {
      throw const AvatarUploadException('Invalid image dimensions.');
    }
    if (bytes.isEmpty || bytes.length > maxInputBytes) {
      throw const AvatarUploadException('Choose an image no larger than 5 MB.');
    }
    final png = bytes.length >= 8 &&
        bytes.take(8).join(',') == '137,80,78,71,13,10,26,10';
    final jpeg = bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    final webp = bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
    if (!png && !jpeg && !webp) {
      throw const AvatarUploadException('Choose a JPEG, PNG, or WebP image.');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width * descriptor.height > 40 * 1000 * 1000) {
          throw const AvatarUploadException(
              'Choose an image below 40 megapixels.');
        }
        final scale = math.min(
            1.0, maxDimension / math.max(descriptor.width, descriptor.height));
        final codec = await descriptor.instantiateCodec(
          targetWidth: math.max(1, (descriptor.width * scale).round()),
          targetHeight: math.max(1, (descriptor.height * scale).round()),
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            final data =
                await frame.image.toByteData(format: ui.ImageByteFormat.png);
            if (data == null || data.lengthInBytes > maxUploadBytes) {
              throw const AvatarUploadException(
                  'Image could not fit the 2 MB upload limit.');
            }
            return data.buffer
                .asUint8List(data.offsetInBytes, data.lengthInBytes);
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  Future<String> upload(Uint8List bytes,
      {required String secret,
      required String npub,
      http.Client? client}) async {
    if (bytes.isEmpty || bytes.length > maxUploadBytes) {
      throw const AvatarUploadException('Image exceeds the 2 MB upload limit.');
    }
    if (NostrCrypto.importIdentity(secret).npub != npub) {
      throw const AvatarUploadException(
          'Unlock the matching identity before uploading.');
    }
    final hash = sha256.convert(bytes).toString();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final event = NostrCrypto.signEvent(secret: secret, event: {
      'kind': 24242,
      'created_at': now - 1,
      'content': 'Upload profile image to Primal Blossom',
      'tags': [
        ['t', 'upload'],
        ['x', hash],
        ['server', server],
        ['expiration', '${now + 300}']
      ],
    });
    final transport = client ?? http.Client();
    try {
      // Primal currently requires standard padded Base64 (see its decode_b64).
      final request = http.Request('PUT', Uri.https(server, '/upload'))
        ..followRedirects = false
        ..headers.addAll({
          'Authorization':
              'Nostr ${base64Encode(utf8.encode(jsonEncode(event)))}',
          'Content-Type': 'image/png',
          'X-SHA-256': hash
        })
        ..bodyBytes = bytes;
      return await (() async {
        final response = await transport.send(request);
        if (response.statusCode != 200 && response.statusCode != 201) {
          throw AvatarUploadException(response.statusCode == 402
              ? 'Primal requires payment or additional storage for this upload.'
              : 'Primal rejected the upload (HTTP ${response.statusCode}). Please retry.');
        }
        final body = <int>[];
        await for (final chunk in response.stream) {
          body.addAll(chunk);
          if (body.length > 64 * 1024) {
            throw const FormatException('Oversized response');
          }
        }
        final descriptor =
            jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        final url = Uri.tryParse(descriptor['url'] as String? ?? '');
        if (descriptor['sha256'] != hash ||
            descriptor['size'] != bytes.length ||
            url == null ||
            url.scheme != 'https' ||
            url.host != server ||
            url.userInfo.isNotEmpty ||
            url.port != 443 ||
            !RegExp('^/$hash(?:\\.[a-zA-Z0-9]+)?\$').hasMatch(url.path)) {
          throw const AvatarUploadException(
              'Primal returned an invalid image receipt. Please retry.');
        }
        return url.toString();
      })()
          .timeout(const Duration(seconds: 60));
    } finally {
      if (client == null) transport.close();
    }
  }
}
