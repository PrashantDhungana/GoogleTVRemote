import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../phone_controls.dart';
import '../remote_controller.dart';
import '../tv/key_codes.dart';
import '../tv/tv_app.dart';
import 'app_key_setup.dart';
import 'app_shortcuts.dart';
import 'cast_help.dart';
import 'device_sheet.dart';
import 'dpad.dart';
import 'media_controls.dart';
import 'now_playing_pill.dart';
import 'pairing_dialog.dart';
import 'remote_button.dart';
import 'settings_screen.dart';
import 'swipe_pad.dart';
import 'typing_sheet.dart';

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.controller});

  final RemoteController controller;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  late final AppLifecycleListener _lifecycle;
  late ConnectionStatus _lastStatus = widget.controller.status;
  bool _pairingDialogOpen = false;
  late bool _couldType;
  bool _typingSheetOpen = false;
  late final _phone = PhoneControls(onVolumeButton: _onVolumeButton);

  RemoteController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        switch (state) {
          case AppLifecycleState.resumed:
            _controller.setForeground(true);
          case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
            _controller.setForeground(false);
          case AppLifecycleState.inactive:
            break; // e.g. the notification shade is open; keep the connection.
        }
      },
    );
    _couldType = _controller.canType;
    _controller.addListener(_onControllerChanged);
    _captureVolumeButtons();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_controller.status == ConnectionStatus.noDevice) {
        showDeviceSheet(context, _controller);
      } else if (_controller.status == ConnectionStatus.needsPairing) {
        _pair();
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _lifecycle.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// The phone's volume buttons control the TV only while connected, so they
  /// still change the phone's volume when the TV can't be reached.
  void _captureVolumeButtons() =>
      _phone.setVolumeButtonsCaptured(_controller.volumeKeysEnabled && _controller.isConnected);

  void _onVolumeButton(VolumeButton button) => _controller.press(switch (button) {
    VolumeButton.up => RemoteKey.volumeUp,
    VolumeButton.down => RemoteKey.volumeDown,
  });

  Future<void> _castScreen() async {
    HapticFeedback.lightImpact();
    if (await _phone.openScreenCast() || !mounted) return;
    await showCastHelp(context, tvName: _controller.device?.name);
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(controller: _controller)));
  }

  void _onControllerChanged() {
    _captureVolumeButtons();
    final status = _controller.status;
    // Ask to pair as soon as a TV turns out to need it, but don't nag after
    // the user cancels.
    if (status == ConnectionStatus.needsPairing && _lastStatus != ConnectionStatus.needsPairing) {
      _pair();
    }
    _lastStatus = status;

    // Open the keyboard when a text box on the TV gets focus, like the TV asks.
    final canType = _controller.canType;
    if (canType && !_couldType && (ModalRoute.of(context)?.isCurrent ?? false)) {
      _type();
    }
    _couldType = canType;
  }

  Future<void> _type() async {
    if (_typingSheetOpen || !mounted) return;
    _typingSheetOpen = true;
    try {
      await showTypingSheet(context, _controller);
    } finally {
      _typingSheetOpen = false;
    }
  }

  void _onKeyboardPressed() {
    HapticFeedback.lightImpact();
    if (_controller.canType) {
      _type();
    } else if (_controller.isConnected) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Select a text box on the TV first, then type here.')),
        );
    } else {
      _offerDevicesIfNeeded(sent: false);
    }
  }

  Future<void> _pair() async {
    if (_pairingDialogOpen || !mounted) return;
    _pairingDialogOpen = true;
    try {
      await showPairingDialog(context, _controller);
    } finally {
      _pairingDialogOpen = false;
    }
  }

  void _press(RemoteKey key) {
    HapticFeedback.lightImpact();
    _offerDevicesIfNeeded(sent: _controller.press(key));
  }

  void _launch(TvApp app) {
    HapticFeedback.lightImpact();
    switch (_controller.launchApp(app)) {
      case AppLaunchResult.sent:
        break;
      case AppLaunchResult.notConnected:
        _offerDevicesIfNeeded(sent: false);
      case AppLaunchResult.needsSetup:
        showAppKeySetup(context, _controller, app);
    }
  }

  Future<void> _onMicPressed() async {
    HapticFeedback.lightImpact();
    if (_controller.voice != VoiceState.idle) {
      _controller.stopVoice();
      return;
    }
    final result = await _controller.startVoice();
    if (result == VoiceStartResult.notConnected) _offerDevicesIfNeeded(sent: false);
    final problem = switch (result) {
      VoiceStartResult.started ||
      VoiceStartResult.cancelled ||
      VoiceStartResult.notConnected => null,
      VoiceStartResult.unsupported => "This TV doesn't accept voice search from the app.",
      VoiceStartResult.noPermission =>
        "Voice search needs the microphone. Allow it for TV Remote in your phone's settings.",
      VoiceStartResult.noMicrophone => "Couldn't use the phone's microphone.",
      VoiceStartResult.noResponse => "The TV didn't start voice search. Try again.",
    };
    if (problem != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  void _offerDevicesIfNeeded({required bool sent}) {
    if (!sent && _controller.status == ConnectionStatus.noDevice) {
      showDeviceSheet(context, _controller);
    }
  }

  void _step(RemoteKey key) {
    HapticFeedback.selectionClick();
    _controller.press(key);
  }

  Widget _nowPlaying() {
    final app = _controller.openApp;
    final (title, icon) = switch (app) {
      _ when !_controller.isConnected => ('Not connected', Icons.tv_off_outlined),
      _ when _controller.tv.isOn == false => ('TV is off', Icons.tv_off_outlined),
      null => ('Nothing playing', Icons.tv),
      OpenApp(isHome: true) => ('Home', Icons.home_outlined),
      OpenApp(:final name) => (name, Icons.apps),
    };
    final playing =
        _controller.isConnected && _controller.tv.isOn != false && (app?.playsMedia ?? false);
    return NowPlayingPill(
      // Rebuilt per app, so a new app fades in.
      key: ValueKey((title, playing)),
      title: title,
      idleIcon: icon,
      playing: playing,
      onPlayPause: () => _press(RemoteKey.mediaPlayPause),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final tv = _controller.tv;
            final muted = tv.muted ?? false;
            return LayoutBuilder(
              builder: (context, constraints) {
                // Short phones get slightly smaller buttons and gaps, so everything fits.
                final compact = constraints.maxHeight < 700;
                final gap = compact ? 12.0 : 16.0;
                final buttonSize = compact ? 56.0 : 64.0;
                // The row's four buttons shrink to fit on narrow phones.
                final rowButtonSize = min(buttonSize, (constraints.maxWidth - 32 - 3 * 8) / 4);
                final listening = _controller.voice != VoiceState.idle;
                final scheme = Theme.of(context).colorScheme;
                return Padding(
                  padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, gap),
                  child: Column(
                    children: [
                      _TopBar(
                        controller: _controller,
                        onDeviceTap: () => showDeviceSheet(context, _controller),
                        onPower: () => _press(RemoteKey.power),
                        onModeChanged: _controller.setMode,
                        onCast: PhoneControls.isSupported ? _castScreen : null,
                        onSettings: _openSettings,
                      ),
                      _StatusBanner(
                        controller: _controller,
                        onChooseDevice: () => showDeviceSheet(context, _controller),
                        onPair: _pair,
                      ),
                      SizedBox(height: gap),
                      // While listening, the now-playing pill makes way for
                      // voice search, so small phones keep room for the D-pad.
                      SizedBox(
                        height: 48,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: listening
                              ? _VoiceBar(voice: _controller.voice, onStop: _controller.stopVoice)
                              : _nowPlaying(),
                        ),
                      ),
                      SizedBox(height: gap),
                      Expanded(
                        child: AnimatedOpacity(
                          opacity: _controller.isConnected ? 1 : 0.5,
                          duration: const Duration(milliseconds: 200),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: switch (_controller.mode) {
                              ControlMode.dpad => LayoutBuilder(
                                key: const ValueKey(ControlMode.dpad),
                                builder: (context, constraints) {
                                  final size = max(
                                    0.0,
                                    min(
                                      min(constraints.maxWidth - 32, constraints.maxHeight),
                                      340.0,
                                    ),
                                  );
                                  return Center(
                                    child: DPad(size: size, onKey: _press),
                                  );
                                },
                              ),
                              ControlMode.swipe => Padding(
                                key: const ValueKey(ControlMode.swipe),
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: SwipePad(onKey: _step),
                              ),
                            },
                          ),
                        ),
                      ),
                      SizedBox(height: gap + 4),
                      AnimatedOpacity(
                        opacity: _controller.isConnected ? 1 : 0.5,
                        duration: const Duration(milliseconds: 200),
                        child: Column(
                          children: [
                            if (_controller.mediaControlsEnabled) ...[
                              MediaControls(height: compact ? 44 : 52, onKey: _press),
                              SizedBox(height: gap),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                RemoteButton(
                                  label: 'Back',
                                  width: rowButtonSize,
                                  height: rowButtonSize,
                                  onPressed: () => _press(RemoteKey.back),
                                  child: const Icon(Icons.arrow_back),
                                ),
                                RemoteButton(
                                  label: 'Home',
                                  width: rowButtonSize,
                                  height: rowButtonSize,
                                  onPressed: () => _press(RemoteKey.home),
                                  child: const Icon(Icons.home_outlined),
                                ),
                                RemoteButton(
                                  label: listening ? 'Stop voice search' : 'Voice search',
                                  width: rowButtonSize,
                                  height: rowButtonSize,
                                  color: listening ? scheme.primary : null,
                                  foregroundColor: listening ? scheme.onPrimary : null,
                                  onPressed: _onMicPressed,
                                  child: Icon(listening ? Icons.mic : Icons.mic_none),
                                ),
                                RemoteButton(
                                  label: 'Keyboard',
                                  width: rowButtonSize,
                                  height: rowButtonSize,
                                  color: _controller.canType ? scheme.primaryContainer : null,
                                  foregroundColor: _controller.canType
                                      ? scheme.onPrimaryContainer
                                      : null,
                                  onPressed: _onKeyboardPressed,
                                  child: const Icon(Icons.keyboard_outlined),
                                ),
                              ],
                            ),
                            SizedBox(height: gap),
                            VolumeRocker(
                              height: buttonSize,
                              level: tv.volumeLevel,
                              muted: muted,
                              onVolumeDown: () => _press(RemoteKey.volumeDown),
                              onVolumeUp: () => _press(RemoteKey.volumeUp),
                              onMute: () => _press(RemoteKey.volumeMute),
                            ),
                            SizedBox(height: gap),
                            AppShortcuts(
                              height: compact ? 44 : 48,
                              onLaunch: _launch,
                              onSetUp: (app) => showAppKeySetup(context, _controller, app),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

enum _MenuItem { dpad, swipe, settings }

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.onDeviceTap,
    required this.onPower,
    required this.onModeChanged,
    required this.onCast,
    required this.onSettings,
  });

  final RemoteController controller;
  final VoidCallback onDeviceTap;
  final VoidCallback onPower;
  final ValueChanged<ControlMode> onModeChanged;

  /// Null where the phone's screen can't be cast.
  final VoidCallback? onCast;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, color) = switch (controller.status) {
      ConnectionStatus.noDevice => ('Tap to choose a TV', scheme.onSurfaceVariant),
      ConnectionStatus.preparing => ('Setting up a secure connection…', scheme.onSurfaceVariant),
      ConnectionStatus.connecting => ('Connecting…', scheme.onSurfaceVariant),
      ConnectionStatus.connected => ('Connected', scheme.primary),
      ConnectionStatus.disconnected => ('Not connected', scheme.error),
      ConnectionStatus.needsPairing => ('Needs pairing', scheme.error),
    };
    final busy =
        controller.status == ConnectionStatus.connecting ||
        controller.status == ConnectionStatus.preparing;

    return Row(
      children: [
        Expanded(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onDeviceTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.tv, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  controller.device?.name ?? 'No TV selected',
                                  style: theme.textTheme.titleMedium,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Icon(Icons.expand_more, size: 20, color: scheme.onSurfaceVariant),
                            ],
                          ),
                          Row(
                            children: [
                              if (busy)
                                const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: SizedBox.square(
                                    dimension: 10,
                                    child: CircularProgressIndicator(strokeWidth: 1.5),
                                  ),
                                )
                              else
                                Container(
                                  width: 8,
                                  height: 8,
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                                ),
                              Flexible(
                                child: Text(
                                  label,
                                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (onCast case final onCast?)
          IconButton(tooltip: 'Cast screen', icon: const Icon(Icons.cast), onPressed: onCast),
        PopupMenuButton<_MenuItem>(
          tooltip: 'More options',
          icon: const Icon(Icons.more_vert),
          onSelected: (item) => switch (item) {
            _MenuItem.dpad => onModeChanged(ControlMode.dpad),
            _MenuItem.swipe => onModeChanged(ControlMode.swipe),
            _MenuItem.settings => onSettings(),
          },
          itemBuilder: (context) => [
            for (final (item, mode, icon, text) in [
              (_MenuItem.dpad, ControlMode.dpad, Icons.gamepad_outlined, 'D-pad'),
              (_MenuItem.swipe, ControlMode.swipe, Icons.swipe, 'Swipe'),
            ])
              PopupMenuItem(
                value: item,
                child: Row(
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(text)),
                    if (mode == controller.mode) Icon(Icons.check, size: 20, color: scheme.primary),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: _MenuItem.settings,
              child: Row(
                children: [
                  Icon(Icons.settings_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('Settings'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(width: 8),
        RemoteButton(
          label: 'Power',
          width: 56,
          height: 56,
          color: scheme.errorContainer,
          foregroundColor: scheme.onErrorContainer,
          onPressed: onPower,
          child: const Icon(Icons.power_settings_new),
        ),
      ],
    );
  }
}

/// Explains why the remote isn't usable yet and offers the fix.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.controller,
    required this.onChooseDevice,
    required this.onPair,
  });

  final RemoteController controller;
  final VoidCallback onChooseDevice;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final name = controller.device?.name ?? 'your TV';
    final content = switch (controller.status) {
      ConnectionStatus.noDevice => (
        Icons.search,
        'Choose the TV you want to control.',
        'Choose TV',
        onChooseDevice,
      ),
      ConnectionStatus.needsPairing => (
        Icons.link,
        'Pair with $name to start. A code will appear on the TV.',
        'Pair',
        onPair,
      ),
      ConnectionStatus.disconnected => (
        Icons.wifi_off,
        "${controller.message ?? "Can't reach $name."} Is it on and on the same Wi-Fi?",
        'Retry',
        controller.retry,
      ),
      _ => null,
    };

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: content == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card.filled(
                margin: EdgeInsets.zero,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Icon(content.$1),
                      const SizedBox(width: 12),
                      Expanded(child: Text(content.$2)),
                      const SizedBox(width: 8),
                      FilledButton.tonal(onPressed: content.$4, child: Text(content.$3)),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// Shows that the phone is listening for voice search, with a way to stop.
class _VoiceBar extends StatelessWidget {
  const _VoiceBar({required this.voice, required this.onStop});

  final VoiceState voice;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Icon(Icons.mic, color: scheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              voice == VoiceState.starting ? 'Starting voice search…' : 'Listening… speak now',
              style: theme.textTheme.titleSmall?.copyWith(color: scheme.onPrimaryContainer),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          FilledButton(onPressed: onStop, child: const Text('Done')),
        ],
      ),
    );
  }
}
