/// Android `KeyEvent` codes accepted by the TV (`RemoteKeyCode` in remotemessage.proto).
enum RemoteKey {
  home(3),
  back(4),
  dpadUp(19),
  dpadDown(20),
  dpadLeft(21),
  dpadRight(22),
  dpadCenter(23),
  volumeUp(24),
  volumeDown(25),
  power(26),
  search(84),
  mediaPlayPause(85),
  mediaNext(87),
  mediaPrevious(88),
  mediaRewind(89),
  mediaFastForward(90),
  volumeMute(164);

  const RemoteKey(this.code);

  final int code;
}

/// How a key is pressed (`RemoteDirection` in remotemessage.proto).
enum KeyDirection {
  /// Key down, held until [endLong] is sent.
  startLong(1),

  /// Key up after [startLong].
  endLong(2),

  /// A complete press: key down then key up.
  short(3);

  const KeyDirection(this.value);

  final int value;
}

/// Keys that physical remotes send from their app buttons (Netflix, YouTube…).
/// Which app each one opens is decided by the TV maker, so the user picks.
const appKeyCandidates = <(String name, int code)>[
  ('Video app 1', 289),
  ('Video app 2', 290),
  ('Video app 3', 291),
  ('Video app 4', 292),
  ('Video app 5', 293),
  ('Video app 6', 294),
  ('Video app 7', 295),
  ('Video app 8', 296),
  ('Featured app 1', 297),
  ('Featured app 2', 298),
  ('Featured app 3', 299),
  ('Featured app 4', 300),
  ('Red', 183),
  ('Green', 184),
  ('Yellow', 185),
  ('Blue', 186),
  ('Explorer', 64),
  ('Bookmark', 174),
];
