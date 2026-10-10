import 'dart:async';

import 'package:flutter/foundation.dart';

import 'remote_connection.dart';

/// One edit for [RemoteConnection.replaceText].
typedef TextEdit = ({int start, int end, String text});

/// The smallest edit that turns [from] into [to] on the TV.
///
/// The TV inserts at its own cursor when the range is empty, ignoring where
/// the range is. So an insertion anywhere else replaces a neighbouring
/// character together with the new text.
TextEdit textEdit(String from, int cursor, String to) {
  var prefix = 0;
  final shorter = from.length < to.length ? from.length : to.length;
  while (prefix < shorter && from.codeUnitAt(prefix) == to.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shorter - prefix &&
      from.codeUnitAt(from.length - 1 - suffix) == to.codeUnitAt(to.length - 1 - suffix)) {
    suffix++;
  }
  // Don't split an emoji or other surrogate pair.
  if (prefix > 0 && _isHighSurrogate(from.codeUnitAt(prefix - 1))) prefix--;
  if (suffix > 0 && _isLowSurrogate(from.codeUnitAt(from.length - suffix))) suffix--;

  final end = from.length - suffix;
  final text = to.substring(prefix, to.length - suffix);
  if (prefix < end || prefix == cursor || from.isEmpty) {
    return (start: prefix, end: end, text: text);
  }
  if (prefix > 0) {
    final before = _isLowSurrogate(from.codeUnitAt(prefix - 1)) && prefix > 1 ? 2 : 1;
    return (
      start: prefix - before,
      end: prefix,
      text: from.substring(prefix - before, prefix) + text,
    );
  }
  final after = _isHighSurrogate(from.codeUnitAt(0)) && from.length > 1 ? 2 : 1;
  return (start: 0, end: after, text: text + from.substring(0, after));
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Keeps the TV's focused text box matching what the user types on the phone.
///
/// Sends one edit at a time and waits for the TV to apply it, because each
/// edit must carry the counter the TV reports after the previous one. Typing
/// in the meantime is merged into the next edit.
class TextSync extends ChangeNotifier {
  TextSync(this._connection) {
    _connection.textField.addListener(_onTvChanged);
    _onTvChanged();
  }

  /// How long to wait for the TV to apply an edit before giving up on it.
  static const _editTimeout = Duration(seconds: 1);

  final RemoteConnection _connection;
  String _text = '';
  String? _expected;
  Timer? _timeout;
  bool _disposed = false;

  /// Whether a text box on the TV is waiting for typing.
  bool get active => _connection.textField.value != null;

  /// The text as the user should see it: theirs while edits are on the way,
  /// otherwise the TV's.
  String get text => _text;

  /// Makes the TV's text box read [text].
  void setText(String text) {
    if (!active || text == _text) return;
    _text = text;
    _push();
  }

  void _push() {
    final field = _connection.textField.value;
    if (field == null || _expected != null || field.text == _text) return;
    final edit = textEdit(field.text, field.cursor, _text);
    _expected = _text;
    _timeout = Timer(_editTimeout, () {
      // The TV didn't apply it. Show what the TV has rather than retrying forever.
      _expected = null;
      _text = _connection.textField.value?.text ?? '';
      _notify();
    });
    _connection.replaceText(edit.start, edit.end, edit.text);
  }

  void _onTvChanged() {
    final field = _connection.textField.value;
    if (field == null) {
      _settle();
      _text = '';
    } else if (_expected == null) {
      _text = field.text;
    } else if (field.text == _expected) {
      // Inserted text arrives a character at a time; this is the last one.
      _settle();
      _push();
    }
    _notify();
  }

  void _settle() {
    _timeout?.cancel();
    _expected = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timeout?.cancel();
    _connection.textField.removeListener(_onTvChanged);
    super.dispose();
  }
}
