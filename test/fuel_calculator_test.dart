import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimo_spark/logic/fuel_calculator.dart';
import 'package:mimo_spark/data/database_helper.dart';
import 'helpers/fake_database.dart';

// FuelCalculator uses an estimated fuel level, not a direct tank measurement.
// Real-time OBD integration and the gauge appearance still need iPhone testing.
double expectedNeedleAngle(double liters) {
  const startAngle = 226.0; // E at 0 L
  const endAngle = 308.0; // F at 35 L
  final ratio = liters.clamp(0.0, 35.0) / 35.0;
  return startAngle + ratio * (endAngle - startAngle);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DatabaseHelper().setDatabaseForTesting(FakeDatabase());
  });

  group('Fuel gauge geometry (mathematical reference)', () {
    test('0 L E, 17.5 L middle, 35 L F', () {
      expect(expectedNeedleAngle(0), closeTo(226, 0.0001));
      expect(expectedNeedleAngle(17.5), closeTo(267, 0.0001));
      expect(expectedNeedleAngle(35), closeTo(308, 0.0001));
    });

    test('needle progresses monotonically towards E when liters fall', () {
      final liters = <double>[35, 25, 17.5, 10, 5, 0];
      for (var i = 1; i < liters.length; i++) {
        expect(expectedNeedleAngle(liters[i]),
            lessThan(expectedNeedleAngle(liters[i - 1])));
      }
    });

    test('angles clamp to end stops', () {
      expect(expectedNeedleAngle(-1), 226);
      expect(expectedNeedleAngle(36), 308);
    });
  });

  group('FuelCalculator with mocked SharedPreferences', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DatabaseHelper().setDatabaseForTesting(FakeDatabase());
    });

    test('initializes in uncalibrated state when no value exists (no arbitrary guess)', () async {
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.isCalibrated, isFalse);
      expect(calculator.currentLiters, 0.0);
      expect(calculator.kmRestants, 0);
    });

    test('restores a persisted fuel level after a new instance starts', () async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'last_fuel_level': 9.3},
      );
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.currentLiters, closeTo(9.3, 1e-9));
      expect(calculator.kmRestants, 124);
    });

    test('reads legacy calibration when the modern key is absent', () async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'fuel_calibration': 19.0},
      );
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.currentLiters, 19);
    });

    test('calibration writes a persistent level and caps it to tank capacity', () async {
      final calculator = FuelCalculator();
      await calculator.calibrate(50);
      expect(calculator.currentLiters, 35);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('last_fuel_level'), 35);
      await calculator.calibrate(-2);
      expect(calculator.currentLiters, 0);
      expect(prefs.getDouble('last_fuel_level'), 0);
    });

    test('actual updateVirtualFuel reduces 20 L to 19.5 L', () async {
      final calculator = FuelCalculator();
      await calculator.calibrate(20);
      // 6 L/hour for 300 seconds = 0.5 L.
      calculator.updateVirtualFuel(6, 300);
      expect(calculator.currentLiters, closeTo(19.5, 1e-9));
      expect(calculator.kmRestants, 260);
    });

    test('saving and reopening restores the consumed 19.5 L', () async {
      final calculator = FuelCalculator();
      await calculator.calibrate(20);
      calculator.updateVirtualFuel(6, 300);
      await calculator.save();
      final restarted = FuelCalculator();
      await restarted.init();
      expect(restarted.currentLiters, closeTo(19.5, 1e-9));
      expect(restarted.kmRestants, 260);
    });

    test('manual calibration overrides previously consumed fuel', () async {
      final calculator = FuelCalculator();
      await calculator.calibrate(20);
      calculator.updateVirtualFuel(6, 300);
      await calculator.calibrate(25);
      expect(calculator.currentLiters, 25);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('last_fuel_level'), 25);
    });

    test('no fuel is deducted while uninitialized', () {
      final calculator = FuelCalculator();
      calculator.currentLiters = 20;
      calculator.updateVirtualFuel(6, 300);
      expect(calculator.currentLiters, 20);
    });

    test('invalid lph and elapsed times do not reduce fuel', () async {
      final calculator = FuelCalculator();
      await calculator.calibrate(20);
      for (final lph in <double>[0, -1, double.nan, double.infinity]) {
        calculator.updateVirtualFuel(lph, 300);
      }
      for (final seconds in <double>[0, -1, double.nan, double.infinity]) {
        calculator.updateVirtualFuel(6, seconds);
      }
      expect(calculator.currentLiters, 20);
    });

    test('actual updateVirtualFuel never goes below zero', () async {
      final calculator = FuelCalculator();
      await calculator.calibrate(0.2);
      calculator.updateVirtualFuel(20, 3600);
      expect(calculator.currentLiters, 0);
    });

    test('MAF estimate to liters per hour uses existing formula', () {
      final calculator = FuelCalculator();
      expect(calculator.calculateConsumptionLph(0), 0);
      expect(calculator.calculateConsumptionLph(-1), 0);
      expect(calculator.calculateConsumptionLph(2),
          closeTo((2 / (14.7 * 750)) * 3600, 1e-9));
    });
  });

  group('Fuel refill (Fonctionnalité 1 — V3.1)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DatabaseHelper().setDatabaseForTesting(FakeDatabase());
    });

    test('Ajout de 10 L à 9,3 L donne exactement 19,3 L', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 9.3});
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.currentLiters, closeTo(9.3, 1e-9));

      final newLevel = await calculator.addFuel(10.0);
      expect(newLevel, closeTo(19.3, 1e-9));
      expect(calculator.currentLiters, closeTo(19.3, 1e-9));

      // Vérifier la persistance immédiate dans SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('last_fuel_level'), closeTo(19.3, 1e-9));
    });

    test('Rejet strict du dépassement de 35 L avec exception StateError (pas de troncature)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 9.3});
      final calculator = FuelCalculator();
      await calculator.init();

      // Tenter d'ajouter 30 L (total = 39.3 L > 35 L)
      expect(
        () async => await calculator.addFuel(30.0),
        throwsA(isA<StateError>()),
      );

      // Vérifier que le niveau actuel est resté intact à 9.3 L
      expect(calculator.currentLiters, closeTo(9.3, 1e-9));
    });

    test('Rejet strict des valeurs nulles, négatives, NaN et infinies', () async {
      final calculator = FuelCalculator();
      await calculator.init();

      expect(() async => await calculator.addFuel(0.0), throwsA(isA<ArgumentError>()));
      expect(() async => await calculator.addFuel(-5.0), throwsA(isA<ArgumentError>()));
      expect(() async => await calculator.addFuel(double.nan), throwsA(isA<ArgumentError>()));
      expect(() async => await calculator.addFuel(double.infinity), throwsA(isA<ArgumentError>()));
    });

    test('Gestion des décimales et calcul exact du montant en DA', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      // Ajout de 9.5 L
      final newLevel = await calculator.addFuel(9.5);
      expect(newLevel, closeTo(19.5, 1e-9));

      // Calcul du montant en DA avec prix du litre à 50 DA
      const pricePerLiter = 50.0;
      final amountDa = 9.5 * pricePerLiter;
      expect(amountDa, closeTo(475.0, 1e-9));
    });

    test('Annulation de plein : restitution sécurisée du niveau précédent', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 9.3});
      final calculator = FuelCalculator();
      await calculator.init();

      await calculator.addFuel(10.0);
      expect(calculator.currentLiters, closeTo(19.3, 1e-9));

      // Annulation directe sans consommation
      await calculator.cancelFuelRefill(10.0, levelBefore: 9.3);
      expect(calculator.currentLiters, closeTo(9.3, 1e-9));
    });

    test('Annulation de plein après consommation : ne descend jamais sous 0 L', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 5.0});
      final calculator = FuelCalculator();
      await calculator.init();

      await calculator.addFuel(5.0); // Total = 10 L
      expect(calculator.currentLiters, closeTo(10.0, 1e-9));

      // Consommer 8 L -> reste 2 L
      calculator.updateVirtualFuel(8.0, 3600);
      expect(calculator.currentLiters, closeTo(2.0, 1e-9));

      // Annuler le plein de 5 L -> 2 L - 5 L ne devient PAS négatif mais est clampé à 0 L
      await calculator.cancelFuelRefill(5.0);
      expect(calculator.currentLiters, 0.0);
    });

    test('Redémarrage de l\'application : le niveau après plein est restauré', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 9.3});
      final appSession1 = FuelCalculator();
      await appSession1.init();
      await appSession1.addFuel(10.0); // 19.3 L
      await appSession1.save();

      // Nouvelle instance (simulant un redémarrage de l'app)
      final appSession2 = FuelCalculator();
      await appSession2.init();
      expect(appSession2.currentLiters, closeTo(19.3, 1e-9));
      expect(appSession2.kmRestants, (19.3 / 7.5 * 100).toInt());
    });
  });
}
