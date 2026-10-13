import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wingman_app/src/core/nostr_crypto.dart';
import 'package:wingman_app/src/features/browser/profile_avatar_upload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final identity = NostrCrypto.importIdentity('1'.padLeft(64, '0'));
  test('rejects oversized and unsupported input before decoding', () async {
    await expectLater(
        ProfileAvatarUpload.prepare(
            Uint8List(ProfileAvatarUpload.maxInputBytes + 1)),
        throwsA(isA<AvatarUploadException>()));
    await expectLater(
        ProfileAvatarUpload.prepare(Uint8List.fromList(utf8.encode('<svg/>'))),
        throwsA(isA<AvatarUploadException>()));
  });
  test('resizes image preserving aspect ratio and emits a bounded PNG',
      () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final source = await picture.toImage(1024, 256);
    final bytes = await source.toByteData(format: ui.ImageByteFormat.png);
    final prepared =
        await ProfileAvatarUpload.prepare(bytes!.buffer.asUint8List());
    final codec = await ui.instantiateImageCodec(prepared);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 512);
    expect(frame.image.height, 128);
    expect(prepared.length, lessThan(ProfileAvatarUpload.maxUploadBytes));
    frame.image.dispose();
    codec.dispose();
    source.dispose();
    picture.dispose();
  });
  test('upload signs exact hash for Primal and validates receipt', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final hash = sha256.convert(bytes).toString();
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://blossom.primal.net/upload');
      expect(request.method, 'PUT');
      expect(request.followRedirects, false);
      expect(request.bodyBytes, bytes);
      final event = jsonDecode(utf8.decode(
              base64Decode(request.headers['Authorization']!.substring(6))))
          as Map<String, dynamic>;
      expect(event['kind'], 24242);
      expect(event['pubkey'], identity.publicKeyHex);
      expect(event['tags'], contains(equals(['x', hash])));
      expect(event['tags'], contains(equals(['server', 'blossom.primal.net'])));
      expect(event['tags'], contains(equals(['t', 'upload'])));
      expect(jsonEncode(event), isNot(contains(identity.nsec)));
      expect(NostrCrypto.signEvent(secret: identity.nsec, event: event), event);
      return http.Response(
          jsonEncode({
            'url': 'https://blossom.primal.net/$hash.png',
            'sha256': hash,
            'size': 3
          }),
          201);
    });
    expect(
        await ProfileAvatarUpload().upload(bytes,
            secret: identity.nsec, npub: identity.npub, client: client),
        'https://blossom.primal.net/$hash.png');
  });
  test('rejects identity mismatch without sending and untrusted receipts',
      () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
          '{"url":"https://evil.example/avatar.png","sha256":"wrong","size":3}',
          200);
    });
    final bytes = Uint8List.fromList([1, 2, 3]);
    await expectLater(
        ProfileAvatarUpload().upload(bytes,
            secret: identity.nsec, npub: 'different', client: client),
        throwsA(isA<AvatarUploadException>()));
    expect(requests, 0);
    await expectLater(
        ProfileAvatarUpload().upload(bytes,
            secret: identity.nsec, npub: identity.npub, client: client),
        throwsA(isA<AvatarUploadException>()));
  });
  test('payment failure is actionable', () async {
    await expectLater(
        ProfileAvatarUpload().upload(Uint8List.fromList([1]),
            secret: identity.nsec,
            npub: identity.npub,
            client: MockClient((_) async => http.Response('', 402))),
        throwsA(isA<AvatarUploadException>()
            .having((e) => e.message, 'message', contains('payment'))));
  });
}
