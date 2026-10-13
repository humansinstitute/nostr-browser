import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/core/native_core_bridge.dart';

void main() {
  test('NativeCoreBridge resolves the local repository root', () {
    final root = NativeCoreBridge().debugResolveRepoRoot();

    expect(File('$root/Cargo.toml').existsSync(), isTrue);
    expect(Directory('$root/crates/wmapp-core').existsSync(), isTrue);
  });
}
