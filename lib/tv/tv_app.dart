import 'package:flutter/foundation.dart';

/// Streaming apps the remote can open directly.
enum TvApp {
  netflix('Netflix', 'com.netflix.ninja', 'https://www.netflix.com/title'),
  youtube('YouTube', 'com.google.android.youtube.tv', 'https://www.youtube.com'),
  primeVideo('Prime Video', 'com.amazon.amazonvideo.livingroom', 'https://app.primevideo.com');

  const TvApp(this.label, this.packageName, this.link);

  final String label;

  /// The Android TV package, for reference: what the TV reports once the app is open.
  final String packageName;

  /// A web link the app is registered to handle, so the TV opens the app itself.
  ///
  /// Not `market://launch?id=…`: that goes through the Play Store, and a TCL TV
  /// with a custom launcher answered it with an error and dropped the connection.
  final String link;
}

/// An app the TV reports as open, by its Android TV package.
@immutable
class OpenApp {
  const OpenApp(this.package);

  final String package;

  static const _names = {
    'com.netflix.ninja': 'Netflix',
    'com.google.android.youtube.tv': 'YouTube',
    'com.google.android.youtube.tvkids': 'YouTube Kids',
    'com.google.android.youtube.tvmusic': 'YouTube Music',
    'com.amazon.amazonvideo.livingroom': 'Prime Video',
    'com.disney.disneyplus': 'Disney+',
    'com.apple.atve.androidtv.appletv': 'Apple TV',
    'com.hulu.livingroomplus': 'Hulu',
    'com.wbd.stream': 'Max',
    'com.spotify.tv.android': 'Spotify',
    'com.plexapp.android': 'Plex',
    'org.xbmc.kodi': 'Kodi',
    'org.videolan.vlc': 'VLC',
    'tv.twitch.android.app': 'Twitch',
    'com.android.tv.settings': 'Settings',
    'com.android.vending': 'Play Store',
  };

  static const _launchers = {
    'com.google.android.apps.tv.launcherx', // Google TV home
    'com.google.android.tvlauncher', // Android TV home
    'com.google.android.leanbacklauncher',
    'com.spocky.projengmenu', // Projectivy Launcher
  };

  /// Apps without anything to play, so media keys aren't offered.
  static const _withoutMedia = {'com.android.tv.settings', 'com.android.vending'};

  /// Packages the TV reports while drawing over another app, rather than
  /// switching to them: the remote service itself and the voice search screen.
  static const overlays = {'com.google.android.tv.remote.service', 'com.google.android.katniss'};

  bool get isHome => _launchers.contains(package) || package.contains('launcher');

  /// A name to show; the package itself for apps the remote doesn't know.
  String get name => isHome ? 'Home' : _names[package] ?? package;

  /// Whether play/pause and seeking are likely to do something here.
  bool get playsMedia => !isHome && !_withoutMedia.contains(package);

  @override
  bool operator ==(Object other) => other is OpenApp && other.package == package;

  @override
  int get hashCode => package.hashCode;
}
