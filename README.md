# TV Remote

A phone remote for Google TV and Android TV, built with Flutter (Android and iOS).
It uses the same protocol as the official Google TV app, so it works with any
TV that the Google TV app can control. Nothing needs to be installed on the TV.

## Features

- **Power** on/off (toggle). Also shows when the TV is in standby.
- **Navigation** in two modes, switchable at any time (the choice is remembered):
  - **D-pad**: up, down, left, right and OK. Hold a direction to repeat it.
  - **Swipe**: a touchpad. Drag to move one step per ~44 px (a long drag scrolls
    through several items), flick to move once, tap for OK.
- **Volume** up/down (hold to repeat) and **mute**. Shows the TV's volume level when it reports one.
- **Phone volume buttons** change the TV's volume while the app is open and connected
  (Android; on by default, switch off in **Settings**). When the TV isn't connected they
  change the phone's volume as usual.
- **Home** and **Back**.
- **Media controls** (off by default, **Settings › Advanced**): previous, rewind,
  play/pause, fast-forward and next buttons above Back and Home.
- **Voice search**: tap the mic and say what you want, like "funny cat videos". The
  phone's microphone streams to the TV's own voice search, which decides when you've
  finished and shows the results (it stops listening after 15 seconds at most, or
  tap **Done**). This also works where typing doesn't, such as YouTube.
- **What's open**: a pill shows the app open on the TV. While an app that plays
  media is open it animates, and tapping it plays or pauses.
- **Netflix**, **YouTube** and **Prime Video** buttons that open those apps on the TV.
- **Typing**: when a text box is selected on the TV, the phone's keyboard opens and
  text appears on the TV as you type, including edits and deletions. The TV shows
  "Use the keyboard on your mobile device" while the app is open. Apps that draw their
  own on-screen keyboard (YouTube, for example) don't use this, so it can't type there.
  Confirm the text on the TV with the remote; the TV ignores Enter sent this way.
- **Screen cast** (Android): the cast button in the top bar opens the phone's own
  screen-cast list (Settings › Cast), where Google TVs appear; tap one to mirror the
  phone. Phones without that screen (some Samsung and Xiaomi models) get instructions
  for their Quick Settings tile (Smart View, Cast or Screen mirroring) instead. Mirroring
  is done by the phone itself, so the app doesn't need to stay open.
- **Several TVs**: tap the TV name at the top to switch. Every TV you've used is listed
  under *Your TVs*, where its ⋮ menu renames or removes it. Each TV is paired once.
  If the router gives a saved TV a new address, the picker follows it there.
- Finds TVs on the Wi-Fi automatically (mDNS), or you can type the TV's IP address.
- Remembers the TVs and reconnects automatically, including after the app returns
  from the background or the Wi-Fi drops.

## Running it

```bash
flutter pub get
flutter run            # with a phone connected, or an emulator running
flutter build apk --release --split-per-abi   # phone APKs in build/app/outputs/flutter-apk/
```

The phone and the TV must be on the same network. Discovery doesn't work in the
Android emulator (it sits behind NAT), but typing the TV's IP address does.

### First connection

1. Open the app and pick your TV from the list (or enter its IP address: on the
   TV, **Settings › Network & Internet ›** your network).
2. The TV shows a 6-character code. Type it into the app.
3. Done. The pairing is remembered; you won't be asked again unless the TV is
   reset or its Android TV Remote Service data is cleared.

### Turning the TV on

The power button sends the same key as a physical remote. It can wake the TV
from **standby**, because the TV keeps its remote service running on the
network. If the TV is fully powered off or in a deep "eco" mode, nothing on the
network can reach it. On most TVs a setting such as *Network standby*,
*Wake on LAN* or *Quick start* keeps it reachable (the name varies by manufacturer).

## How it works

The TV runs Google's "Android TV Remote Service", which listens on two TLS ports:

| Port | Purpose | Messages |
|------|---------|----------|
| 6467 | Pairing ("polo" protocol) | `polo.proto` `OuterMessage` |
| 6466 | Remote control | `remotemessage.proto` `RemoteMessage` |

Each message is a protobuf, prefixed with its varint-encoded length.

1. **Identity.** On first use the app generates a self-signed RSA-2048
   certificate (in a background isolate) and stores it. Every connection
   presents this certificate.
2. **Pairing.** The app sends a pairing request, offers a 6-digit hexadecimal code
   as the "input" role, and the TV displays the code. The secret sent back is
   `SHA-256(client modulus ‖ client exponent ‖ TV modulus ‖ TV exponent ‖ code[1..2])`;
   the first byte of the code is a check byte, so most typos are caught locally
   and can be corrected without restarting.
3. **Remote session.** After the configure / set-active handshake, the TV
   reports its power state and volume, pings every 5 s (the app replies, and
   treats 16 s of silence as a dropped connection), and accepts key presses as
   Android key codes (`KEYCODE_POWER` = 26, `KEYCODE_DPAD_UP` = 19, and so on).
