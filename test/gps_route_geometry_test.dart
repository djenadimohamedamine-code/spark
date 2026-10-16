import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mimo_spark/core/gps_route_geometry.dart';

void main() {
  group('GPS calcul d itineraire', () {
    test('point au milieu du segment : pas de recalcul a tort', () {
      final route = <LatLng>[
        const LatLng(36.8, 3.05),
        const LatLng(36.8, 3.052),
      ];
      final distance = GpsRouteGeometry.distanceMetersToPolyline(
        const LatLng(36.8001, 3.051), route);
      // ~11 m du segment malgré ~90 m jusqu'aux sommets.
      expect(distance, greaterThan(9));
      expect(distance, lessThan(15));
    });

    test('sortie de route de 200m declenche le seuil 70m', () {
      final route = <LatLng>[
        const LatLng(36.8, 3.05),
        const LatLng(36.8, 3.052),
      ];
      expect(GpsRouteGeometry.distanceMetersToPolyline(
        const LatLng(36.802, 3.051), route), greaterThan(70));
    });

    test('polyline vide, ligne ponctuelle et sommets identiques', () {
      final geometry = GpsRouteGeometry.distanceMetersToPolyline;
      expect(geometry(const LatLng(36.8, 3.05), <LatLng>[]), double.infinity);
      expect(geometry(const LatLng(36.8, 3.05),
          <LatLng>[const LatLng(36.8, 3.05)]), 0);
      expect(geometry(const LatLng(36.8, 3.05),
          <LatLng>[const LatLng(36.8, 3.05), const LatLng(36.8, 3.05)]), 0);
    });

    test('reponse OSRM ancienne ignoree apres nouvelle destination', () {
      final guard = GpsRouteRequestGuard();
      final first = guard.begin();
      expect(guard.isCurrent(first), isTrue);
      final second = guard.begin();
      expect(guard.isCurrent(first), isFalse);
      expect(guard.isCurrent(second), isTrue);
      guard.invalidate();
      expect(guard.isCurrent(second), isFalse);
    });
  });
}
