import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Touch-only shell gestures. Opaque edge hit targets exclude platform views
/// from these pointer sequences, including Android's eager gesture recognizer.
/// The child stays mounted when controls are shown or hidden.
class FocusEdgeGestures extends StatefulWidget {
  const FocusEdgeGestures({
    required this.enabled,
    required this.onShowControls,
    required this.onNextTab,
    required this.child,
    super.key,
  });

  final bool enabled;
  final VoidCallback onShowControls;
  final VoidCallback onNextTab;
  final Widget child;

  @override
  State<FocusEdgeGestures> createState() => _FocusEdgeGesturesState();
}

enum _Edge { top, right }

class _FocusEdgeGesturesState extends State<FocusEdgeGestures> {
  static const _edgeWidth = 24.0;
  static const _distance = 48.0;
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  _Edge? _edge;

  @override
  void didUpdateWidget(covariant FocusEdgeGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _edge = null;
  }

  void _down(PointerDownEvent event, Size size, EdgeInsets padding) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1) {
      _edge = null;
      return;
    }
    if (!widget.enabled || event.kind != PointerDeviceKind.touch) return;
    _pointer = event.pointer;
    _origin = event.localPosition;
    final position = event.localPosition;
    // Reserve the entire left corner for Scaffold's drawer edge (20 + inset).
    if (position.dx < padding.left + _edgeWidth) return;
    if (position.dy < padding.top + _edgeWidth) {
      _edge = _Edge.top;
    } else if (position.dx >= size.width - padding.right - _edgeWidth) {
      _edge = _Edge.right;
    }
  }

  void _move(PointerEvent event) {
    if (event.pointer != _pointer || _edge == null) return;
    final delta = event.localPosition - _origin!;
    final forward = _edge == _Edge.top ? delta.dy : -delta.dx;
    final sideways = _edge == _Edge.top ? delta.dx.abs() : delta.dy.abs();
    // Reject a wrong-axis or outward start once it exceeds touch slop.
    if (forward < -kTouchSlop ||
        (sideways > kTouchSlop && sideways > forward)) {
      _edge = null;
    }
  }

  void _up(PointerUpEvent event) {
    _move(event);
    final edge = _edge;
    if (event.pointer == _pointer && edge != null && widget.enabled) {
      final delta = event.localPosition - _origin!;
      final forward = edge == _Edge.top ? delta.dy : -delta.dx;
      final sideways = edge == _Edge.top ? delta.dx.abs() : delta.dy.abs();
      _edge = null;
      if (forward >= _distance && forward >= sideways * 2) {
        if (edge == _Edge.top) {
          widget.onShowControls();
        } else {
          widget.onNextTab();
        }
      }
    }
    _pointers.remove(event.pointer);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      return Listener(
        onPointerDown: (event) => _down(event, constraints.biggest, padding),
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (event) {
          _edge = null;
          _pointers.remove(event.pointer);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (widget.enabled) ...[
              Positioned(
                top: 0,
                left: padding.left + _edgeWidth,
                right: 0,
                height: padding.top + _edgeWidth,
                child: const Listener(behavior: HitTestBehavior.opaque),
              ),
              Positioned(
                top: padding.top + _edgeWidth,
                right: 0,
                bottom: 0,
                width: padding.right + _edgeWidth,
                child: const Listener(behavior: HitTestBehavior.opaque),
              ),
            ],
          ],
        ),
      );
    });
  }
}
