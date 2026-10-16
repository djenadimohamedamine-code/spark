import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Distance du GPS au segment de route le plus proche (pas seulement
/// aux sommets du polyligne OSRM).
class GpsRouteGeometry {
  GpsRouteGeometry._();

  static double distanceMetersToPolyline(LatLng point, List<LatLng> route) {
    if (route.isEmpty) return double.infinity;
    const metersPerDegree = 111195.0;
    final cosLatitude = math.cos(point.latitude * math.pi / 180).abs();
    final xScale = metersPerDegree * cosLatitude;

    double x(LatLng p) => (p.longitude - point.longitude) * xScale;
    double y(LatLng p) => (p.latitude - point.latitude) * metersPerDegree;

    var prevX = x(route.first);
    var prevY = y(route.first);
    var bestSq = prevX * prevX + prevY * prevY;

    for (var i = 1; i < route.length; i++) {
      final nextX = x(route[i]);
      final nextY = y(route[i]);
      final dx = nextX - prevX;
      final dy = nextY - prevY;
      final denom = dx * dx + dy * dy;
      final fraction = denom > 0
          ? (-(prevX * dx + prevY * dy) / denom).clamp(0.0, 1.0)
          : 0.0;
      final nearX = prevX + fraction * dx;
      final nearY = prevY + fraction * dy;
      bestSq = math.min(bestSq, nearX * nearX + nearY * nearY);
      prevX = nextX;
      prevY = nextY;
    }
    return math.sqrt(bestSq);
  }
}

/// Annule l'effet des réponses HTTP reçues après un changement de destination
/// ou un abandon de navigation.
class GpsRouteRequestGuard {
  int _generation = 0;

  int begin() => ++_generation;
  void invalidate() { _generation++; }
  bool isCurrent(int id) => id == _generation;
}
