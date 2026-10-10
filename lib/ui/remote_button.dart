import 'dart:async';

import 'package:flutter/material.dart';

const repeatDelay = Duration(milliseconds: 400);
const repeatInterval = Duration(milliseconds: 110);

/// A remote button that fires on touch-down, like a physical remote, and
/// optionally keeps firing while held.
class RemoteButton extends StatefulWidget {
  const RemoteButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    this.repeat = false,
    this.width = 64,
    this.height = 64,
    this.color,
    this.foregroundColor,
  });

  /// Read by screen readers.
  final String label;
  final VoidCallback onPressed;
  final Widget child;
  final bool repeat;
  final double width;
  final double height;
  final Color? color;
  final Color? foregroundColor;

  @override
  State<RemoteButton> createState() => _RemoteButtonState();
}

class _RemoteButtonState extends State<RemoteButton> {
  int? _pointer;
  Timer? _repeatTimer;

  void _onDown(PointerDownEvent event) {
    if (_pointer != null) return;
    setState(() => _pointer = event.pointer);
    widget.onPressed();
    if (widget.repeat) {
      _repeatTimer = Timer(repeatDelay, () {
        _repeatTimer = Timer.periodic(repeatInterval, (_) => widget.onPressed());
      });
    }
  }

  void _onUp(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _repeatTimer?.cancel();
    setState(() => _pointer = null);
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = widget.color ?? scheme.surfaceContainerHigh;
    return Semantics(
      container: true,
      button: true,
      label: widget.label,
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: Listener(
        onPointerDown: _onDown,
        onPointerUp: _onUp,
        onPointerCancel: _onUp,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: _pointer != null
                ? Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.14), background)
                : background,
            borderRadius: BorderRadius.circular(widget.height / 2),
          ),
          child: Center(
            child: IconTheme.merge(
              data: IconThemeData(color: widget.foregroundColor ?? scheme.onSurface, size: 26),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill with volume down and up buttons that repeat while held, and the
/// volume between them, which mutes when tapped.
class VolumeRocker extends StatelessWidget {
  const VolumeRocker({
    super.key,
    required this.onVolumeDown,
    required this.onVolumeUp,
    required this.onMute,
    this.height = 64,
    this.level,
    this.muted = false,
  });

  final VoidCallback onVolumeDown;
  final VoidCallback onVolumeUp;
  final VoidCallback onMute;
  final double height;
  final int? level;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RemoteButton(
            label: 'Volume down',
            repeat: true,
            width: 76,
            height: height,
            color: Colors.transparent,
            onPressed: onVolumeDown,
            child: const Icon(Icons.remove),
          ),
          RemoteButton(
            label: muted ? 'Unmute' : 'Mute',
            width: 72,
            height: height - 12,
            color: muted ? scheme.primaryContainer : Colors.transparent,
            onPressed: onMute,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  muted ? Icons.volume_off : Icons.volume_up,
                  size: 18,
                  color: muted ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                ),
                Text(
                  muted ? 'Muted' : (level != null ? '$level' : 'Vol'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: muted ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          RemoteButton(
            label: 'Volume up',
            repeat: true,
            width: 76,
            height: height,
            color: Colors.transparent,
            onPressed: onVolumeUp,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
