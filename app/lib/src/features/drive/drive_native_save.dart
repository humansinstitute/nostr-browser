import 'dart:async';
import 'dart:io';

/// A bounded stream with cancellation retained through close, rename and export.
class DriveNativeSave {
  DriveNativeSave(this.partial, this.target) : sink = partial.openWrite();
  final File partial;
  final String target;
  final IOSink sink;
  bool cancelled = false;
  bool committed = false;
  Future<void>? _closing;
  Future<void>? _finishing;
  Future<void> _close() => _closing ??= sink.close();

  Future<void> cancel() async {
    if (committed) return;
    cancelled = true;
    if (_finishing != null) {
      try {
        await _finishing;
      } catch (_) {}
    } else {
      await _close();
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> finish(
      {required bool Function() revoked,
      Future<void> Function()? export,
      Future<void> Function()? beforeCommit,
      Future<void> Function(File)? cleanupBackup}) {
    if (_finishing != null) throw StateError('save_finishing');
    return _finishing = _finish(revoked, export, beforeCommit, cleanupBackup);
  }

  Future<void> _finish(
      bool Function() revoked,
      Future<void> Function()? export,
      Future<void> Function()? beforeCommit,
      Future<void> Function(File)? cleanupBackup) async {
    final destination = File(target);
    final backup = File('${partial.path}.previous');
    var backedUp = false, renamed = false;
    void check() {
      if (cancelled || revoked()) throw StateError('cancelled');
    }

    try {
      await _close();
      if (beforeCommit != null) await beforeCommit();
      check();
      if (await destination.exists()) {
        check();
        await destination.rename(backup.path);
        backedUp = true;
      }
      check();
      await partial.rename(target);
      renamed = true;
      check();
      if (export != null) await export();
      check();
    } catch (_) {
      if (renamed && await destination.exists()) await destination.delete();
      if (backedUp) await backup.rename(target);
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    // Terminal commit: subsequent cancellation cannot undo a completed save.
    // Report it as committed even while best-effort backup cleanup is pending.
    committed = true;
    if (backedUp) {
      try {
        if (cleanupBackup != null) {
          await cleanupBackup(backup);
        } else {
          await backup.delete();
        }
      } catch (_) {/* Preserve the backup if cleanup is unavailable. */}
    }
  }
}
