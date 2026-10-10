import 'package:flutter/material.dart';

import '../remote_controller.dart';

Future<void> showTypingSheet(BuildContext context, RemoteController controller) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TypingSheet(controller: controller),
    );

/// Types into the text box focused on the TV, as the user types on the phone.
/// Closes itself when the TV leaves the text box.
class TypingSheet extends StatefulWidget {
  const TypingSheet({super.key, required this.controller});

  final RemoteController controller;

  @override
  State<TypingSheet> createState() => _TypingSheetState();
}

class _TypingSheetState extends State<TypingSheet> {
  late final _text = TextEditingController(text: widget.controller.typedText);
  bool _closing = false;

  RemoteController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _text.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!_controller.canType) {
      _close();
      return;
    }
    // Changed on the TV, or by an edit the TV didn't take.
    final typed = _controller.typedText;
    if (typed != _text.text) {
      _text.value = TextEditingValue(
        text: typed,
        selection: TextSelection.collapsed(offset: typed.length),
      );
    }
    setState(() {});
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _clear() {
    _text.clear();
    _controller.type('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Type on the TV', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'Text appears in the TV\'s text box as you type. '
                'Confirm it on the TV with the remote.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _text,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onChanged: (text) {
                  _controller.type(text);
                  setState(() {}); // for the clear button
                },
                onSubmitted: (_) => _close(),
                decoration: InputDecoration(
                  hintText: 'Type here',
                  border: const OutlineInputBorder(),
                  suffixIcon: _text.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.clear),
                          onPressed: _clear,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
