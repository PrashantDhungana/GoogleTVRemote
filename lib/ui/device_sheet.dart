import 'package:flutter/material.dart';

import '../remote_controller.dart';
import '../tv/discovery.dart';

Future<void> showDeviceSheet(BuildContext context, RemoteController controller) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DeviceSheet(controller: controller),
    );

/// Lists the saved TVs (to switch between, rename or remove), TVs found on the
/// network, and accepts a manually entered address.
class DeviceSheet extends StatefulWidget {
  const DeviceSheet({super.key, required this.controller});

  final RemoteController controller;

  @override
  State<DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<DeviceSheet> {
  final _discovery = TvDiscovery();
  final _address = TextEditingController();
  String? _addressError;

  RemoteController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _discovery
      ..addListener(_followMovedTvs)
      ..start();
  }

  @override
  void dispose() {
    _discovery
      ..removeListener(_followMovedTvs)
      ..dispose();
    _address.dispose();
    super.dispose();
  }

  /// Saved TVs found at a new address (the router gave them another one) are
  /// updated, so they keep working.
  void _followMovedTvs() {
    for (final found in _discovery.devices) {
      final saved = _controller.savedMatch(found);
      if (saved != null && saved.host != found.host) {
        _controller.updateAddress(saved, found.host);
      }
    }
  }

  void _select(TvDevice device) {
    _controller.selectDevice(device);
    Navigator.of(context).pop();
  }

  Future<void> _rename(TvDevice device) async {
    final name = await showRenameDialog(context, device.name);
    if (name != null) await _controller.renameDevice(device, name);
  }

  void _connectToAddress() {
    final host = _address.text.trim();
    if (!RegExp(r'^[A-Za-z0-9.\-:]+$').hasMatch(host)) {
      setState(() => _addressError = 'Enter an IP address, like 192.168.1.20');
      return;
    }
    _select(TvDevice(name: host, host: host));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Choose a TV', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'Google TV and Android TV devices on your Wi-Fi network show up here.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: Listenable.merge([_discovery, _controller]),
                builder: (context, _) {
                  final current = _controller.device;
                  final saved = _controller.savedDevices;
                  final others = [
                    for (final device in _discovery.devices)
                      if (_controller.savedMatch(device) == null) device,
                  ];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (saved.isNotEmpty) ...[
                        Text('Your TVs', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        for (final device in saved)
                          _SavedTvTile(
                            device: device,
                            isCurrent: device.host == current?.host,
                            onTap: () => _select(device),
                            onRename: () => _rename(device),
                            onRemove: () => _controller.forgetDevice(device),
                          ),
                        const SizedBox(height: 16),
                        Text('Other TVs on your network', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                      ],
                      for (final device in others)
                        Card.filled(
                          color: scheme.surfaceContainerHigh,
                          child: ListTile(
                            leading: const Icon(Icons.tv),
                            title: Text(device.name),
                            subtitle: Text(device.host),
                            onTap: () => _select(device),
                          ),
                        ),
                      if (_discovery.error case final error?)
                        _Note(
                          icon: Icons.error_outline,
                          text: "Couldn't search the network: $error",
                        )
                      else if (_discovery.isScanning && others.isEmpty)
                        _Note(
                          icon: null,
                          text: saved.isEmpty
                              ? 'Looking for TVs… Make sure the TV is on and on the same Wi-Fi.'
                              : 'Looking for other TVs…',
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              Text('Or enter its IP address', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _address,
                // Some numeric keyboards can't type more than one dot.
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: '192.168.1.20',
                  helperText: 'On the TV: Settings › Network & Internet › your network',
                  errorText: _addressError,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Connect',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _connectToAddress,
                  ),
                ),
                onChanged: (_) {
                  if (_addressError != null) setState(() => _addressError = null);
                },
                onSubmitted: (_) => _connectToAddress(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _SavedTvAction { rename, remove }

class _SavedTvTile extends StatelessWidget {
  const _SavedTvTile({
    required this.device,
    required this.isCurrent,
    required this.onTap,
    required this.onRename,
    required this.onRemove,
  });

  final TvDevice device;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      color: isCurrent ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      child: ListTile(
        leading: Icon(
          isCurrent ? Icons.check_circle : Icons.tv,
          color: isCurrent ? scheme.primary : null,
        ),
        title: Text(device.name),
        subtitle: Text(isCurrent ? '${device.host} · In use' : device.host),
        onTap: onTap,
        trailing: PopupMenuButton<_SavedTvAction>(
          tooltip: 'Options for ${device.name}',
          onSelected: (action) => switch (action) {
            _SavedTvAction.rename => onRename(),
            _SavedTvAction.remove => onRemove(),
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _SavedTvAction.rename,
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Rename'),
                ],
              ),
            ),
            PopupMenuItem(
              value: _SavedTvAction.remove,
              child: Row(
                children: [
                  Icon(Icons.delete_outline, size: 20),
                  SizedBox(width: 12),
                  Text('Remove'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a new name for a TV. Returns null if cancelled.
Future<String?> showRenameDialog(BuildContext context, String name) => showDialog<String>(
  context: context,
  builder: (_) => _RenameDialog(name: name),
);

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.name});

  final String name;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.name)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.name.length);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename TV'),
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => TextButton(
            onPressed: _name.text.trim().isEmpty ? null : _save,
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  /// A spinner is shown when null.
  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: icon != null
                ? Icon(icon, size: 20)
                : const CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
