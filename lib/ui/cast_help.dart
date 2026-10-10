import 'package:flutter/material.dart';

/// Explains how to mirror the phone's screen when the app couldn't open the
/// phone's cast screen itself.
Future<void> showCastHelp(BuildContext context, {String? tvName}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    icon: const Icon(Icons.cast),
    title: const Text('Cast your screen'),
    content: Text(
      "Your phone didn't open its screen casting, so start it from the phone:\n\n"
      '1. Swipe down from the top of the screen to open Quick Settings.\n'
      '2. Tap Screen Cast. It may be called Cast, Smart View or Screen mirroring.\n'
      '3. Choose ${tvName ?? 'your TV'}.\n\n'
      'The Google Home app can also cast your screen. The phone and TV must be on the same Wi-Fi.',
    ),
    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
  ),
);
