import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/tv/certificate.dart';
import 'package:tv_remote/tv/remote_connection.dart';
import 'package:tv_remote/tv/text_input.dart';

import 'support/fake_tv.dart';

/// Applies [edit] the way the TV does, for checking [textEdit] on its own.
String _apply(String text, int cursor, TextEdit edit) => edit.start == edit.end
    ? text.substring(0, cursor) + edit.text + text.substring(cursor)
    : text.substring(0, edit.start) + edit.text + text.substring(edit.end);

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('textEdit', () {
    void check(String from, String to, {int? cursor, TextEdit? expected}) {
      final at = cursor ?? from.length;
      final edit = textEdit(from, at, to);
      expect(_apply(from, at, edit), to, reason: '$from -> $to with $edit');
      if (expected != null) expect(edit, expected);
    }

    test('typing at the end inserts at the cursor', () {
      check('hel', 'hello', expected: (start: 3, end: 3, text: 'lo'));
      check('', 'hi', expected: (start: 0, end: 0, text: 'hi'));
    });

    test('deleting and replacing send a range', () {
      check('hello', 'hell', expected: (start: 4, end: 5, text: ''));
      check('hello', '', expected: (start: 0, end: 5, text: ''));
      check('hello world', 'hello there', expected: (start: 6, end: 11, text: 'there'));
      check('cat', 'cut', expected: (start: 1, end: 2, text: 'u'));
    });

    test('inserting away from the cursor replaces a neighbouring character', () {
      check('hllo', 'hello', expected: (start: 0, end: 1, text: 'he'));
      check('ello', 'hello', expected: (start: 0, end: 1, text: 'he'));
      check('ab', 'aXb', cursor: 2);
      // When the TV's cursor is in the middle, typing there is a plain insert.
      check('ab', 'aXb', cursor: 1, expected: (start: 1, end: 1, text: 'X'));
    });

    test('keeps emoji whole', () {
      check('a😀', 'a😀b');
      check('😀', 'X😀', cursor: 2);
      check('a😀b', 'a😁b', expected: (start: 1, end: 3, text: '😁'));
      check('😀b', '😀Xb', cursor: 3);
    });
  });

  group('typing on the TV', () {
    late ClientIdentity client;
    late ClientIdentity tvIdentity;
    late FakeTv tv;
    late RemoteConnection connection;
    late TextSync sync;

    setUpAll(() async {
      (client, tvIdentity) = await (
        Isolate.run(ClientIdentity.generate),
        Isolate.run(() => ClientIdentity.generate(commonName: 'tv')),
      ).wait;
    });

    setUp(() async {
      tv = await FakeTv.start(tvIdentity: tvIdentity, client: client)
        ..paired = true;
      connection = await RemoteConnection.connect(
        host: '127.0.0.1',
        identity: client,
        port: tv.remotePort,
      );
      sync = TextSync(connection);
    });

    tearDown(() async {
      sync.dispose();
      connection.close();
      await tv.close();
    });

    test('asks the TV to hand typing to the phone', () async {
      expect(tv.activeFeatures! & 4, 4);
    });

    test('follows the text box focused on the TV', () async {
      expect(sync.active, isFalse);
      tv.focusTextField('abc');
      await _until(() => sync.active);
      expect(sync.text, 'abc');

      tv.typeOnTv('abcd');
      await _until(() => sync.text == 'abcd');

      tv.leaveTextField();
      await _until(() => !sync.active);
      expect(sync.text, '');
    });

    test('fast typing reaches the TV in full, with no edit ignored', () async {
      tv.focusTextField();
      await _until(() => sync.active);

      // Every keystroke arrives before the TV has applied the previous one.
      var typed = '';
      for (final char in 'hello world'.split('')) {
        sync.setText(typed += char);
      }
      await _until(() => tv.text == 'hello world');
      expect(tv.staleEdits, 0);
      expect(sync.text, 'hello world');
    });

    test('edits, deletes and clears', () async {
      tv.focusTextField('hello');
      await _until(() => sync.text == 'hello');

      sync.setText('help');
      await _until(() => tv.text == 'help');
      sync.setText('yelp');
      await _until(() => tv.text == 'yelp');
      sync.setText('yelps!');
      sync.setText('yelp');
      await _until(() => tv.text == 'yelp' && sync.text == 'yelp');
      sync.setText('');
      await _until(() => tv.text == '');
      expect(tv.staleEdits, 0);
    });

    test('shows the TV text again if an edit is not applied', () async {
      tv.focusTextField('abc');
      await _until(() => sync.text == 'abc');
      tv.leaveTextField(); // the edit below arrives after the box is gone
      sync.setText('abcd');
      await _until(() => !sync.active);
      expect(sync.text, '');
    });
  });
}
