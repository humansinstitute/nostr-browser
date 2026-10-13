import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/drive/drive_native_save.dart';

void main() {
  test('cancel during finish keeps existing target and removes partial',
      () async {
    final dir = await Directory.systemTemp.createTemp('drive-save-');
    try {
      final target = File('${dir.path}/saved');
      await target.writeAsString('original');
      final save = DriveNativeSave(File('${dir.path}/partial'), target.path);
      save.sink.add([1, 2, 3]);
      final reached = Completer<void>(), resume = Completer<void>();
      final finish = save.finish(
          revoked: () => false,
          beforeCommit: () async {
            reached.complete();
            await resume.future;
          });
      final failure = expectLater(finish, throwsStateError);
      await reached.future;
      final cancel = save.cancel();
      resume.complete();
      await failure;
      await cancel;
      expect(await target.readAsString(), 'original');
      expect(await save.partial.exists(), false);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('revocation during export rolls back replacement', () async {
    final dir = await Directory.systemTemp.createTemp('drive-save-');
    try {
      final target = File('${dir.path}/saved');
      await target.writeAsString('original');
      final save = DriveNativeSave(File('${dir.path}/partial'), target.path);
      save.sink.add([1, 2, 3]);
      var revoked = false;
      await expectLater(
          save.finish(
              revoked: () => revoked,
              export: () async {
                revoked = true;
              }),
          throwsStateError);
      expect(await target.readAsString(), 'original');
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test(
      'cancel during terminal backup cleanup truthfully preserves committed save',
      () async {
    final dir = await Directory.systemTemp.createTemp('drive-save-');
    try {
      final target = File('${dir.path}/saved');
      await target.writeAsString('original');
      final save = DriveNativeSave(File('${dir.path}/partial'), target.path);
      save.sink.add([1, 2, 3]);
      final entered = Completer<void>(), resume = Completer<void>();
      final finish = save.finish(
          revoked: () => false,
          cleanupBackup: (backup) async {
            entered.complete();
            await resume.future;
            await backup.delete();
          });
      await entered.future;
      expect(save.committed, true);
      await save.cancel();
      expect(save.cancelled, false);
      resume.complete();
      await finish;
      expect(await target.readAsBytes(), [1, 2, 3]);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
