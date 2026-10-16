import 'dart:math' as math;

/// Orientation of the real Chevrolet Spark cutout used on both map pages.
///
/// The nose of 'Adobe Express - file.png' points roughly 65 degrees
/// counter-clockwise from the top of the image. Both map pages must use
/// the same correction rather than independent guessed values.
///
/// flutter_map Markers use rotate: false, so they already follow any
/// camera rotation. Do NOT subtract camera.rotation a second time.
class VehicleMarkerHeading {
  VehicleMarkerHeading._();

  static const double spriteNoseBearingDegrees = 295.0; // NW: 360 - 65

  static double rotationDegrees(double gpsHeadingDegrees) {
    final rotation = (gpsHeadingDegrees - spriteNoseBearingDegrees) % 360.0;
    return rotation < 0 ? rotation + 360.0 : rotation;
  }

  /// Rotate the map against the heading while following, so the direction
  /// of travel is up. Markers already inherit this rotation from flutter_map.
  static double followingCameraDegrees(double gpsHeadingDegrees) =>
      -((gpsHeadingDegrees % 360 + 360) % 360);

  static double rotationRadians(double gpsHeadingDegrees) =>
      rotationDegrees(gpsHeadingDegrees) * math.pi / 180.0;
}
