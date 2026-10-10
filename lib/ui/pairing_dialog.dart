import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../remote_controller.dart';
import '../tv/pairing.dart';

/// Returns true once paired.
Future<bool> showPairingDialog(BuildContext context, RemoteController controller) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PairingDialog(controller: controller),
    ) ??
    false;

enum _Stage { connecting, enterCode, verifying, failed }

class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key, required this.controller});

  final RemoteController controller;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  static const _codeLength = 6;

  final _code = TextEditingController();
  final _focus = FocusNode();
  _Stage _stage = _Stage.connecting;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _code.clear();
    if (_stage != _Stage.connecting) {
      setState(() {
        _stage = _Stage.connecting;
        _error = null;
      });
    }
    try {
      await widget.controller.startPairing();
      if (mounted) setState(() => _stage = _Stage.enterCode);
    } on PairingException catch (e) {
      if (mounted) _showFailure(e.message);
    }
  }

  Future<void> _submit() async {
    if (_code.text.length != _codeLength || _stage != _Stage.enterCode) return;
    setState(() {
      _stage = _Stage.verifying;
      _error = null;
    });
    try {
      await widget.controller.finishPairing(_code.text);
      if (mounted) Navigator.of(context).pop(true);
    } on WrongPairingCodeException catch (e) {
      if (!mounted) return;
      _code.clear();
      setState(() {
        _stage = _Stage.enterCode;
        _error = e.message;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    } on PairingException catch (e) {
      if (mounted) _showFailure(e.message);
    }
  }

  void _showFailure(String message) => setState(() {
    _stage = _Stage.failed;
    _error = message;
  });

  void _cancel() {
    widget.controller.cancelPairing();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = widget.controller.device?.name ?? 'your TV';

    return AlertDialog(
      icon: const Icon(Icons.connected_tv),
      title: Text('Pair with $name'),
      content: switch (_stage) {
        _Stage.connecting => const Row(
          children: [
            SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 16),
            Expanded(child: Text('Asking the TV for a code…')),
          ],
        ),
        _Stage.failed => Text(_error ?? 'Pairing failed.'),
        _Stage.enterCode || _Stage.verifying => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the code shown on your TV.'),
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              focusNode: _focus,
              autofocus: true,
              enabled: _stage == _Stage.enterCode,
              maxLength: _codeLength,
              textAlign: TextAlign.center,
              textCapitalization: TextCapitalization.characters,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              style: theme.textTheme.headlineMedium?.copyWith(
                letterSpacing: 8,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                const _UpperCaseFormatter(),
              ],
              decoration: InputDecoration(
                counterText: '',
                hintText: '••••••',
                errorText: _error,
                errorMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {}); // Refresh the Pair button.
                if (value.length == _codeLength) _submit();
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      },
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        switch (_stage) {
          _Stage.failed => FilledButton(onPressed: _start, child: const Text('Try again')),
          _Stage.verifying => const FilledButton(
            onPressed: null,
            child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          _ => FilledButton(
            onPressed: _stage == _Stage.enterCode && _code.text.length == _codeLength
                ? _submit
                : null,
            child: const Text('Pair'),
          ),
        },
      ],
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
