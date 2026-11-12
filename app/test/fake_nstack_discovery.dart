import 'package:wingman_app/src/features/nstack/nstack_self_index.dart';

/// Keep unrelated shell/profile tests offline; discovery has its own signed fixtures.
class EmptyNStackDiscovery extends NStackSelfIndexDiscovery {
  @override
  Future<List<NStackDiscoveredTower>> discover(
          {required String identityNpub, required String secret}) async =>
      const [];
}
