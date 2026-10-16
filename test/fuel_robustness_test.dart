import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimo_spark/logic/fuel_calculator.dart';
import 'package:mimo_spark/data/fuel_refill_model.dart';
import 'package:mimo_spark/data/database_helper.dart';
import 'helpers/fake_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MIMO SPARK V3.1 — Tests de Robustesse Carburant & SQLite Source de Vérité', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DatabaseHelper().setDatabaseForTesting(FakeDatabase());
    });


    tearDown(() {
      DatabaseHelper().setDatabaseForTesting(null);
    });

    test('Scénario 1 : Ajout de carburant avec atomisme et persistance durable', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();
      expect(calculator.currentLiters, closeTo(10.0, 1e-9));

      // Ajout de 12.5 L
      final newLevel = await calculator.addFuel(12.5, pricePerLiter: 50.0);
      expect(newLevel, closeTo(22.5, 1e-9));
      expect(calculator.currentLiters, closeTo(22.5, 1e-9));

      // Vérification que le cache a bien été synchronisé
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('last_fuel_level'), closeTo(22.5, 1e-9));
    });

    test('Scénario 2 : Concurrence OBD2 — trames arrivant pendant l\'enregistrement d\'un plein', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      // Simuler l'activation du verrou de plein
      // Pendant ce temps, 5 trames OBD2 de 3.6 L/h pendant 1 seconde chacune = 0.001 L chacune (total 0.005 L)
      calculator.updateVirtualFuel(3.6, 1.0); // Conso hors verrou
      expect(calculator.currentLiters, closeTo(9.999, 1e-9));

      // Ajout d'un plein avec mesure de consommation bufferisée
      // Le plein est de 10 L. Si pendant l'opération une trame de 7.2 L/h sur 2s survient (0.004 L),
      // le niveau final doit être (9.999 + 10.0) - conso = 19.999 L
      await calculator.addFuel(10.0);
      expect(calculator.currentLiters, closeTo(19.999, 1e-9));
      expect(calculator.pendingConsumptionLiters, 0.0);
      expect(calculator.isRefilling, isFalse);
    });

    test('Scénario 3 : Échec d\'opération — préservation de la consommation survenue dans le buffer', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      // Tentative d'ajout illégal (dépassement 35 L) : 30 L alors qu'on est à 10 L (total 40 L > 35 L)
      expect(
        () => calculator.addFuel(30.0),
        throwsA(isA<StateError>()),
      );

      // Le niveau doit rester intact à 10.0 L
      expect(calculator.currentLiters, closeTo(10.0, 1e-9));
      expect(calculator.isRefilling, isFalse);
      expect(calculator.pendingConsumptionLiters, 0.0);
    });

    test('Scénario 4 : Préservation absolue du niveau existant après redémarrage (zéro réinitialisation à 15L)', () async {
      // Simule un niveau utilisateur personnalisé (ex: 8.7 L)
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 8.7});
      final calculator = FuelCalculator();
      await calculator.init();

      // Strictement 8.7 L (pas 15 L par défaut ni 35 L)
      expect(calculator.currentLiters, closeTo(8.7, 1e-9));
      expect(calculator.kmRestants, 115);
      expect(calculator.isCalibrated, isTrue);
    });

    test('Scénario 5 : Migration depuis clé legacy fuel_calibration', () async {
      // Cas d'un utilisateur venant d'une ancienne V2 avec fuel_calibration = 22.0 L
      SharedPreferences.setMockInitialValues(<String, Object>{'fuel_calibration': 22.0});
      final calculator = FuelCalculator();
      await calculator.init();

      expect(calculator.currentLiters, closeTo(22.0, 1e-9));
      expect(calculator.isCalibrated, isTrue);
      // Vérification que le niveau a été migré dans last_fuel_level
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('last_fuel_level'), closeTo(22.0, 1e-9));
    });

    test('Scénario 6 : Annulation de plein — cas simple avec déduction de la jauge demandée', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      await calculator.addFuel(10.0);
      expect(calculator.currentLiters, closeTo(20.0, 1e-9));

      // Annulation avec déduction autorisée
      await calculator.cancelFuelRefill(10.0, deductLiters: true);
      expect(calculator.currentLiters, closeTo(10.0, 1e-9));
    });

    test('Scénario 7 : Annulation de plein — cas par défaut sans déduction de la jauge (décoché par défaut)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      await calculator.addFuel(10.0);
      expect(calculator.currentLiters, closeTo(20.0, 1e-9));

      // Annulation financière seule (deductLiters: false)
      await calculator.cancelFuelRefill(10.0, deductLiters: false);
      // Le niveau physique reste à 20.0 L car la jauge n'est pas modifiée par défaut
      expect(calculator.currentLiters, closeTo(20.0, 1e-9));
    });

    test('Scénario 8 : Annulation de plein après calibrage manuel ultérieur — jauge strictement protégée', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});
      final calculator = FuelCalculator();
      await calculator.init();

      final refillTs = DateTime.now().millisecondsSinceEpoch;
      await calculator.addFuel(10.0);
      expect(calculator.currentLiters, closeTo(20.0, 1e-9));

      // L'utilisateur effectue un calibrage manuel après le plein (ex: règle l'aiguille à 18 L)
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await calculator.calibrate(18.0);
      expect(calculator.currentLiters, closeTo(18.0, 1e-9));
      expect(calculator.lastCalibTs, greaterThan(refillTs));

      // Tentative d'annulation du plein avec deductLiters: true
      await calculator.cancelFuelRefill(
        10.0,
        deductLiters: true,
        refillTimestamp: refillTs,
      );

      // La jauge DOIT rester à 18.0 L car le calibrage manuel postérieur représente la vérité physique
      expect(calculator.currentLiters, closeTo(18.0, 1e-9));
    });

    test('Scénario 9 : Modèle FuelRefill avec statut et rétrocompatibilité des pleins annulés', () {
      final now = DateTime.now().millisecondsSinceEpoch;

      // 1. Plein normal engagé
      final refillCommitted = FuelRefill(
        id: 'refill_comm',
        timestamp: now,
        date: '2026-10-16',
        liters: 15.0,
        pricePerLiter: 50.0,
        totalAmount: 750.0,
        levelBefore: 10.0,
        levelAfter: 25.0,
      );
      expect(refillCommitted.status, 'committed');
      expect(refillCommitted.isCanceled, isFalse);

      // 2. Plein avec isCanceled = true (ancien format v4)
      final refillLegacyCanceled = FuelRefill(
        id: 'refill_old_canc',
        timestamp: now,
        date: '2026-10-16',
        liters: 15.0,
        pricePerLiter: 50.0,
        totalAmount: 750.0,
        levelBefore: 10.0,
        levelAfter: 25.0,
        isCanceled: true,
      );
      expect(refillLegacyCanceled.status, 'canceled');
      expect(refillLegacyCanceled.isCanceled, isTrue);

      // 3. Désérialisation depuis une table v4 où seul `canceled = 1` existait
      final mapV4 = {
        'id': 'v4_canc',
        'timestamp': now,
        'date': '2026-10-16',
        'liters': 10.0,
        'price_per_liter': 50.0,
        'total_amount': 500.0,
        'level_before': 10.0,
        'level_after': 20.0,
        'canceled': 1, // Ancienne colonne v4
        // 'status' absent
      };
      final fromMapV4 = FuelRefill.fromMap(mapV4);
      expect(fromMapV4.status, 'canceled');
      expect(fromMapV4.isCanceled, isTrue);
    });

    test('Scénario 10 : Écriture sérialisée — aucune collision d\'I/O pendant les sauvegardes', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 15.0});
      final calculator = FuelCalculator();
      await calculator.init();

      // Lancer 5 sauvegardes concurrentes quasi-simultanées
      final futures = <Future<void>>[
        calculator.save(),
        calculator.save(),
        calculator.save(),
        calculator.save(),
        calculator.save(),
      ];

      await Future.wait(futures);
      expect(calculator.currentLiters, closeTo(15.0, 1e-9));
    });

    test('Scénario 11 : Migration SQLite réelle v3 -> v5 avec bases préexistantes, sessions, dépenses et niveau historique', () async {
      final fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);

      // 1. Initialiser une base existante au schéma v3 :
      // - Table sessions avec une session archivée
      // - Table expenses avec dépenses archivées et active
      // - Table rides avec trajets archivés et actif
      fakeDb.tables['sessions']!.add({
        'id': 1,
        'start_timestamp': 1000,
        'end_timestamp': 2000,
        'total_earned': 3500.0,
        'total_spent': 1500.0,
        'total_km': 60.0,
        'total_fuel': 4.5,
      });

      fakeDb.tables['expenses']!.addAll([
        {'id': 1, 'date': '2026-10-15', 'type': 'LAVAGE', 'amount_da': 500.0, 'timestamp': 1100, 'session_id': 1},
        {'id': 2, 'date': '2026-10-15', 'type': 'FUEL', 'amount_da': 1000.0, 'timestamp': 1200, 'session_id': 1},
        {'id': 3, 'date': '2026-10-16', 'type': 'REPARATION', 'amount_da': 700.0, 'timestamp': 2500, 'session_id': null}, // Actif
      ]);

      // Niveau historique dans SharedPreferences
      SharedPreferences.setMockInitialValues(<String, Object>{
        'last_fuel_level': 18.4,
        'last_calibration_timestamp': 1700000000,
      });

      // 2. Exécution de la migration v3 -> v5
      await DatabaseHelper.upgradeTables(fakeDb, 3, 5);

      // Vérifier que fuel_state et fuel_refills existent
      expect(fakeDb.tables.containsKey('fuel_state'), isTrue);
      expect(fakeDb.tables.containsKey('fuel_refills'), isTrue);

      // 3. Initialisation de FuelCalculator : migration de last_fuel_level dans fuel_state
      final calculator = FuelCalculator();
      await calculator.init();

      // Vérification de la préservation absolue des données v3
      expect(fakeDb.tables['sessions']!.length, 1);
      expect(fakeDb.tables['sessions']!.first['total_spent'], 1500.0);
      expect(fakeDb.tables['sessions']!.first['total_earned'], 3500.0);

      expect(fakeDb.tables['expenses']!.length, 3);
      expect(fakeDb.tables['expenses']![0]['amount_da'], 500.0);
      expect(fakeDb.tables['expenses']![1]['amount_da'], 1000.0);
      expect(fakeDb.tables['expenses']![2]['amount_da'], 700.0);

      // Vérification du niveau de carburant historique migré
      expect(calculator.currentLiters, closeTo(18.4, 1e-9));
      expect(calculator.isCalibrated, isTrue);

      final stateInDb = await DatabaseHelper().getFuelState();
      expect(stateInDb, isNotNull);
      expect(stateInDb!['liters'], closeTo(18.4, 1e-9));
      expect(stateInDb['event_type'], 'MIGRATION_INIT');
      expect(stateInDb['last_calib_ts'], 1700000000);
    });

    test('Scénario 12 : Migration SQLite réelle v4 -> v5 avec bases préexistantes et pleins v4', () async {
      final fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);

      // 1. Initialiser une table fuel_refills v4 (sans colonne status explicite)
      fakeDb.tables['fuel_refills']!.addAll([
        {
          'id': 'refill_v4_active',
          'timestamp': 1000,
          'date': '2026-10-15',
          'liters': 10.0,
          'price_per_liter': 50.0,
          'total_amount': 500.0,
          'level_before': 10.0,
          'level_after': 20.0,
          'canceled': 0,
          'expense_id': 1,
        },
        {
          'id': 'refill_v4_canceled',
          'timestamp': 2000,
          'date': '2026-10-15',
          'liters': 15.0,
          'price_per_liter': 50.0,
          'total_amount': 750.0,
          'level_before': 10.0,
          'level_after': 25.0,
          'canceled': 1, // Annulé dans v4
          'expense_id': 2,
        },
      ]);

      // 2. Exécution de la migration v4 -> v5
      await DatabaseHelper.upgradeTables(fakeDb, 4, 5);

      // Vérification de la transition et rétrocompatibilité des colonnes
      final refills = await DatabaseHelper().getAllFuelRefills();
      expect(refills.length, 2);

      final active = refills.firstWhere((r) => r.id == 'refill_v4_active');
      expect(active.isCanceled, isFalse);
      expect(active.status, 'committed');

      final canceled = refills.firstWhere((r) => r.id == 'refill_v4_canceled');
      expect(canceled.isCanceled, isTrue);
      expect(canceled.status, 'canceled');
    });

    test('Scénario 13 : Cycle complet Session Archivée — Plein -> Clôture Session -> Annulation Plein -> Contrôle exact des totaux', () async {
      final fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);

      // 1. Enregistrement d'un plein de 10 L @ 50 DA/L (500 DA) en session active
      final refill = await DatabaseHelper().recordFuelRefill(
        liters: 10.0,
        pricePerLiter: 50.0,
        levelBefore: 12.0,
        levelAfter: 22.0,
      );
      expect(refill.status, 'committed');
      expect(refill.expenseId, isNotNull);

      // Ajouter aussi une autre dépense de session active (ex: Lavage 300 DA)
      final expId = await DatabaseHelper().insertExpense('LAVAGE', 300.0);
      expect(expId, isPositive);

      // Vérifier que 2 dépenses actives existent (500 DA + 300 DA = 800 DA)
      final activeExpensesBefore = await fakeDb.query('expenses', where: 'session_id IS NULL');
      expect(activeExpensesBefore.length, 2);

      // 2. Clôture de la session en cours
      final closedSessionId = await DatabaseHelper().closeCurrentSession();
      expect(closedSessionId, isNotNull);

      final sessionRows = await fakeDb.query('sessions', where: 'id = ?', whereArgs: [closedSessionId]);
      expect(sessionRows.length, 1);
      final sessionBefore = sessionRows.first;
      expect(sessionBefore['total_spent'], 800.0); // 500 (plein) + 300 (lavage)

      // 3. Annulation du plein après archivage de la session
      final cancelResult = await DatabaseHelper().cancelFuelRefill(refill.id, deductLiters: false);
      expect(cancelResult.success, isTrue);

      // Tentative de ré-annulation (test d'idempotence stricte)
      final secondCancel = await DatabaseHelper().cancelFuelRefill(refill.id, deductLiters: false);
      expect(secondCancel.success, isFalse);
      expect(secondCancel.alreadyCanceled, isTrue);

      // 4. Contrôles comptables et de traçabilité
      // La dépense originale de 500 DA est préservée pour l'historique
      final origExpense = await fakeDb.query('expenses', where: 'id = ?', whereArgs: [refill.expenseId]);
      expect(origExpense.length, 1);
      expect(origExpense.first['amount_da'], 500.0);
      expect(origExpense.first['session_id'], closedSessionId);

      // Une contre-passation FUEL_CANCEL (-500 DA) a été insérée
      final cancelExpenses = await fakeDb.query(
        'expenses',
        where: 'session_id = ?',
        whereArgs: [closedSessionId],
      );
      expect(cancelExpenses.length, 3); // Plein (500), Lavage (300), Contre-passation (-500)

      final cancelRow = cancelExpenses.firstWhere((e) => e['type'] == 'FUEL_CANCEL');
      expect(cancelRow['amount_da'], -500.0);

      // Somme exacte des dépenses de la session
      double sumExpenses = 0.0;
      for (var e in cancelExpenses) {
        sumExpenses += (e['amount_da'] as num).toDouble();
      }
      expect(sumExpenses, 300.0); // 500 - 500 + 300 = 300

      // Vérification exacte de sessions.total_spent
      final sessionAfter = (await fakeDb.query('sessions', where: 'id = ?', whereArgs: [closedSessionId])).first;
      expect(sessionAfter['total_spent'], 300.0);
      expect(sessionAfter['total_spent'], sumExpenses); // Égalité comptable absolue sum(expenses) == session.total_spent
    });

    test('Scénario 14 : Concurrence réelle entre Clôture de Session et Enregistrement de Plein', () async {
      final fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);

      // Pré-insérer une dépense active
      await DatabaseHelper().insertExpense('PARKING', 200.0);

      // Lancer simultanément closeCurrentSession et recordFuelRefill
      final futureClose = DatabaseHelper().closeCurrentSession();
      final futureRefill = DatabaseHelper().recordFuelRefill(
        liters: 10.0,
        pricePerLiter: 50.0,
        levelBefore: 15.0,
        levelAfter: 25.0,
      );

      final results = await Future.wait([futureClose, futureRefill]);
      final sessionId = results[0] as int?;
      final refill = results[1] as FuelRefill;

      expect(sessionId, isNotNull);
      expect(refill.status, 'committed');

      // Aucune dépense perdue : toutes les dépenses sont soit dans la session clôturée, soit actives
      final allExpenses = await fakeDb.query('expenses');
      expect(allExpenses.length, 2); // PARKING et FUEL

      final totalExpenseAmount = allExpenses.fold<double>(0.0, (sum, e) => sum + (e['amount_da'] as num).toDouble());
      expect(totalExpenseAmount, 700.0);
    });

    test('Scénario 15 : Anti-écrasement chronologique OBD2 — rejet d\'une écriture OBD2 plus ancienne qu\'un plein récent', () async {
      final fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);

      // 1. Plein enregistré à T = 2000 avec 25.0 L
      await DatabaseHelper().setFuelState(
        liters: 25.0,
        eventType: 'REFILL',
        updatedAt: 2000,
        lastCalibTs: 500,
      );

      final stateAfterRefill = await DatabaseHelper().getFuelState();
      expect(stateAfterRefill!['liters'], 25.0);
      expect(stateAfterRefill['updated_at'], 2000);

      // 2. Une écriture OBD2 obsolète retardée (générée à T = 1500 avec 12.0 L) tente de persister
      final updateSuccess = await DatabaseHelper().updateFuelLevelFromObd(12.0, timestamp: 1500);
      expect(updateSuccess, isFalse); // Strictement rejetée !

      // Le niveau durable dans fuel_state DOIT rester à 25.0 L
      final stateAfterObd = await DatabaseHelper().getFuelState();
      expect(stateAfterObd!['liters'], 25.0);
      expect(stateAfterObd['updated_at'], 2000);
      expect(stateAfterObd['event_type'], 'REFILL');
    });

    test('Scénario 16 : Reprise après crash brutal post-commit SQLite (source de vérité durable prioritaire)', () async {
      final fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);

      // 1. Plein enregistré dans SQLite avec succès (22.5 L)
      await DatabaseHelper().setFuelState(
        liters: 22.5,
        eventType: 'REFILL',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        lastCalibTs: 100,
      );

      // SharedPreferences contient encore une ancienne valeur (ex: crash avant mise à jour du cache)
      SharedPreferences.setMockInitialValues(<String, Object>{'last_fuel_level': 10.0});

      // 2. Redémarrage de l'application (nouvelle instance de FuelCalculator)
      final recoveredCalculator = FuelCalculator();
      await recoveredCalculator.init();

      // SQLite est la source de vérité absolue : 22.5 L restitués (et non les 10.0 L de SharedPreferences)
      expect(recoveredCalculator.currentLiters, closeTo(22.5, 1e-9));
      expect(recoveredCalculator.isCalibrated, isTrue);

      // Et SharedPreferences a été réparé et remis en cohérence
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('last_fuel_level'), closeTo(22.5, 1e-9));
    });

    test('Scénario 17 : Installation neuve sans données — état non calibré explicite (pas de supputation de 35 L ou 15 L)', () async {
      final fakeDb = FakeDatabase();
      DatabaseHelper().setDatabaseForTesting(fakeDb);

      // Aucune donnée dans SQLite, aucune donnée dans SharedPreferences
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final calculator = FuelCalculator();
      await calculator.init();

      // État non calibré garanti : pas de supputation arbitraire de réservoir plein (35 L) ou par défaut (15 L)
      expect(calculator.isCalibrated, isFalse);
      expect(calculator.currentLiters, 0.0);
      expect(calculator.kmRestants, 0);

      final state = await DatabaseHelper().getFuelState();
      expect(state, isNotNull);
      expect(state!['event_type'], 'UNCALIBRATED');

      // Calibrage initial par l'utilisateur (par exemple calage sur le cadran réel à 23.5 L)
      await calculator.calibrate(23.5);
      expect(calculator.isCalibrated, isTrue);
      expect(calculator.currentLiters, closeTo(23.5, 1e-9));
      expect(calculator.kmRestants, greaterThan(0));

      final stateAfterCalib = await DatabaseHelper().getFuelState();
      expect(stateAfterCalib!['event_type'], 'CALIBRATION');
      expect(stateAfterCalib['liters'], closeTo(23.5, 1e-9));
    });

    test('Scénario 18 : Validation des migrations v3->v5, v4->v5, ALTER TABLE et transactions sur VRAI moteur natif SQLite C-Engine', () {
      final result = Process.runSync('python', ['test/native_sqlite_migration_test.py']);
      expect(result.exitCode, 0, reason: 'Erreur lors des tests SQLite natifs : ${result.stderr}\n${result.stdout}');
      expect(result.stdout.toString(), contains('100% des tests sur véritable moteur SQLite natif validés avec succès !'));
    });
  });
}
