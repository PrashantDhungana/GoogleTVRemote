import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../tv/key_codes.dart';
import 'remote_button.dart';

/// A circular directional pad with an OK button in the middle.
///
/// Directions repeat while held; OK fires once per press.
class DPad extends StatefulWidget {
  const DPad({super.key, required this.size, required this.onKey});

  final double size;
  final ValueChanged<RemoteKey> onKey;

  @override
  State<DPad> createState() => _DPadState();
}

class _DPadState extends State<DPad> {
  /// Radius of the OK button (plus its surrounding gap), relative to the pad's.
  static const centerFraction = 0.40;

  int? _pointer;
  RemoteKey? _pressed;
  Timer? _repeatTimer;

  RemoteKey? _keyAt(Offset position) {
    final radius = widget.size / 2;
    final offset = position - Offset(radius, radius);
    final distance = offset.distance;
    if (distance > radius) return null;
    if (distance <= radius * centerFraction) return RemoteKey.dpadCenter;
    if (offset.dx.abs() > offset.dy.abs()) {
      return offset.dx > 0 ? RemoteKey.dpadRight : RemoteKey.dpadLeft;
    }
    return offset.dy > 0 ? RemoteKey.dpadDown : RemoteKey.dpadUp;
  }

  void _onDown(PointerDownEvent event) {
    if (_pointer != null) return;
    final key = _keyAt(event.localPosition);
    if (key == null) return;
    setState(() {
      _pointer = event.pointer;
      _pressed = key;
    });
    widget.onKey(key);
    if (key != RemoteKey.dpadCenter) {
      _repeatTimer = Timer(repeatDelay, () {
        _repeatTimer = Timer.periodic(repeatInterval, (_) => widget.onKey(key));
      });
    }
  }

  void _onUp(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _repeatTimer?.cancel();
    setState(() {
      _pointer = null;
      _pressed = null;
    });
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    final zone = size * 0.3;

    Widget semanticZone(String label, RemoteKey key, Alignment alignment) => Align(
      alignment: alignment,
      child: Semantics(
        button: true,
        label: label,
        onTap: () => widget.onKey(key),
        child: SizedBox.square(dimension: zone),
      ),
    );

    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Listener(
            onPointerDown: _onDown,
            onPointerUp: _onUp,
            onPointerCancel: _onUp,
            child: CustomPaint(
              size: Size.square(size),
              painter: _DPadPainter(
                pressed: _pressed,
                centerFraction: centerFraction,
                ring: scheme.surfaceContainerHighest,
                ringPressed: Color.alphaBlend(
                  scheme.onSurface.withValues(alpha: 0.12),
                  scheme.surfaceContainerHighest,
                ),
                // A different tone from the ring, so OK reads as its own button.
                center: scheme.surfaceContainerLow,
                centerPressed: Color.alphaBlend(
                  scheme.onSurface.withValues(alpha: 0.12),
                  scheme.surfaceContainerLow,
                ),
                centerOutline: scheme.outlineVariant,
                marks: scheme.onSurfaceVariant,
                pressedMark: scheme.primary,
              ),
            ),
          ),
          // Invisible targets so screen readers can reach each direction.
          semanticZone('Up', RemoteKey.dpadUp, Alignment.topCenter),
          semanticZone('Down', RemoteKey.dpadDown, Alignment.bottomCenter),
          semanticZone('Left', RemoteKey.dpadLeft, Alignment.centerLeft),
          semanticZone('Right', RemoteKey.dpadRight, Alignment.centerRight),
          semanticZone('OK', RemoteKey.dpadCenter, Alignment.center),
        ],
      ),
    );
  }
}

class _DPadPainter extends CustomPainter {
  _DPadPainter({
    required this.pressed,
    required this.centerFraction,
    required this.ring,
    required this.ringPressed,
    required this.center,
    required this.centerPressed,
    required this.centerOutline,
    required this.marks,
    required this.pressedMark,
  });

  final RemoteKey? pressed;
  final double centerFraction;
  final Color ring;
  final Color ringPressed;
  final Color center;
  final Color centerPressed;
  final Color centerOutline;
  final Color marks;
  final Color pressedMark;

  static const _directions = {
    RemoteKey.dpadRight: 0.0,
    RemoteKey.dpadDown: pi / 2,
    RemoteKey.dpadLeft: pi,
    RemoteKey.dpadUp: -pi / 2,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final origin = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final moatRadius = radius * centerFraction;
    final buttonRadius = moatRadius - radius * 0.04;

    canvas.drawCircle(origin, radius, Paint()..color = ring);

    final pressedAngle = _directions[pressed];
    if (pressedAngle != null) {
      final sector = Path()
        ..moveTo(origin.dx, origin.dy)
        ..arcTo(
          Rect.fromCircle(center: origin, radius: radius),
          pressedAngle - pi / 4,
          pi / 2,
          false,
        )
        ..close();
      canvas.drawPath(sector, Paint()..color = ringPressed);
      canvas.drawCircle(origin, moatRadius, Paint()..color = ring);
    }

    final markDistance = (radius + moatRadius) / 2;
    for (final MapEntry(key: key, value: angle) in _directions.entries) {
      canvas.drawCircle(
        origin + Offset.fromDirection(angle, markDistance),
        radius * 0.028,
        Paint()..color = key == pressed ? pressedMark : marks,
      );
    }

    canvas.drawCircle(
      origin,
      buttonRadius,
      Paint()..color = pressed == RemoteKey.dpadCenter ? centerPressed : center,
    );
    canvas.drawCircle(
      origin,
      buttonRadius,
      Paint()
        ..color = centerOutline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_DPadPainter old) =>
      old.pressed != pressed ||
      old.ring != ring ||
      old.center != center ||
      old.centerOutline != centerOutline ||
      old.marks != marks ||
      old.pressedMark != pressedMark;
}
