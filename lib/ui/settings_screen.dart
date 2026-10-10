import 'package:flutter/material.dart';

import '../phone_controls.dart';
import '../remote_controller.dart';

/// The remote's settings, with less used ones under Advanced.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          children: [
            if (PhoneControls.isSupported)
              SwitchListTile(
                secondary: const Icon(Icons.volume_up_outlined),
                title: const Text('Phone volume buttons'),
                subtitle: const Text(
                  "Change the TV's volume with your phone's volume buttons while the app is "
                  'open and connected.',
                ),
                value: controller.volumeKeysEnabled,
                onChanged: controller.setVolumeKeysEnabled,
              ),
            const _SectionHeader('Advanced'),
            SwitchListTile(
              secondary: const Icon(Icons.play_circle_outline),
              title: const Text('Media controls'),
              subtitle: const Text(
                'Show previous, rewind, play/pause, fast-forward and next buttons.',
              ),
              value: controller.mediaControlsEnabled,
              onChanged: controller.setMediaControlsEnabled,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
