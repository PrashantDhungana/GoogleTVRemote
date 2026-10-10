import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../tv/tv_app.dart';

/// One-tap buttons that open streaming apps on the TV, showing each app's logo.
class AppShortcuts extends StatelessWidget {
  const AppShortcuts({super.key, required this.onLaunch, required this.onSetUp, this.height = 48});

  final ValueChanged<TvApp> onLaunch;

  /// Long press: choose how the app opens.
  final ValueChanged<TvApp> onSetUp;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final app in TvApp.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _BrandButton(
                app: app,
                height: height,
                onTap: () => onLaunch(app),
                onLongPress: () => onSetUp(app),
              ),
            ),
          ),
      ],
    );
  }
}

/// The pill shape and touch handling shared by every app button.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.longPressHint,
    required this.color,
    required this.height,
    required this.onTap,
    required this.onLongPress,
    required this.child,
  });

  final String label;
  final String longPressHint;
  final Color color;
  final double height;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onLongPressHint: longPressHint,
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Material(
          color: color,
          shape: StadiumBorder(
            // Keeps black and white buttons visible on either theme.
            side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _BrandButton extends StatelessWidget {
  const _BrandButton({
    required this.app,
    required this.height,
    required this.onTap,
    required this.onLongPress,
  });

  final TvApp app;
  final double height;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    // Logo file, logo colour, button colour, and logo height relative to the button.
    final (asset, logoColor, background, scale) = switch (app) {
      TvApp.netflix => ('netflix', const Color(0xFFE50914), const Color(0xFF000000), 0.55),
      TvApp.youtube => ('youtube', const Color(0xFFFF0000), const Color(0xFFFFFFFF), 0.65),
      // The Prime Video logo is a wordmark, so it can be drawn larger.
      TvApp.primeVideo => ('primevideo', const Color(0xFF1399FF), const Color(0xFF0F171E), 1.0),
    };
    return _Pill(
      label: 'Open ${app.label}',
      longPressHint: 'Choose how it opens',
      color: background,
      height: height,
      onTap: onTap,
      onLongPress: onLongPress,
      child: SvgPicture.asset(
        'assets/logos/$asset.svg',
        height: height * scale,
        colorFilter: ColorFilter.mode(logoColor, BlendMode.srcIn),
      ),
    );
  }
}
