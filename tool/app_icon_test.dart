// Renders the app icon (see app_icon.dart) into the Android and iOS icon
// files. Run from the project root after changing the design:
//   flutter test tool/app_icon_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'app_icon.dart';

const _androidRes = 'android/app/src/main/res';
const _iosIcons = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';

/// Android densities and their scale from mdpi.
const _densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};

/// How large the D-pad is drawn on an adaptive icon layer. Launchers show
/// only the middle 72 of its 108 dp, so this keeps a comfortable margin.
const _adaptiveScale = 0.72;

Future<Image> _render(int size, void Function(Canvas canvas, double size) paint) {
  final recorder = PictureRecorder();
  paint(Canvas(recorder), size.toDouble());
  return recorder.endRecording().toImage(size, size);
}

Future<void> _writePng(Image image, String path) async {
  final png = await image.toByteData(format: ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
}

/// Writes an opaque image as an RGB PNG: the App Store rejects icons with an
/// alpha channel, and dart:ui only encodes RGBA.
Future<void> _writeOpaquePng(Image image, String path) async {
  final rgba = (await image.toByteData(format: ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final width = image.width;
  final raw = BytesBuilder();
  for (var y = 0; y < image.height; y++) {
    raw.addByte(0); // No filter.
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      raw.add(rgba.sublist(i, i + 3));
    }
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, image.height)
    ..setUint8(8, 8) // Bit depth.
    ..setUint8(9, 2); // Truecolor, no alpha.
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', header.buffer.asUint8List()))
    ..add(_chunk('IDAT', ZLibEncoder(level: 9).convert(raw.takeBytes())))
    ..add(_chunk('IEND', const []));
  File(path).writeAsBytesSync(out.takeBytes());
}

List<int> _chunk(String type, List<int> data) {
  final typeAndData = [...ascii.encode(type), ...data];
  return [
    ...(ByteData(4)..setUint32(0, data.length)).buffer.asUint8List(),
    ...typeAndData,
    ...(ByteData(4)..setUint32(0, _crc32(typeAndData))).buffer.asUint8List(),
  ];
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

void main() {
  test('writes the Android icons', () async {
    for (final MapEntry(key: density, value: factor) in _densities.entries) {
      final dir = '$_androidRes/mipmap-$density';
      final layer = (108 * factor).round();
      await _writePng(
        await _render(layer, (canvas, size) => paintBackground(canvas, size)),
        '$dir/ic_launcher_background.png',
      );
      await _writePng(
        await _render(
          layer,
          (canvas, size) => paintForeground(canvas, size, scale: _adaptiveScale),
        ),
        '$dir/ic_launcher_foreground.png',
      );
      await _writePng(
        await _render(
          layer,
          (canvas, size) => paintForeground(canvas, size, scale: _adaptiveScale, mono: true),
        ),
        '$dir/ic_launcher_monochrome.png',
      );
      // Android 7 and earlier: a rounded square, inset like other legacy icons.
      await _writePng(
        await _render((48 * factor).round(), (canvas, size) {
          final square = Rect.fromLTWH(0, 0, size, size).deflate(size / 24);
          canvas.clipRRect(RRect.fromRectAndRadius(square, Radius.circular(square.width * 0.22)));
          paintBackground(canvas, size);
          paintForeground(canvas, size, scale: 0.85);
        }),
        '$dir/ic_launcher.png',
      );
    }
    Directory('$_androidRes/mipmap-anydpi-v26').createSync();
    File('$_androidRes/mipmap-anydpi-v26/ic_launcher.xml').writeAsStringSync('''
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
''');
  });

  test('writes the iOS icons', () async {
    final contents =
        jsonDecode(File('$_iosIcons/Contents.json').readAsStringSync()) as Map<String, dynamic>;
    final sizes = <String, int>{};
    for (final image in (contents['images'] as List).cast<Map<String, dynamic>>()) {
      final points = double.parse((image['size'] as String).split('x').first);
      final scale = int.parse((image['scale'] as String).replaceAll('x', ''));
      sizes[image['filename'] as String] = (points * scale).round();
    }
    for (final MapEntry(key: file, value: pixels) in sizes.entries) {
      // iOS rounds the corners itself, so the icon is a full square.
      await _writeOpaquePng(
        await _render(pixels, (canvas, size) {
          paintBackground(canvas, size);
          paintForeground(canvas, size);
        }),
        '$_iosIcons/$file',
      );
    }
  });
}
