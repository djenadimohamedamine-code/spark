import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_spark/core/gps_heading_tracker.dart';

GpsFix fix(double lat, double lon, {double kmh = 15, double heading = -1,
    double accuracy = 5}) => GpsFix(
  latitude: lat,
  longitude: lon,
  speedKmh: kmh,
  headingDegrees: heading,
  accuracyMeters: accuracy,
);

void main() {
  group('GpsHeadingTracker - cap reel dans MapPage et ExpertMapPage', () {
    test('cap 0 nord reste valide, sans rebond a 360', () {
      final t = GpsHeadingTracker();
      final first = t.update(fix(36.8, 3.05, heading: 0));
      expect(first.source, 'ios_direct');
      expect(first.headingDegrees, 0);
      expect(t.update(fix(36.80001, 3.05, heading: 359)).headingDegrees, greaterThan(350));
      final wrap = t.update(fix(36.80002, 3.05, heading: 1));
      // 359° et 1° sont voisins : le lissage doit rester près du nord.
      final distanceToNorth = wrap.headingDegrees < 180
          ? wrap.headingDegrees : 360 - wrap.headingDegrees;
      expect(distanceToNorth, lessThan(2));
    });

    test('reprise de cap apres demi-tour avec fixes de seulement 1m', () {
      final t = GpsHeadingTracker();
      t.update(fix(36.8, 3.05, heading: 0));
      var foundFallback = false;
      for (var i = 1; i <= 60; i++) {
        final u = t.update(fix(36.8 - i / 111320, 3.05));
        if (u.source == 'anchor_bearing') foundFallback = true;
      }
      expect(foundFallback, isTrue);
      expect(t.heading, closeTo(180, 2));
    });

    test('GPS imprecis et position stationnaire ne font pas tourner la voiture', () {
      final t = GpsHeadingTracker();
      t.update(fix(36.8, 3.05, heading: 90));
      for (var i = 1; i <= 30; i++) {
        t.update(fix(36.8 + i / 111320, 3.05, kmh: 0.2, accuracy: 5));
      }
      expect(t.heading, 90);
      for (var i = 31; i <= 45; i++) {
        final u = t.update(fix(36.8 + i / 111320, 3.05, accuracy: 80));
        expect(u.source, 'frozen');
      }
      expect(t.heading, 90);
    });

    test('cap brut NaN, negatif et >360 ignores sans jeter les coordonnees', () {
      final t = GpsHeadingTracker();
      t.update(fix(36.8, 3.05, heading: 90));
      expect(t.update(fix(36.8, 3.05, heading: double.nan)).source, 'frozen');
      expect(t.update(fix(36.8, 3.05, heading: 400)).source, 'frozen');
      expect(t.update(fix(500, 3.05, heading: 40)).source, 'invalid_fix');
      expect(t.heading, 90);
    });

    test('la derniere ancre est remplacee par un nouveau heading valide', () {
      final t = GpsHeadingTracker();
      t.update(fix(36.8, 3.05, heading: 0));
      t.update(fix(36.79999, 3.05));
      final direct = t.update(fix(36.79998, 3.05, heading: 180));
      expect(direct.source, 'ios_direct');
      expect(direct.anchorMeters, 0);
      var freeze = t.update(fix(36.79997, 3.05));
      expect(freeze.source, 'frozen');
    });

    test('saut GPS ne produit pas un cap fictif', () {
      final t = GpsHeadingTracker();
      t.update(fix(36.8, 3.05, heading: 0));
      final next = t.update(fix(36.82, 3.05));
      expect(next.source, 'frozen');
      expect(next.headingDegrees, 0);
    });
  });
}
