// Two pieces term_select.dart builds on: [Grab], a recognizer that takes a
// pointer the moment it goes down (so neither xterm's own selection nor a
// scroll gets it), and [SelHandle], the dot a finger drags to move one end
// of a selection. See README.md.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Wins every primary-button pointer, at once: no slop, no
/// delay. A right click still reaches the menu.
class Grab extends OneSequenceGestureRecognizer {
  Grab({super.supportedDevices}) : super(allowedButtonsFilter: (b) => b == kPrimaryButton);

  void Function(PointerDownEvent) onDown = (_) {};
  void Function(Offset global) onMove = (_) {};
  void Function(bool cancelled) onUp = (_) {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event); // tracks it
    resolve(GestureDisposition.accepted); // the arena is still open: we win when it closes
    onDown(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) onMove(event.position);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      onUp(event is PointerCancelEvent);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    stopTrackingPointer(pointer);
    onUp(true);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'grab';
}

/// A selection handle hanging under the line whose bottom is at [at]: a stem
/// and a dot, in a finger-sized box. A [Stack] child.
class SelHandle extends StatelessWidget {
  const SelHandle({super.key, required this.at, required this.onDown, required this.onMove, required this.onUp});
  final Offset at;
  final void Function(PointerDownEvent) onDown;
  final void Function(Offset global) onMove;
  final void Function(bool cancelled) onUp;

  static const box = 44.0;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Positioned(
      left: at.dx - box / 2,
      top: at.dy,
      width: box,
      height: box,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          Grab: GestureRecognizerFactoryWithHandlers<Grab>(
            Grab.new,
            (g) => g
              ..onDown = onDown
              ..onMove = onMove
              ..onUp = onUp,
          ),
        },
        child: Align(
          alignment: Alignment.topCenter,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 2, height: 6, color: color),
            Container(width: 18, height: 18, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ]),
        ),
      ),
    );
  }
}
