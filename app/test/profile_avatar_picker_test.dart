import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wingman_app/src/features/browser/profile_avatar_upload.dart';

class FakePhotoPicker extends ImagePicker {
  XFile? file;
  Exception? error;
  int calls = 0;
  double expectedDimension = 512;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    calls++;
    expect(source, ImageSource.gallery);
    expect(maxWidth, expectedDimension);
    expect(maxHeight, expectedDimension);
    expect(imageQuality, 90);
    expect(requestFullMetadata, isFalse);
    if (error != null) throw error!;
    return file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePhotoPicker picker;
  late ProfileAvatarUpload uploader;
  late Uint8List png;
  var fileCalls = 0;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    picker = FakePhotoPicker();
    fileCalls = 0;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(800, 400);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
    uploader = ProfileAvatarUpload(
      imagePicker: picker,
      selectFile: () async {
        fileCalls++;
        return XFile.fromData(png, name: 'synthetic.png');
      },
    );
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
      'background selection retains more resolution within existing byte limits',
      () async {
    picker.expectedDimension = 1920;
    picker.file = XFile.fromData(png, name: 'background.png');
    final bytes = await uploader.pick(maxDimension: 1920);
    final codec = await ui.instantiateImageCodec(bytes!);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 800);
    expect(frame.image.height, 400);
    frame.image.dispose();
    codec.dispose();
  });

  test('iPhone and iPad use gallery and normalize the selected image',
      () async {
    picker.file = XFile.fromData(png, name: 'converted-library-photo.jpg');
    final result = await uploader.pick();
    expect(picker.calls, 1);
    expect(fileCalls, 0);
    final codec = await ui.instantiateImageCodec(result!);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 512);
    expect(frame.image.height, 256);
    expect(result.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    frame.image.dispose();
    codec.dispose();
  });

  test('gallery cancellation returns null without opening Files', () async {
    expect(await uploader.pick(), isNull);
    expect(fileCalls, 0);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.android
  ]) {
    test('$platform retains file selection', () async {
      debugDefaultTargetPlatformOverride = platform;
      expect(await uploader.pick(), isNotNull);
      expect(fileCalls, 1);
      expect(picker.calls, 0);
    });
  }

  test('Files cancellation returns null', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(
        await ProfileAvatarUpload(selectFile: () async => null).pick(), isNull);
  });

  for (final code in [
    'photo_access_denied',
    'photo_access_restricted',
    'already_active',
    'invalid_image',
    'channel-error'
  ]) {
    test('gallery $code provides actionable error without raw platform details',
        () async {
      picker.error = PlatformException(code: code, message: 'private path');
      await expectLater(
          uploader.pick(),
          throwsA(isA<AvatarUploadException>().having(
              (e) => e.message, 'message', isNot(contains('private path')))));
      expect(fileCalls, 0);
    });
  }

  test('oversized converted library image retains byte limit', () async {
    picker.file =
        XFile.fromData(Uint8List(ProfileAvatarUpload.maxInputBytes + 1));
    await expectLater(
        uploader.pick(),
        throwsA(isA<AvatarUploadException>()
            .having((e) => e.message, 'message', contains('5 MB'))));
  });

  test('unreadable selected file becomes a user-facing error', () async {
    picker.file = XFile('/nonexistent/synthetic-avatar-test.png');
    await expectLater(uploader.pick(), throwsA(isA<AvatarUploadException>()));
  });

  test('corrupt PNG becomes a user-facing error', () async {
    picker.file =
        XFile.fromData(Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]));
    await expectLater(uploader.pick(), throwsA(isA<AvatarUploadException>()));
  });

  test('unsupported image retains format validation', () async {
    picker.file = XFile.fromData(Uint8List.fromList([1, 2, 3]));
    await expectLater(
        uploader.pick(),
        throwsA(isA<AvatarUploadException>().having(
            (e) => e.message, 'message', contains('JPEG, PNG, or WebP'))));
  });
}
