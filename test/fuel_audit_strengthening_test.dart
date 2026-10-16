import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimo_spark/logic/fuel_calculator.dart';
import 'package:mimo_spark/data/database_helper.dart';
import 'package:mimo_spark/ui/map_page.dart';
import 'helpers/fake_database.dart';


class TestDatabaseException implements DatabaseException {
  final String msg;
  TestDatabaseException(this.msg);
  @override
  String toString() => msg;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Base de données factice permettant d'injecter des pannes SQLite ciblées.
class FailingFakeDatabase extends FakeDatabase {
  bool failOnRefill = false;
  bool failOnSetFuelState = false;

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    if (failOnRefill) {
      throw TestDatabaseException('SQLite I/O failure: disk full or database locked');
    }
    return super.transaction(action, exclusive: exclusive);
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    if (failOnSetFuelState && sql.contains('UPDATE fuel_state')) {
      throw TestDatabaseException('SQLite I/O failure on UPDATE fuel_state');
    }
    return super.rawUpdate(sql, arguments);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    if (failOnSetFuelState && table == 'fuel_state') {
      throw TestDatabaseException('SQLite I/O failure on INSERT fuel_state');
    }
    return super.insert(table, values, nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  }
}


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MIMO SPARK V3.1 — Audit GitHub Renforcement P0/P1', () {
    late FakeDatabase fakeDb;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);
    });

    tearDown(() {
      DatabaseHelper().setDatabaseForTesting(null);
    });

    // ── Test 1 : P0 — SQLite indisponible lors d'un plein : aucune fausse confirmation ──
    test('1. SQLite indisponible lors d\'un plein : exception propagée, aucun faux succès', () async {
      final failingDb = FailingFakeDatabase()..failOnRefill = true;
      DatabaseHelper().setDatabaseForTesting(failingDb);

      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 15.0});
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.currentLiters, 15.0);
      expect(calculator.isCalibrated, isTrue);

      // Tenter un plein : doit obligatoirement lever l'exception SQLite (jamais masquée)
      expect(
        () => calculator.addFuel(10.0),
        throwsA(isA<DatabaseException>()),
      );

      // Vérifier que la jauge en mémoire n'a PAS été incrémentée à tort
      expect(calculator.currentLiters, 15.0);
      expect(calculator.isRefilling, isFalse);
      expect(calculator.pendingConsumptionLiters, 0.0);

      // Vérifier qu'aucune dépense n'a été insérée
      expect(failingDb.tables['expenses']?.isEmpty ?? true, isTrue);
      expect(failingDb.tables['fuel_refills']?.isEmpty ?? true, isTrue);
    });

    // ── Test 2 : P0 — Échec SQLite lors d'une calibration : restauration intégrale ──
    test('2. Échec SQLite lors d\'une calibration : rollback complet et restauration de lastCalibTs', () async {
      final failingDb = FailingFakeDatabase()..failOnSetFuelState = true;
      DatabaseHelper().setDatabaseForTesting(failingDb);

      SharedPreferences.setMockInitialValues(<String, Object>{
        'last_fuel_level': 12.0,
        'last_calibration_timestamp': 1000,
      });
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.currentLiters, 12.0);
      expect(calculator.lastCalibTs, 1000);
      expect(calculator.isCalibrated, isTrue);

      // Tenter une calibration à 25.0 L : doit échouer
      expect(
        () => calculator.calibrate(25.0),
        throwsA(isA<Exception>()),
      );

      // Vérifier que l'état mémoire est intégralement restauré (niveau, calibrage, timestamp)
      expect(calculator.currentLiters, 12.0);
      expect(calculator.isCalibrated, isTrue);
      expect(calculator.lastCalibTs, 1000);
    });

    test('13. Échec du plein complet : dernier timestamp de calibration préservé', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'last_fuel_level': 12.0,
        'last_calibration_timestamp': 12345,
      });
      final failingDb = FailingFakeDatabase();
      DatabaseHelper().setDatabaseForTesting(failingDb);
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.lastCalibTs, 12345);
      failingDb.failOnRefill = true;
      await expectLater(
        calculator.addFuel(5.0, isFullTank: true),
        throwsA(isA<DatabaseException>()),
      );
      expect(calculator.currentLiters, 12.0);
      expect(calculator.isCalibrated, isTrue);
      expect(calculator.lastCalibTs, 12345);
    });

    test('14. Réservoir 35 L : refus de plus de 35 L même avec jauge inconnue', () async {
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.isCalibrated, isFalse);

      await expectLater(
        calculator.addFuel(36.0, isFullTank: true),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        calculator.addFuel(10.0, pricePerLiter: double.nan),
        throwsA(isA<ArgumentError>()),
      );
      expect(fakeDb.tables['fuel_refills']?.isEmpty ?? true, isTrue);
      expect(fakeDb.tables['expenses']?.isEmpty ?? true, isTrue);
    });

    // ── Test 3 : P0 — Sérialisation stricte : ancienne sauvegarde OBD2 retardée ──
    test('3. Ancienne sauvegarde OBD2 retardée : ordonnancement FIFO strict sans écrasement', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      // Consommation OBD2 initiale
      calculator.updateVirtualFuel(3.6, 100.0); // Conso de 0.1 L -> 9.9 L
      expect(calculator.currentLiters, closeTo(9.9, 1e-4));

      // Lancement concurrent d'un save OBD2 puis d'un plein de 20 L
      // Grâce à la file FIFO _enqueueExclusive, les opérations s'exécutent dans l'ordre strict
      final saveFuture = calculator.save();
      final refillFuture = calculator.addFuel(20.0);

      await Future.wait([saveFuture, refillFuture]);

      // Le niveau final doit être le plein appliqué (29.9 L) et la persistance SQLite doit refléter ce niveau
      expect(calculator.currentLiters, closeTo(29.9, 1e-4));

      final state = await DatabaseHelper().getFuelState();
      expect(state, isNotNull);
      expect((state!['liters'] as num).toDouble(), closeTo(29.9, 1e-4));
      expect(state['event_type'], 'REFILL');
    });

    // ── Test 4 : P0 — Deux écritures au même timestamp : priorité sémantique ──
    test('4. Deux écritures au même timestamp : rejet de l\'écrasement par un OBD_SYNC', () async {
      final db = DatabaseHelper();
      const fixedTs = 1700000000000;

      // 1. Enregistrer un REFILL à fixedTs
      final refillOk = await db.setFuelState(
        liters: 30.0,
        eventType: 'REFILL',
        lastCalibTs: fixedTs,
        isCalibrated: true,
        updatedAt: fixedTs,
      );
      expect(refillOk, isTrue);

      // 2. Tenter un OBD_SYNC avec EXACTEMENT le même timestamp fixedTs
      final obdOk = await db.setFuelState(
        liters: 10.0,
        eventType: 'OBD_SYNC',
        lastCalibTs: fixedTs,
        isCalibrated: true,
        updatedAt: fixedTs,
      );
      // Doit être rejeté car OBD_SYNC n'a pas la priorité sur REFILL au même instant
      expect(obdOk, isFalse);

      final state = await db.getFuelState();
      expect((state!['liters'] as num).toDouble(), 30.0);
      expect(state['event_type'], 'REFILL');
    });

    // ── Test 5 : P0 — Suppression d'une dépense FUEL dans une session archivée ──
    test('5. Suppression d\'une dépense FUEL dans une session archivée : contre-passation et équilibre de sessions.total_spent', () async {
      final db = DatabaseHelper();
      final refill = await db.recordFuelRefill(
        liters: 15.0,
        pricePerLiter: 50.0,
        levelBefore: 10.0,
        levelAfter: 25.0,
      );
      expect(refill.totalAmount, 750.0);

      // Clôture de session
      final sessionId = await db.closeCurrentSession();
      expect(sessionId, isNotNull);

      final sessions = await db.getAllSessions();
      expect(sessions.first['total_spent'], 750.0);

      // Suppression de la dépense FUEL via deleteExpense()
      final deleteOk = await db.deleteExpense(refill.expenseId!);
      expect(deleteOk, isTrue);

      // Contrôle de la contre-passation FUEL_CANCEL
      final archivedExpenses = await db.getExpensesForSession(sessionId!);
      expect(archivedExpenses.any((e) => e['type'] == 'FUEL_CANCEL' && e['amount_da'] == -750.0), isTrue);

      // Contrôle de l'équilibre mathématique de la session
      final updatedSessions = await db.getAllSessions();
      expect(updatedSessions.first['total_spent'], 0.0);
    });

    // ── Test 6 : P0 — Suppression d'une contre-passation FUEL_CANCEL : interdiction formelle ──
    test('6. Suppression d\'une contre-passation FUEL_CANCEL : rejet par StateError pour intégrité comptable', () async {
      final db = DatabaseHelper();
      final refill = await db.recordFuelRefill(
        liters: 10.0,
        pricePerLiter: 50.0,
        levelBefore: 10.0,
        levelAfter: 20.0,
      );

      final sessionId = await db.closeCurrentSession();
      await db.cancelFuelRefill(refill.id, deductLiters: false);

      final expenses = await db.getExpensesForSession(sessionId!);
      final cancelExpense = expenses.firstWhere((e) => e['type'] == 'FUEL_CANCEL');

      // Tenter de supprimer la contre-passation : doit obligatoirement lever une StateError
      expect(
        () => db.deleteExpense(cancelExpense['id'] as int),
        throwsA(isA<StateError>()),
      );
    });

    // ── Test 7 : P1 — Ajout de carburant avec jauge non calibrée ──
    test('7. Ajout de carburant non calibré : sans plein complet, autonomie reste 0 et statut non calibré préservé', () async {
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.isCalibrated, isFalse);
      expect(calculator.currentLiters, 0.0);
      expect(calculator.kmRestants, 0);

      // 1. Ajout de 10 L sans confirmer le plein complet
      await calculator.addFuel(10.0, pricePerLiter: 50.0, isFullTank: false);

      // La dépense est enregistrée mais la jauge DOIT rester non calibrée
      expect(calculator.isCalibrated, isFalse);
      expect(calculator.currentLiters, 0.0);
      expect(calculator.kmRestants, 0); // Aucune autonomie fictive affichée

      final refills = await DatabaseHelper().getAllFuelRefills();
      expect(refills.length, 1);
      expect(refills.first.liters, 10.0);
      expect(refills.first.levelBefore, isNull); // Pas de faux 0.0 L dans l'historique

      // 2. Ajout ultérieur avec confirmation du plein complet (35 L)
      await calculator.addFuel(15.0, pricePerLiter: 50.0, isFullTank: true);

      expect(calculator.isCalibrated, isTrue);
      expect(calculator.currentLiters, 35.0);
      expect(calculator.kmRestants, (35.0 / 7.5 * 100).toInt()); // ~466 km calculables
    });

    // ── Test 8 : Absence de deadlock dans _enqueueExclusive ──
    test('8. Absence de deadlock dans _enqueueExclusive sous forte charge concurrente', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 20.0});
      final calculator = FuelCalculator();
      await calculator.init();

      // Lancer 20 opérations d'écritures concurrentes et vérifier qu'aucune ne bloque (avec timeout strict)
      final futures = <Future<void>>[];
      for (int i = 0; i < 10; i++) {
        futures.add(calculator.save());
        futures.add(calculator.calibrate(20.0 + (i * 0.1)));
      }

      await Future.wait(futures).timeout(const Duration(seconds: 5));
      expect(calculator.isCalibrated, isTrue);
      expect(calculator.currentLiters, closeTo(20.9, 1e-4));
    });

    // ── Test 9 : Idempotence stricte : double annulation du même plein ──
    test('9. Annulation deux fois du même plein : stricte idempotence et zéro double déduction', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      await calculator.addFuel(10.0, customId: 'double_cancel_test');
      expect(calculator.currentLiters, 20.0);

      // Première annulation avec déduction
      final level1 = await calculator.cancelFuelRefill(10.0, deductLiters: true, refillId: 'double_cancel_test');
      expect(level1, 10.0);
      expect(calculator.currentLiters, 10.0);

      // Seconde annulation du même plein : doit être rejetée sans aucune nouvelle déduction
      final level2 = await calculator.cancelFuelRefill(10.0, deductLiters: true, refillId: 'double_cancel_test');
      expect(level2, 10.0);
      expect(calculator.currentLiters, 10.0); // Toujours 10.0 L (jamais 0.0 L)
    });

    // ── Test 10 : Dépense FUEL historique sans fuel_refills ──
    test('10. Dépense FUEL historique sans fuel_refills : suppression propre sans inventer de litres', () async {
      final db = DatabaseHelper();
      final now = DateTime.now().millisecondsSinceEpoch;

      // Insertion manuelle d'une ancienne dépense FUEL v2 sans fuel_refills
      final rawExpenseId = await fakeDb.insert('expenses', {
        'date': '2026-01-01',
        'type': 'FUEL',
        'amount_da': 500.0,
        'timestamp': now,
      });

      final delOk = await db.deleteExpense(rawExpenseId);
      expect(delOk, isTrue);

      final expList = await fakeDb.query('expenses', where: 'id = ?', whereArgs: [rawExpenseId]);
      expect(expList.isEmpty, isTrue);
    });

    // ── Test 11 : Deux pleins validés très rapidement : identifiants uniques monotones ──
    test('11. Deux pleins validés très rapidement : identifiants uniques et timestamps monotones', () async {
      final calculator = FuelCalculator();
      await calculator.init();
      await calculator.calibrate(10.0);

      final f1 = calculator.addFuel(2.0);
      final f2 = calculator.addFuel(3.0);

      await Future.wait([f1, f2]);

      final refills = await DatabaseHelper().getAllFuelRefills();
      expect(refills.length, 2);
      expect(refills[0].id != refills[1].id, isTrue);
      expect(refills[0].timestamp != refills[1].timestamp, isTrue);
    });

    // ── Test 12 : Navigation MapPage complète avec retour sous SafeArea ──
    testWidgets('12. Véritable parcours de navigation MapPage avec bouton retour vers Dashboard', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            splashFactory: InkRipple.splashFactory,
          ),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.push(
                    ctx,
                    MaterialPageRoute(builder: (_) => const MapPage()),
                  ),
                  child: const Text("Open Map"),
                ),
              ),
            ),
          ),
        ),
      );

      // Ouvrir MapPage
      await tester.tap(find.text("Open Map"));
      await tester.pumpAndSettle();

      // Vérifier la présence du bouton retour sécurisé
      expect(find.byKey(const Key('map_back_button')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // Cliquer sur le bouton retour et vérifier le retour
      await tester.tap(find.byKey(const Key('map_back_button')));
      await tester.pumpAndSettle();

      expect(find.text("Open Map"), findsOneWidget);
      expect(find.byKey(const Key('map_back_button')), findsNothing);
    });
  });
}

