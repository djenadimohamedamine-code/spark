import 'dart:math' as math;

/// Filtre de cap GPS commun aux cartes normale et experte.
///
/// Le cap iOS/Android est prioritaire quand il est valide. Sinon le cap est
/// calculé sur une distance ACCUMULÉE fiable (jamais entre deux fixes à 1 m),
/// pour rester correct pendant un demi-tour quand le cap natif est absent.
class GpsFix {
  final double latitude;
  final double longitude;
  final double speedKmh;
  final double headingDegrees;
  final double accuracyMeters;

  const GpsFix({
    required this.latitude,
    required this.longitude,
    required this.speedKmh,
    required this.headingDegrees,
    required this.accuracyMeters,
  });
}

class GpsHeadingUpdate {
  final double headingDegrees;
  final double stepMeters;
  final double anchorMeters;
  final String source;
  final bool reliable;

  const GpsHeadingUpdate({
    required this.headingDegrees,
    required this.stepMeters,
    required this.anchorMeters,
    required this.source,
    required this.reliable,
  });
}

class GpsHeadingTracker {
  double _heading = 0;
  bool _hasReliableHeading = false;
  GpsFix? _previous;
  GpsFix? _anchor;
  double _traveledFromAnchor = 0;

  double get heading => _heading;

  static double _normalize(double angle) => (angle % 360 + 360) % 360;

  static double _smooth(double previous, double target, {double alpha = 0.25}) {
    var delta = _normalize(target) - previous;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    return _normalize(previous + delta * alpha);
  }

  static double _distanceMeters(GpsFix a, GpsFix b) {
    const radius = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final rLat1 = a.latitude * math.pi / 180;
    final rLat2 = b.latitude * math.pi / 180;
    final hav = math.pow(math.sin(dLat / 2), 2).toDouble() +
        math.cos(rLat1) * math.cos(rLat2) *
            math.pow(math.sin(dLon / 2), 2).toDouble();
    return 2 * radius * math.asin(math.sqrt(hav.clamp(0.0, 1.0)));
  }

  static double _bearingDegrees(GpsFix a, GpsFix b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final deltaLon = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(deltaLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLon);
    return _normalize(math.atan2(y, x) * 180 / math.pi);
  }

  GpsHeadingUpdate update(GpsFix fix) {
    if (!fix.latitude.isFinite || !fix.longitude.isFinite ||
        fix.latitude.abs() > 90 || fix.longitude.abs() > 180) {
      return GpsHeadingUpdate(
        headingDegrees: _heading, stepMeters: 0,
        anchorMeters: _traveledFromAnchor, source: 'invalid_fix',
        reliable: _hasReliableHeading,
      );
    }

    final previous = _previous;
    final stepMeters = previous == null ? 0.0 : _distanceMeters(previous, fix);
    _previous = fix;
    final speed = fix.speedKmh.isFinite && fix.speedKmh > 0 ? fix.speedKmh : 0.0;
    final nativeValid = fix.headingDegrees.isFinite &&
        fix.headingDegrees >= 0 && fix.headingDegrees <= 360;

    if (speed <= 1.5) {
      // Aucun virage artificiel au feu rouge ou lors de petits sauts GPS.
      _anchor = fix;
      _traveledFromAnchor = 0;
      return GpsHeadingUpdate(
        headingDegrees: _heading, stepMeters: stepMeters,
        anchorMeters: 0, source: 'frozen_slow',
        reliable: _hasReliableHeading,
      );
    }

    if (nativeValid) {
      _heading = _hasReliableHeading
          ? _smooth(_heading, fix.headingDegrees)
          : _normalize(fix.headingDegrees);
      _hasReliableHeading = true;
      _anchor = fix;
      _traveledFromAnchor = 0;
      return GpsHeadingUpdate(
        headingDegrees: _heading, stepMeters: stepMeters,
        anchorMeters: 0, source: 'ios_direct', reliable: true,
      );
    }

    // Un saut GPS > 150m ne doit jamais devenir un faux demi-tour.
    if (stepMeters > 150) {
      _anchor = fix;
      _traveledFromAnchor = 0;
    } else {
      _anchor ??= previous ?? fix;
      _traveledFromAnchor += stepMeters;
    }

    final accuracy = fix.accuracyMeters;
    if (_anchor != null && accuracy.isFinite && accuracy >= 0 &&
        accuracy <= 50) {
      final minDistance = math.max(5.0, accuracy * 1.5);
      final netDistance = _distanceMeters(_anchor!, fix);
      if (_traveledFromAnchor >= minDistance && netDistance >= minDistance) {
        final fallbackHeading = _bearingDegrees(_anchor!, fix);
        _heading = _hasReliableHeading
            ? _smooth(_heading, fallbackHeading, alpha: 0.5)
            : fallbackHeading;
        _hasReliableHeading = true;
        // Glisser l'ancre après chaque mesure fiable pour suivre les virages.
        _anchor = fix;
        _traveledFromAnchor = 0;
        return GpsHeadingUpdate(
          headingDegrees: _heading, stepMeters: stepMeters,
          anchorMeters: 0, source: 'anchor_bearing', reliable: true,
        );
      }
    }
    return GpsHeadingUpdate(
      headingDegrees: _heading, stepMeters: stepMeters,
      anchorMeters: _traveledFromAnchor, source: 'frozen',
      reliable: _hasReliableHeading,
    );
  }
}
