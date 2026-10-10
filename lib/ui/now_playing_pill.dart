import 'dart:math';

import 'package:flutter/material.dart';

/// A small centered pill showing the app open on the TV. While a media app is
/// open it has a colorful moving wave, and tapping it plays or pauses;
/// otherwise it's a quiet [idleIcon] and [title].
///
/// The TV doesn't report whether anything is actually playing, so the wave
/// moves whenever [playing] is true.
class NowPlayingPill extends StatelessWidget {
  const NowPlayingPill({
    super.key,
    required this.title,
    required this.playing,
    required this.onPlayPause,
    this.idleIcon = Icons.tv,
  });

  final String title;
  final bool playing;
  final VoidCallback onPlayPause;
  final IconData idleIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textColor = playing ? scheme.onSurface : scheme.onSurfaceVariant;
    return Center(
      child: Semantics(
        button: playing,
        label: playing ? 'Now playing: $title' : title,
        onTapHint: playing ? 'Play or pause' : null,
        excludeSemantics: true,
        child: Material(
          color: scheme.surfaceContainerHigh,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: playing ? onPlayPause : null,
            child: Container(
              height: 40,
              constraints: const BoxConstraints(maxWidth: 280),
              padding: EdgeInsets.only(left: playing ? 12 : 14, right: 18),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (playing) const SiriWave() else Icon(idleIcon, size: 18, color: textColor),
                  SizedBox(width: playing ? 10 : 8),
                  Flexible(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(color: textColor),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Overlapping colored waves that swell and drift, like Siri's. Still when the
/// phone asks for fewer animations.
class SiriWave extends StatefulWidget {
  const SiriWave({super.key, this.size = const Size(64, 26)});

  final Size size;

  @override
  State<SiriWave> createState() => _SiriWaveState();
}

class _SiriWaveState extends State<SiriWave> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 0.15;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      size: widget.size,
      painter: _SiriWavePainter(_controller, glow: dark),
    );
  }
}

class _SiriWavePainter extends CustomPainter {
  _SiriWavePainter(this.progress, {required this.glow}) : super(repaint: progress);

  final Animation<double> progress;

  /// Adds the colors together where they overlap, which glows on a dark pill.
  final bool glow;

  /// Color, waves across the width, drift speed, swell speed and wander speed
  /// (whole cycles per loop, so the animation repeats seamlessly), and phase.
  static const _layers = [
    (Color(0xFF2F80FF), 1.4, 2, 3, 1, 0.0),
    (Color(0xFFFF2D95), 1.2, -3, 2, 2, 1.7),
    (Color(0xFF00D5C8), 1.8, 3, 4, 1, 3.1),
    (Color(0xFFFFB000), 1.0, -2, 3, 2, 4.4),
    (Color(0xFF9B5CFF), 1.6, 2, 2, 1, 5.5),
  ];

  static const _samples = 48;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final t = progress.value * 2 * pi;
    for (final (color, waves, drift, swell, wander, phase) in _layers) {
      // Each layer grows, shrinks and wanders sideways on its own, so the
      // colors keep separating and blending.
      final amplitude = midY * (0.35 + 0.65 * (0.5 + 0.5 * sin(t * swell + phase)));
      final center = 0.5 + 0.18 * sin(t * wander + phase);
      final top = <Offset>[];
      for (var i = 0; i <= _samples; i++) {
        final u = i / _samples;
        // Peaks around this layer's center and tapers to nothing at both ends.
        final local = u < center ? u / center * 0.5 : 0.5 + (u - center) / (1 - center) * 0.5;
        final envelope = pow(sin(pi * local), 2.5).toDouble();
        final y = amplitude * envelope * sin(2 * pi * waves * u + t * drift + phase).abs();
        top.add(Offset(u * size.width, midY - y));
      }
      final path = Path()..moveTo(top.first.dx, top.first.dy);
      for (final point in top.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      // Mirror below the center line, like Siri's glow.
      for (final point in top.reversed) {
        path.lineTo(point.dx, 2 * midY - point.dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: glow ? 0.75 : 0.6)
          ..blendMode = glow ? BlendMode.plus : BlendMode.srcOver,
      );
    }
    // A thin bright line through the middle ties the layers together.
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x002F80FF), Color(0xCCFF2D95), Color(0x0000D5C8)],
        ).createShader(Offset.zero & size)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_SiriWavePainter old) => old.glow != glow;
}
