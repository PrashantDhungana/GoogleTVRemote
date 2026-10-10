import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum VolumeButton { up, down }

/// The phone's own features the remote uses: its volume buttons and screen
/// casting. Android only; elsewhere these do nothing.
class PhoneControls {
  PhoneControls({this.onVolumeButton}) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('tv_remote/phone');

  static bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  /// Called for each press of a volume button while [setVolumeButtonsCaptured]
  /// is on, and repeatedly while one is held.
  final ValueChanged<VolumeButton>? onVolumeButton;

  bool? _captured;

  /// While on, the volume buttons stop changing the phone's volume and are
  /// reported to [onVolumeButton] instead.
  Future<void> setVolumeButtonsCaptured(bool captured) async {
    if (!isSupported || captured == _captured) return;
    _captured = captured;
    try {
      await _channel.invokeMethod<void>('captureVolumeButtons', captured);
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException {
      _captured = null;
    }
  }

  /// Opens the phone's screen-cast picker. Returns false if the phone has none
  /// the app can open.
  Future<bool> openScreenCast() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openScreenCast') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'volumeButton') {
      final button = VolumeButton.values.asNameMap()[call.arguments];
      if (button != null) onVolumeButton?.call(button);
    }
    return null;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    if (_captured ?? false) {
      _channel.invokeMethod<void>('captureVolumeButtons', false).catchError((_) {});
    }
  }
}