4. **Voice search.** The Search key (84) makes the TV open its voice search and
   send `remote_voice_begin` with a session id and the voice app's package
   (`com.google.android.katniss`). The app echoes the session id back, then
   streams `remote_voice_payload` messages of 16-bit PCM, mono, 8 kHz audio
   (recorded at 16 kHz, which every phone supports, and halved). On a TCL TV,
   speech in 8 KiB messages was ignored while 20 KiB messages were recognised, so
   audio is always sent in 20 KiB messages, the last one padded with silence. The
   TV detects the end of speech itself: it sends a voice message back or switches
   away from its voice app, and the app stops recording then. `remote_voice_end`
   is only sent when the user taps Done.
5. **Open app.** Whenever focus moves, the TV sends `remote_ime_key_inject` with the
   focused app's package. While switching it passes through other apps, and the
   voice screen and the remote service itself report as focused while drawn on top,
   so the app ignores those two and only shows an app once it has stayed for a second.
6. **Apps.** The app buttons send an app-link message with a web link each app
   is registered for (`https://www.netflix.com/title`, `https://www.youtube.com`,
   `https://app.primevideo.com`), so the TV opens the app itself. On a TCL TV,
   `market://launch?id=<package>` links got an error and a dropped connection,
   while these web links opened all three apps. Long-press an app button to
   choose one of the TV's app keys instead, for TVs that don't accept links.

The protocol details follow the open-source
[androidtvremote2](https://github.com/tronikos/androidtvremote2) library, which
the field numbers, feature flags and pairing hash were checked against.

## Code layout

```
lib/
  main.dart                  App entry and theme (follows the system light/dark setting)
  remote_controller.dart     App state: selected TV, connection lifecycle, retries, pairing,
                             voice search, open app, settings
  voice_input.dart           Microphone recording, converted to the TV's audio format
  phone_controls.dart        Phone volume buttons and screen cast, via MainActivity.kt (Android)
  tv/
    proto.dart               Minimal protobuf encoder/decoder and length-prefixed framing
    certificate.dart         Client certificate generation, RSA key extraction, pairing secret
    pairing.dart             Pairing session (port 6467)
    remote_connection.dart   Remote control session (port 6466): keys, the focused text box and
                             app, and voice sessions
    text_input.dart          Turns phone typing into the TV's text edits, one at a time
    key_codes.dart           Android key codes and press directions
    tv_app.dart              Streaming apps the remote can open, and names of apps the TV reports
    discovery.dart           mDNS discovery of `_androidtvremote2._tcp`
  ui/
    remote_screen.dart       Main screen: status, power, cast, menu, media keys, buttons, volume
    settings_screen.dart     Settings: phone volume buttons, Advanced › media controls
    media_controls.dart      Previous / rewind / play-pause / fast-forward / next row
    cast_help.dart           How to cast when the phone has no cast screen to open
    dpad.dart                Circular D-pad with OK in the centre
    swipe_pad.dart           Touchpad navigation
    remote_button.dart       Touch-down buttons with hold-to-repeat, volume rocker
    app_shortcuts.dart       Netflix / YouTube / Prime Video buttons
    device_sheet.dart        TV picker: saved TVs (switch, rename, remove), discovered, manual IP
    pairing_dialog.dart      Pairing code entry
    typing_sheet.dart        Keyboard panel for typing on the TV
test/
  support/fake_tv.dart       A fake TV that speaks both protocols over real TLS sockets
  tv_protocol_test.dart      Pairing, connecting, keys, pings, reconnects, against the fake TV
  text_input_test.dart       Text edits, fast typing and the TV's text box, against the fake TV
  voice_input_test.dart      Halving the microphone's sample rate
  pairing_secret_test.dart   Known-answer test for the pairing hash
  proto_test.dart            Wire-format encoding and framing
  saved_tvs_test.dart        Saving, renaming, moving and removing TVs; settings
  widget_test.dart           D-pad zones, swipe gestures, buttons, pairing dialog, settings,
                             volume buttons, cast, TV picker
tool/
  diagnose_test.dart         Checks a real TV: its features and which app links it accepts
  feature_probe_test.dart    Checks a real TV: device info, open-app reports, voice session start
  typing_check_test.dart     Checks typing on a real TV
  voice_check_test.dart      Checks voice search on a real TV with a recorded WAV
```

Run the tests with `flutter test`.

## Notes

- The pairing certificate and private key are stored with `shared_preferences`.
  They only grant control of TVs this phone has paired with.
- Android app id is `com.example.tv_remote`. Change `applicationId` in
  `android/app/build.gradle.kts` (and the iOS bundle id) before publishing.
- On iOS, the first scan triggers the system's local network permission prompt.
- The microphone permission is asked for the first time the mic button is tapped.
  Audio is only recorded while voice search is listening, and goes only to the TV.
- Android 6.0 or newer is required (the `record` package's minimum).
