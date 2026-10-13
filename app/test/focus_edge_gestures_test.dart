import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wingman_app/src/features/browser/focus_edge_gestures.dart';

void main() {
  testWidgets('edge zones exclude eager content; other touches reach the page',
      (tester) async {
    var shown = 0;
    var next = 0;
    var pageTouches = 0;
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data:
              const MediaQueryData(padding: EdgeInsets.only(top: 44, left: 8)),
          child: FocusEdgeGestures(
            enabled: true,
            onShowControls: () => shown++,
            onNextTab: () => next++,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                    EagerGestureRecognizer>(
                  EagerGestureRecognizer.new,
                  (_) {},
                ),
              },
              child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => pageTouches++),
            ),
          ),
        )));
    await tester.dragFrom(const Offset(400, 50), const Offset(0, 100));
    await tester.dragFrom(const Offset(790, 300), const Offset(-150, 0));
    expect(shown, 1);
    expect(next, 1);
    expect(pageTouches, 0);
    await tester.dragFrom(const Offset(400, 300), const Offset(0, 100));
    await tester.dragFrom(const Offset(5, 5), const Offset(100, 0));
    expect(pageTouches, 2);
    expect(shown, 1);
    expect(next, 1);
  });

  testWidgets('rejects short, wrong, diagonal, cancelled and multitouch swipes',
      (tester) async {
    var actions = 0;
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: FocusEdgeGestures(
            enabled: true,
            onShowControls: () => actions++,
            onNextTab: () => actions++,
            child: const ColoredBox(color: Color(0xFFFFFFFF)),
          ),
        )));
    for (final entry in <(Offset, Offset)>[
      (const Offset(790, 300), const Offset(-30, 0)),
      (const Offset(790, 300), const Offset(80, 0)),
      (const Offset(790, 300), const Offset(-60, 80)),
      (const Offset(400, 5), const Offset(0, -80)),
      (const Offset(400, 5), const Offset(80, 0)),
      (const Offset(400, 5), const Offset(0, 30)),
    ]) {
      await tester.dragFrom(entry.$1, entry.$2);
    }
    final cancelled = await tester.startGesture(const Offset(790, 300));
    await cancelled.moveBy(const Offset(-100, 0));
    await cancelled.cancel();
    final first = await tester.startGesture(const Offset(790, 300), pointer: 1);
    final second =
        await tester.startGesture(const Offset(400, 300), pointer: 2);
    await second.up();
    await first.moveBy(const Offset(-150, 0));
    await first.up();
    final outside =
        await tester.startGesture(const Offset(400, 300), pointer: 3);
    final edge = await tester.startGesture(const Offset(790, 300), pointer: 4);
    await edge.moveBy(const Offset(-150, 0));
    await edge.up();
    await outside.up();
    final mouse = await tester.startGesture(const Offset(790, 300),
        kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(-150, 0));
    await mouse.up();
    expect(actions, 0);
    final valid = await tester.startGesture(const Offset(790, 300));
    await valid.moveBy(const Offset(-100, 0));
    await valid.moveBy(const Offset(-100, 0));
    expect(actions, 0);
    await valid.up();
    expect(actions, 1);
  });
}
