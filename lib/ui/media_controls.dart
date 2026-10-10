import 'dart:math';

import 'package:flutter/material.dart';

import '../tv/key_codes.dart';
import 'remote_button.dart';

/// Previous, rewind, play/pause, fast-forward and next.
class MediaControls extends StatelessWidget {
  const MediaControls({super.key, required this.onKey, this.height = 52});

  final ValueChanged<RemoteKey> onKey;
  final double height;

  static const _keys = [
    (RemoteKey.mediaPrevious, 'Previous', Icons.skip_previous),
    (RemoteKey.mediaRewind, 'Rewind', Icons.fast_rewind),
    (RemoteKey.mediaPlayPause, 'Play or pause', Icons.play_arrow),
    (RemoteKey.mediaFastForward, 'Fast-forward', Icons.fast_forward),
    (RemoteKey.mediaNext, 'Next', Icons.skip_next),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = min(height, (constraints.maxWidth - 4 * 8) / _keys.length);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final (key, label, icon) in _keys)
              RemoteButton(
                label: label,
                width: width,
                height: width,
                color: key == RemoteKey.mediaPlayPause ? scheme.secondaryContainer : null,
                foregroundColor: key == RemoteKey.mediaPlayPause
                    ? scheme.onSecondaryContainer
                    : null,
                onPressed: () => onKey(key),
                child: Icon(icon),
              ),
          ],
        );
      },
    );
  }
}
