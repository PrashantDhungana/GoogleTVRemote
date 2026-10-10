import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../remote_controller.dart';
import '../tv/key_codes.dart';
import '../tv/tv_app.dart';

Future<void> showAppKeySetup(BuildContext context, RemoteController controller, TvApp app) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AppKeySetupSheet(controller: controller, app: app),
    );

/// Lets the user find which of the TV's app keys opens [app]: they try keys
/// while watching the TV, then keep the one that worked.
class AppKeySetupSheet extends StatefulWidget {
  const AppKeySetupSheet({super.key, required this.controller, required this.app});

  final RemoteController controller;
  final TvApp app;

  @override
  State<AppKeySetupSheet> createState() => _AppKeySetupSheetState();
}

class _AppKeySetupSheetState extends State<AppKeySetupSheet> {
  int? _tried;

  RemoteController get _controller => widget.controller;

  void _try(int code) {
    HapticFeedback.lightImpact();
    final sent = code == RemoteController.appLinkChoice
        ? _controller.tryAppLink(widget.app)
        : _controller.pressCode(code);
    if (sent) setState(() => _tried = code);
  }

  Future<void> _use(int code) async {
    await _controller.setAppKey(widget.app, code);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text('${widget.app.label} button is set up.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = widget.app.label;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final current =
              _controller.appKeys[widget.app] ??
              (_controller.supportsAppLinks ? RemoteController.appLinkChoice : null);
          final choices = [
            if (_controller.supportsAppLinks)
              ('App link (recommended)', RemoteController.appLinkChoice),
            ...appKeyCandidates,
          ];
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              Text('Set up the $label button', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Choose how this button opens $label. Tap Try on an option and watch the TV. '
                'When $label opens, tap Use. The other options are keys that some TV remotes '
                'use for their app buttons.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Something else opened? Go back to the home screen first.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _controller.press(RemoteKey.home),
                    icon: const Icon(Icons.home_outlined),
                    label: const Text('Home'),
                  ),
                ],
              ),
              if (!_controller.isConnected)
                Card.filled(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Connect to your TV first.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              for (final (name, code) in choices)
                Card.filled(
                  color: code == _tried ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
                  child: ListTile(
                    title: Text(name),
                    subtitle: code == current ? Text('Opens $label now') : null,
                    leading: code == current
                        ? Icon(Icons.check_circle, color: scheme.primary)
                        : const Icon(Icons.radio_button_unchecked),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OutlinedButton(
                          onPressed: _controller.isConnected ? () => _try(code) : null,
                          child: const Text('Try'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: code == _tried ? () => _use(code) : null,
                          child: const Text('Use'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_controller.appKeys.containsKey(widget.app))
                TextButton(
                  onPressed: () => _controller.setAppKey(widget.app, null),
                  child: const Text('Reset to default'),
                ),
            ],
          );
        },
      ),
    );
  }
}
