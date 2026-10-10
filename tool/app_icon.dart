import 'dart:math';
import 'dart:ui';

/// The app icon: a white D-pad with arrows in the now-playing wave's colors,
/// on deep navy. `app_icon_test.dart` renders it into the Android and iOS
/// icon files.
///
/// Sizes are fractions of the canvas, with the artwork centered.

const _dots = [
  Color(0xFF2F80FF), // up
  Color(0xFFFF2D95), // right
  Color(0xFF00D5C8), // down
  Color(0xFFFFB000), // left
];

/// The background alone, full bleed.
void paintBackground(Canvas canvas, double size) {
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size, size),
    Paint()
      ..shader = Gradient.linear(Offset.zero, Offset(size, size), const [
        Color(0xFF1B2250),
        Color(0xFF0B0E24),
      ]),
  );
  // A soft blue glow behind the D-pad.
  final center = Offset(size / 2, size / 2);
  canvas.drawCircle(
    center,
    size * 0.45,
    Paint()
      ..shader = Gradient.radial(center, size * 0.45, const [Color(0x483D7BFF), Color(0x003D7BFF)]),
  );
}

/// The D-pad on a transparent background, [scale] times its full size
/// (0.58 of the canvas across). With [mono] the arrows are cut out instead of
/// colored, for Android's themed icons.
void paintForeground(Canvas canvas, double size, {double scale = 1, bool mono = false}) {
  final c = Offset(size / 2, size / 2);
  final s = size * scale;
  canvas.saveLayer(Rect.fromLTWH(0, 0, size, size), Paint());
  final white = Paint()..color = const Color(0xFFFFFFFF);
  // The ring, with a gap around the center button.
  canvas.drawPath(
    Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: c, radius: s * 0.29))
      ..addOval(Rect.fromCircle(center: c, radius: s * 0.135)),
    white,
  );
  canvas.drawCircle(c, s * 0.095, white);
  for (var i = 0; i < 4; i++) {
    final angle = -pi / 2 + i * pi / 2;
    canvas.drawCircle(
      c + Offset(cos(angle), sin(angle)) * s * 0.212,
      s * 0.034,
      mono ? (Paint()..blendMode = BlendMode.clear) : (Paint()..color = _dots[i]),
    );
  }
  canvas.restore();
}
