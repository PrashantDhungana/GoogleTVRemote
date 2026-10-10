import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../tv/key_codes.dart';

/// A touchpad: a swipe moves the TV's focus once, however long or fast it is.
/// Keeping the finger moving past [repeatDelay] steps again every
/// [repeatStep] pixels, so a long deliberate drag scrolls through several
/// items. A tap selects.
class SwipePad extends StatefulWidget {
  const SwipePad({super.key, required this.onKey});

  final ValueChanged<RemoteKey> onKey;

  /// Travel before the first move of a gesture.
  static const firstStep = 30.0;

  /// Travel per further move once a drag has been held for [repeatDelay].
  static const repeatStep = 80.0;

  /// How long after the first move a drag starts repeating.
  static const repeatDelay = Duration(milliseconds: 350);

  @override
  State<SwipePad> createState() => _SwipePadState();
}

class _SwipePadState extends State<SwipePad> with SingleTickerProviderStateMixin {
  static const _flickDistance = 12.0;
  static const _flickVelocity = 300.0;

  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  Offset _travel = Offset.zero;
  Duration? _firstMoveAt;
  Offset? _touch;
  RemoteKey? _lastKey;

  void _send(RemoteKey key) {
    widget.onKey(key);
    setState(() => _lastKey = key);
    _flash.forward(from: 0);
  }

  void _onPanStart(DragStartDetails details) {
    _travel = Offset.zero;
    _firstMoveAt = null;
    setState(() => _touch = details.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final now = details.sourceTimeStamp ?? Duration.zero;
    _travel += details.delta;
    setState(() => _touch = details.localPosition);

    final firstMoveAt = _firstMoveAt;
    if (firstMoveAt != null && now - firstMoveAt < SwipePad.repeatDelay) {
      // The rest of a quick swipe: ignore it, so one swipe is one move.
      _travel = Offset.zero;
      return;
    }
    final step = firstMoveAt == null ? SwipePad.firstStep : SwipePad.repeatStep;
    final dx = _travel.dx;
    final dy = _travel.dy;
    if (dx.abs() >= step && dx.abs() >= dy.abs()) {
      _send(dx > 0 ? RemoteKey.dpadRight : RemoteKey.dpadLeft);
    } else if (dy.abs() >= step && dy.abs() > dx.abs()) {
      _send(dy > 0 ? RemoteKey.dpadDown : RemoteKey.dpadUp);
    } else {
      return;
    }
    _firstMoveAt ??= now;
    _travel = Offset.zero;
  }

  void _onPanEnd(DragEndDetails details) {
    if (_firstMoveAt == null) {
      final velocity = details.velocity.pixelsPerSecond;
      final direction = _travel.distance >= _flickDistance
          ? _travel
          : (velocity.distance >= _flickVelocity ? velocity : null);
      if (direction != null) {
        _send(
          direction.dx.abs() > direction.dy.abs()
              ? (direction.dx > 0 ? RemoteKey.dpadRight : RemoteKey.dpadLeft)
              : (direction.dy > 0 ? RemoteKey.dpadDown : RemoteKey.dpadUp),
        );
      }
    }
    setState(() => _touch = null);
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      label: 'Touchpad. Swipe to move, tap to select.',
      onTap: () => widget.onKey(RemoteKey.dpadCenter),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Count movement from the first touch, so the drag slop isn't lost.
        dragStartBehavior: DragStartBehavior.down,
        onTap: () => _send(RemoteKey.dpadCenter),
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        onPanCancel: () => setState(() => _touch = null),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(32),
          ),
          child: SizedBox.expand(
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedOpacity(
                  opacity: _touch == null ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.swipe, size: 32, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text(
                        'Swipe to move · Tap to select',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                AnimatedBuilder(
                  animation: _flash,
                  builder: (context, _) {
                    final key = _lastKey;
                    if (key == null || _flash.isDismissed || _flash.isCompleted) {
                      return const SizedBox.shrink();
                    }
                    return Opacity(
                      opacity: 1 - _flash.value,
                      child: Transform.scale(
                        scale: 0.9 + 0.3 * _flash.value,
                        child: Icon(_iconFor(key), size: 72, color: scheme.primary),
                      ),
                    );
                  },
                ),
                if (_touch case final touch?)
                  Positioned(
                    left: touch.dx - 28,
                    top: touch.dy - 28,
                    child: IgnorePointer(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.primary.withValues(alpha: 0.18),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(RemoteKey key) => switch (key) {
    RemoteKey.dpadUp => Icons.keyboard_arrow_up,
    RemoteKey.dpadDown => Icons.keyboard_arrow_down,
    RemoteKey.dpadLeft => Icons.keyboard_arrow_left,
    RemoteKey.dpadRight => Icons.keyboard_arrow_right,
    _ => Icons.circle_outlined,
  };
}
