import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_spark/core/vehicle_marker_heading.dart';

int _paethPredictor(int left, int above, int upperLeft) {
  final prediction = left + above - upperLeft;
  final leftDiff = (prediction - left).abs();
  final aboveDiff = (prediction - above).abs();
  final cornerDiff = (prediction - upperLeft).abs();
  if (leftDiff <= aboveDiff && leftDiff <= cornerDiff) return left;
  if (aboveDiff <= cornerDiff) return above;
  return upperLeft;
}

void main() {
  test('Real Chevrolet Spark PNG has transparent corners (pure Dart PNG decode)', () async {
    // No dart:ui image codec or testWidgets fake-async: both can hang on CI.
    final png = await File('assets/images/Adobe Express - file.png').readAsBytes();
    expect(png.length, greaterThan(33));
    expect(
      png.sublist(0, 8),
      equals(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
      reason: 'The vehicle asset must be a real PNG.',
    );
    final header = ByteData.sublistView(png);
    final width = header.getUint32(16, Endian.big);
    final height = header.getUint32(20, Endian.big);
    expect(width, greaterThan(0));
    expect(height, greaterThan(0));
    expect(png[24], 8, reason: 'Expect 8-bit PNG channels');
    expect(png[25], 6, reason: 'Expect PNG RGBA, not an opaque RGB screenshot');
    expect(png[28], 0, reason: 'Expect non-interlaced PNG');

    final compressed = BytesBuilder(copy: false);
    int offset = 8;
    while (offset + 12 <= png.length) {
      final length = header.getUint32(offset, Endian.big);
      expect(offset + length + 12, lessThanOrEqualTo(png.length));
      final chunk = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
      if (chunk == 'IDAT') {
        compressed.add(png.sublist(offset + 8, offset + 8 + length));
      }
      offset += length + 12;
      if (chunk == 'IEND') break;
    }
    final pixels = zlib.decode(compressed.takeBytes());
    final scanlineLength = width * 4 + 1;
    expect(pixels.length, height * scanlineLength);

    List<int> previousAlpha = List<int>.filled(width, 0);
    final corners = <int>[];
    for (int y = 0; y < height; y++) {
      final rowStart = y * scanlineLength;
      final filter = pixels[rowStart];
      expect(filter, inInclusiveRange(0, 4), reason: 'Valid PNG row filter');
      final currentAlpha = List<int>.filled(width, 0);
      for (int x = 0; x < width; x++) {
        // Alpha channel is independent of RGB for PNG scanline filters.
        final encodedAlpha = pixels[rowStart + 1 + x * 4 + 3];
        final left = x == 0 ? 0 : currentAlpha[x - 1];
        final above = previousAlpha[x];
        final upperLeft = x == 0 ? 0 : previousAlpha[x - 1];
        int predictor;
        switch (filter) {
          case 1:
            predictor = left;
            break;
          case 2:
            predictor = above;
            break;
          case 3:
            predictor = (left + above) ~/ 2;
            break;
          case 4:
            predictor = _paethPredictor(left, above, upperLeft);
            break;
          default:
            predictor = 0;
        }
        currentAlpha[x] = (encodedAlpha + predictor) & 0xff;
      }
      if (y == 0 || y == height - 1) {
        corners.add(currentAlpha.first);
        corners.add(currentAlpha.last);
      }
      previousAlpha = currentAlpha;
    }
    expect(corners, everyElement(lessThan(16)),
        reason: 'All four sprite corners must be transparent; no fake checkerboard');
  });

  group('Chevrolet Spark car marker orientation', () {
    test('car nose follows cardinal GPS headings with one sprite offset', () {
      expect(VehicleMarkerHeading.rotationDegrees(0), closeTo(65, 0.001));
      expect(VehicleMarkerHeading.rotationDegrees(90), closeTo(155, 0.001));
      expect(VehicleMarkerHeading.rotationDegrees(180), closeTo(245, 0.001));
      expect(VehicleMarkerHeading.rotationDegrees(270), closeTo(335, 0.001));
    });

    test('wrap around heading 359 to 0 without flipping 180 degrees', () {
      expect(VehicleMarkerHeading.rotationDegrees(359), closeTo(64, 0.001));
      expect(VehicleMarkerHeading.rotationDegrees(0), closeTo(65, 0.001));
      expect(VehicleMarkerHeading.rotationDegrees(360), closeTo(65, 0.001));
    });

    test('normalizes negative bearings to the same direction', () {
      expect(VehicleMarkerHeading.rotationDegrees(-10), closeTo(55, 0.001));
      expect(VehicleMarkerHeading.rotationDegrees(350), closeTo(55, 0.001));
    });

    test('returns an angle in radians for Flutter Transform.rotate', () {
      expect(
        VehicleMarkerHeading.rotationRadians(0),
        closeTo(65 * 3.141592653589793 / 180, 0.000001),
      );
    });
    test('following camera keeps photo upright and nose forward for every cap', () {
      for (var heading = 0; heading < 360; heading++) {
        final camera = VehicleMarkerHeading.followingCameraDegrees(
          heading.toDouble(),
        );
        final sprite = VehicleMarkerHeading.rotationDegrees(heading.toDouble());
        // The photo stays at its north-facing correction on screen, even
        // when travelling south. Do not subtract the camera a second time.
        final screenRotation = (camera + sprite + 360) % 360;
        expect(screenRotation, closeTo(65, 0.001));
        final noseOnScreen = (screenRotation +
            VehicleMarkerHeading.spriteNoseBearingDegrees) % 360;
        expect(noseOnScreen, closeTo(0, 0.001));
      }
    });

  });
}
