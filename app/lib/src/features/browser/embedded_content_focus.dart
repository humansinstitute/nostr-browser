import 'package:flutter/widgets.dart';

/// Moves stale shell focus to a neutral target on native content touches.
/// WebKit retains native responder ownership. Keys are never consumed here.
/// Unlike unfocus(), this cannot restore a previously focused shell button.
class EmbeddedContentFocus extends StatefulWidget {
  const EmbeddedContentFocus({super.key, required this.child});
  final Widget child;
  @override
  State<EmbeddedContentFocus> createState() => _EmbeddedContentFocusState();
}

class _EmbeddedContentFocusState extends State<EmbeddedContentFocus> {
  final _focus =
      FocusNode(debugLabel: 'Embedded browser content', skipTraversal: true);
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: _focus,
        child: Listener(
            onPointerDown: (_) => _focus.requestFocus(), child: widget.child),
      );
}
