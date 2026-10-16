import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database_helper.dart';
import '../data/fuel_refill_model.dart';

class FuelCalculator {
  double currentLiters = 0.0;
  bool lowFuelAlerted = false;
  int _lastAlertedKm = -1;
  int _lastCalibTs = 0;
  int get lastCalibTs => _lastCalibTs;

  bool _isCalibrated = false;
  /// Indique si la jauge a été calibrée par l'utilisateur ou restaurée depuis des données historiques fiables.
  bool get isCalibrated => _isCalibrated;

  bool _isRefilling = false;
  bool get isRefilling => _isRefilling;
  double _pendingConsumptionLiters = 0.0;
  double get pendingConsumptionLiters => _pendingConsumptionLiters;

  static const double _consumptionL100 = 7.5;
  static const double _tankCapacity = 35.0;
  static const double _fuelDensity = 750.0;  // g/L essence SP95
  static const double _afr = 14.7;           // Air-Fuel Ratio stœchiométrique
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isInitialized = false;
  Future<void>? _initFuture;

  // File d'attente strictement séquentielle pour TOUTES les écritures de carburant (FIFO sans interférence)
  Future<void> _writeQueue = Future<void>.value();
  int _lastWrittenTs = 0;

  /// Génère un timestamp strictement croissant et unique pour éliminer tout conflit ou égalité.
  int _getMonotonicTimestamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now <= _lastWrittenTs) {
      _lastWrittenTs++;
    } else {
      _lastWrittenTs = now;
    }
    return _lastWrittenTs;
  }

  /// Exécute une opération de persistance de manière strictement sérialisée dans la file FIFO.
  /// Empêche tout interblocage (deadlock) : les méthodes internes exécutées ne doivent jamais se remettre en file.
  Future<T> _enqueueExclusive<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        final result = await operation();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }, onError: (_) async {
      // Même en cas d'erreur de l'opération précédente, exécuter la suivante
      try {
        final result = await operation();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // Initialise en chargeant la source de vérité SQLite durable ou SharedPreferences en premier import
  Future<void> init() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    // 1. Priorité absolue à la source de vérité SQLite
    Map<String, dynamic>? fuelState;
    try {
      fuelState = await DatabaseHelper().getFuelState();
    } catch (_) {
      // Ignoré si environnement de test unitaire sans plugin SQLite natif
    }

    if (fuelState != null) {
      // Le timestamp SQLite survit aux redémarrages ; la file conserve sa monotonie.
      _lastWrittenTs = (fuelState['updated_at'] as num?)?.toInt() ?? 0;
      final isCalibratedInt = fuelState['is_calibrated'] as int?;
      final eventType = fuelState['event_type'] as String?;
      final calibTs = (fuelState['last_calib_ts'] as int?) ?? 0;

      // P1 : Ne pas déduire isCalibrated uniquement de l'event_type (ex: OBD_SYNC sur non calibré)
      if (isCalibratedInt == 0 || eventType == 'UNCALIBRATED' || eventType == 'REFILL_UNCALIBRATED') {
        _isCalibrated = false;
        currentLiters = 0.0;
        _lastCalibTs = 0;
      } else {
        _isCalibrated = true;
        currentLiters = ((fuelState['liters'] as num).toDouble()).clamp(0.0, _tankCapacity);
        _lastCalibTs = calibTs;

        // Resynchronisation du cache SharedPreferences pour réparer toute divergence suite à un crash brutal
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble('last_fuel_level', currentLiters);
          if (calibTs > 0) {
            await prefs.setInt('last_calibration_timestamp', calibTs);
          }
        } catch (_) {}
      }
    } else {
      // 2. Migration contrôlée depuis SharedPreferences (installation existante v3/v4 ou première ouverture)
      final prefs = await SharedPreferences.getInstance();
      final savedFuel = prefs.getDouble('last_fuel_level');
      final legacyFuel = savedFuel == null ? prefs.getDouble('fuel_calibration') : null;

      if (savedFuel != null || legacyFuel != null) {
        // Préservation exacte des données utilisateur existantes
        final initialLiters = (savedFuel ?? legacyFuel!).clamp(0.0, _tankCapacity);
        _lastCalibTs = prefs.getInt('last_calibration_timestamp') ?? 0;
        _isCalibrated = true;
        currentLiters = initialLiters;

        // Inscription durable dans fuel_state SQLite pour figer la vérité
        try {
          await DatabaseHelper().setFuelState(
            liters: initialLiters,
            eventType: 'MIGRATION_INIT',
            lastCalibTs: _lastCalibTs,
            isCalibrated: true,
          );
        } catch (_) {}

        if (savedFuel == null) {
          await prefs.setDouble('last_fuel_level', currentLiters);
        }
      } else {
        // Aucune donnée historique : état non calibré explicite (pas de supputation arbitraire de 35 L ou 15 L)
        _isCalibrated = false;
        currentLiters = 0.0;
        _lastCalibTs = 0;

        try {
          await DatabaseHelper().setFuelState(
            liters: 0.0,
            eventType: 'UNCALIBRATED',
            lastCalibTs: 0,
            isCalibrated: false,
          );
        } catch (_) {}
      }
    }
    _isInitialized = true;
  }

  // Calibrage manuel par l'utilisateur (bouton dans le menu ou tactile)
  Future<void> calibrate(double liters) {
    return _enqueueExclusive(() => _calibrateInternal(liters));
  }

  Future<void> _calibrateInternal(double liters) async {
    await init();
    if (!liters.isFinite) throw ArgumentError.value(liters, 'liters');
    final previousLiters = currentLiters;
    final wasCalibrated = _isCalibrated;
    final previousCalibTs = _lastCalibTs;
    final calibrated = liters.clamp(0.0, _tankCapacity);
    final nowMs = _getMonotonicTimestamp();

    try {
      final ok = await DatabaseHelper().setFuelState(
        liters: calibrated,
        eventType: 'CALIBRATION',
        lastCalibTs: nowMs,
        isCalibrated: true,
        updatedAt: nowMs,
      );
      if (!ok) {
        throw StateError("Échec de mise à jour SQLite lors de la calibration.");
      }

      currentLiters = calibrated;
      _isCalibrated = true;
      _lastCalibTs = nowMs;
      lowFuelAlerted = false;
      _lastAlertedKm = -1;

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('last_fuel_level', calibrated);
        await prefs.setInt('last_calibration_timestamp', nowMs);
      } catch (_) {}

      print('Niveau essence calibré.');
    } catch (e) {
      // P0 : Restauration intégrale de l'ancien état en cas d'échec SQLite
      currentLiters = previousLiters;
      _isCalibrated = wasCalibrated;
      _lastCalibTs = previousCalibTs;
      rethrow;
    }
  }

  /// Capacité maximale du réservoir (35 litres pour la Spark 0.8L).
  static const double tankCapacity = _tankCapacity;

  /// Litres maximum pouvant encore être ajoutés sans déborder du réservoir.
  double get maxAddableLiters => _isCalibrated ? (_tankCapacity - currentLiters).clamp(0.0, _tankCapacity) : _tankCapacity;

  /// Ajoute une quantité exacte de carburant en litres de manière atomique :
  /// - Exécuté dans la file FIFO unique pour garantir l'absence de conflit.
  /// - Verrouille les calculs OBD2 sans perte de consommation via `_pendingConsumptionLiters`.
  /// - Met à jour atomiquement `fuel_refills`, `expenses` et `fuel_state` dans SQLite.
  /// - Si `isCalibrated == false` et `!isFullTank` : enregistre la dépense mais conserve la jauge non calibrée (P1).
  /// - Si `isFullTank == true` : calibre le niveau à 35 L avec certitude.
  Future<double> addFuel(
    double litersAdded, {
    double pricePerLiter = 50.0,
    String? customId,
    bool isFullTank = false,
  }) {
    return _enqueueExclusive(() => _addFuelInternal(
      litersAdded,
      pricePerLiter: pricePerLiter,
      customId: customId,
      isFullTank: isFullTank,
    ));
  }

  Future<double> _addFuelInternal(
    double litersAdded, {
    double pricePerLiter = 50.0,
    String? customId,
    bool isFullTank = false,
  }) async {
    await init();
    if (!litersAdded.isFinite || litersAdded.isNaN || litersAdded <= 0) {
      throw ArgumentError.value(litersAdded, 'litersAdded', 'La quantité de carburant doit être positive et finie.');
    }

    final double? levelBefore;
    final double? levelAfter;
    final bool newCalibrated;
    final previousCalibTs = _lastCalibTs;
    final nowMs = _getMonotonicTimestamp();

    if (isFullTank) {
      levelBefore = _isCalibrated ? currentLiters : null;
      levelAfter = _tankCapacity;
      newCalibrated = true;
      _lastCalibTs = nowMs;
    } else if (!_isCalibrated) {
      // P1 : Si la jauge n'est pas calibrée, ajouter X litres ne permet pas de connaître le total.
      // On n'invente pas un niveau initial à 0.0 L, on enregistre la dépense et on garde la jauge non calibrée.
      levelBefore = null;
      levelAfter = null;
      newCalibrated = false;
    } else {
      final projected = currentLiters + litersAdded;
      if (projected > _tankCapacity + 1e-6) {
        throw StateError(
          'Le plein ($projected L) dépasse la capacité maximale du réservoir ($_tankCapacity L).',
        );
      }
      levelBefore = currentLiters;
      levelAfter = projected.clamp(0.0, _tankCapacity);
      newCalibrated = true;
    }

    // Verrouillage anti-concurrence OBD2 pour capturer la consommation survenue pendant l'I/O SQLite
    _isRefilling = true;
    _pendingConsumptionLiters = 0.0;

    FuelRefill refill;
    try {
      // 1. Écriture atomique dans SQLite (fuel_refills + expenses + fuel_state)
      // P0 : Toute exception SQLite est PROPAGÉE (jamais masquée ou considérée comme succès)
      refill = await DatabaseHelper().recordFuelRefill(
        liters: litersAdded,
        pricePerLiter: pricePerLiter,
        levelBefore: levelBefore,
        levelAfter: levelAfter,
        lastCalibTs: _lastCalibTs,
        customId: customId,
        timestamp: nowMs,
        isCalibrated: newCalibrated,
        eventType: newCalibrated ? 'REFILL' : 'REFILL_UNCALIBRATED',
      );
    } catch (e) {
      // Restaurer aussi le calibrage si l'utilisateur avait coché « réservoir plein ».
      _lastCalibTs = previousCalibTs;
      // En cas d'échec SQLite, le plein n'a pas été commité.
      // La consommation mesurée pendant l'I/O n'est pas perdue pour autant si la jauge était calibrée
      if (_isCalibrated) {
        currentLiters = (currentLiters - _pendingConsumptionLiters).clamp(0.0, _tankCapacity);
      }
      _pendingConsumptionLiters = 0.0;
      _isRefilling = false;
      rethrow;
    }

    // 2. À ce stade, la transaction SQLite a RÉELLEMENT été validée et commité durablement.
    _isRefilling = false;
    if (newCalibrated && levelAfter != null) {
      currentLiters = (levelAfter - _pendingConsumptionLiters).clamp(0.0, _tankCapacity);
      _isCalibrated = true;
    } else {
      currentLiters = 0.0;
      _isCalibrated = false;
    }
    _pendingConsumptionLiters = 0.0;

    // Mise à jour SQLite si de la consommation OBD2 mesurée pendant l'écriture a été déduite
    if (newCalibrated && levelAfter != null && currentLiters != levelAfter) {
      final saveTs = _getMonotonicTimestamp();
      try {
        final persisted = await DatabaseHelper().setFuelState(
          liters: currentLiters,
          eventType: 'REFILL_POST_CONSUMPTION',
          lastCalibTs: _lastCalibTs,
          isCalibrated: true,
          updatedAt: saveTs,
        );
        if (!persisted) throw StateError('Synchronisation post-plein rejetée par SQLite');
      } catch (e) {
        // Le plein et sa dépense sont DÉJÀ commitées : ne pas afficher un faux échec
        // qui provoquerait une deuxième saisie financière. Retenter après la file FIFO.
        print('Plein enregistré ; synchronisation consommation différée : $e');
        unawaited(save().catchError((Object error, StackTrace stack) {
          print('Reprise sauvegarde consommation après plein échouée : $error');
        }));
      }
    }

    // 3. Mise à jour du miroir/cache SharedPreferences
    // Si SharedPreferences échoue après le commit SQLite, on ne fait pas échouer le plein commité !
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_isCalibrated) {
        await prefs.setDouble('last_fuel_level', currentLiters);
      }
      await prefs.setInt('last_session_timestamp', nowMs);
    } catch (_) {}

    lowFuelAlerted = false;
    _lastAlertedKm = -1;
    return currentLiters;
  }

  /// Annule un plein précédent de manière strictement idempotente.
  /// La transaction SQLite est la référence unique pour le résultat et la déduction.
  Future<double> cancelFuelRefill(
    double litersAdded, {
    bool deductLiters = true,
    String? refillId,
    int? refillTimestamp,
    double? levelBefore,
  }) {
    return _enqueueExclusive(() => _cancelFuelRefillInternal(
      litersAdded,
      deductLiters: deductLiters,
      refillId: refillId,
      refillTimestamp: refillTimestamp,
      levelBefore: levelBefore,
    ));
  }

  Future<double> _cancelFuelRefillInternal(
    double litersAdded, {
    bool deductLiters = true,
    String? refillId,
    int? refillTimestamp,
    double? levelBefore,
  }) async {
    await init();
    if (!litersAdded.isFinite || litersAdded.isNaN || litersAdded <= 0) {
      throw ArgumentError.value(litersAdded, 'litersAdded', 'La quantité de carburant doit être positive et finie.');
    }

    final shouldDeduct = deductLiters || levelBefore != null;

    if (refillId != null) {
      final nowMs = _getMonotonicTimestamp();
      final result = await DatabaseHelper().cancelFuelRefill(
        refillId,
        deductLiters: shouldDeduct,
        timestamp: nowMs,
      );

      // Si le plein était déjà annulé : idempotence stricte, aucune action sur la mémoire
      if (result.alreadyCanceled || !result.success) {
        return currentLiters;
      }

      // Si SQLite a appliqué la déduction, synchroniser DIRECTEMENT la mémoire avec SQLite
      // (évite toute double déduction entre DatabaseHelper et FuelCalculator)
      if (result.deductLitersApplied && result.newFuelLevel != null) {
        currentLiters = result.newFuelLevel!;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setDouble('last_fuel_level', currentLiters);
        } catch (_) {}
      }
    } else if (shouldDeduct && _isCalibrated) {
      if (refillTimestamp != null && _lastCalibTs > refillTimestamp) {
        return currentLiters;
      }
      if (levelBefore != null && (currentLiters - (levelBefore + litersAdded)).abs() < 1e-4) {
        currentLiters = levelBefore.clamp(0.0, _tankCapacity);
      } else {
        currentLiters = (currentLiters - litersAdded).clamp(0.0, _tankCapacity);
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('last_fuel_level', currentLiters);
      } catch (_) {}
    }

    return currentLiters;
  }


  // Mise à jour par la consommation calculée (MAF ou MAP)
  void updateVirtualFuel(double lph, double secondsPassed) {
    if (!_isInitialized || !lph.isFinite || !secondsPassed.isFinite || lph <= 0 || secondsPassed <= 0) return;
    double consumedLiters = (lph / 3600.0) * secondsPassed;

    if (_isRefilling) {
      // Si un plein est en cours d'enregistrement SQLite, mettre la consommation en tampon
      _pendingConsumptionLiters += consumedLiters;
    } else if (_isCalibrated) {
      currentLiters = (currentLiters - consumedLiters).clamp(0.0, _tankCapacity);
      _saveAsync();
    }

    if (_isCalibrated) {
      // Alerte originale si 0 L
      if (currentLiters <= 5.0 && !lowFuelAlerted) {
        print('Critique, carburant très bas !');
        lowFuelAlerted = true;
      } else if (currentLiters > 5.0) {
        lowFuelAlerted = false;
      }

      // Nouvelles Alertes KMs (Sous 100 km, tous les 10 km)
      int km = kmRestants;
      if (km <= 100 && km > 0) {
        int alertDecade = (km / 10).floor() * 10;
        if (_lastAlertedKm == -1 || alertDecade < _lastAlertedKm) {
          print('Mimo, autonomie basse à $alertDecade kilomètres.');
          _lastAlertedKm = alertDecade;
        }
      } else if (km > 110) {
        _lastAlertedKm = -1;
      }
    }
  }

  // MAF (g/s) → L/h
  double calculateConsumptionLph(double mafGs) {
    if (mafGs <= 0) return 0.0;
    return (mafGs / (_afr * _fuelDensity)) * 3600.0;
  }

  // Mise à jour directe si le PID 012F répond (rare sur Spark)
  void updateRealFuelLevel(double levelPercent, double capacity) {
    if (!_isInitialized || !levelPercent.isFinite || !capacity.isFinite || levelPercent < 0 || levelPercent > 100 || capacity <= 0) return;
    currentLiters = ((levelPercent / 100.0) * capacity).clamp(0.0, _tankCapacity);
    _isCalibrated = true;
    _saveAsync();
  }

  // Km restants estimés selon la consommation configurée (0 si jauge non calibrée)
  int get kmRestants => _isCalibrated ? (currentLiters / _consumptionL100 * 100).toInt() : 0;

  Future<void> save() {
    return _enqueueExclusive(() => _saveInternal());
  }

  Future<void> _saveInternal() async {
    await init();
    // P1 : Ne jamais sauvegarder une jauge non calibrée comme si elle était à 0.0 L réel
    if (!_isCalibrated) return;

    final nowMs = _getMonotonicTimestamp();
    final litersToSave = currentLiters;

    // 1. Sauvegarde durable dans la source de vérité SQLite avec vérification de retour
    final ok = await DatabaseHelper().setFuelState(
      liters: litersToSave,
      eventType: 'OBD_SYNC',
      lastCalibTs: _lastCalibTs,
      isCalibrated: true,
      updatedAt: nowMs,
    );
    if (!ok) {
      throw StateError("Écriture OBD2 rejetée par SQLite (obsolète ou conflit d'horodatage).");
    }

    // 2. Mise à jour du miroir/cache SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_fuel_level', litersToSave);
    await prefs.setInt('last_session_timestamp', nowMs);
  }

  void _saveAsync() {
    final now = DateTime.now();
    if (now.difference(_lastSave) >= const Duration(seconds: 30)) {
      _lastSave = now;
      unawaited(save().catchError((Object error, StackTrace stack) {
        _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
        print('Erreur sauvegarde carburant: $error');
      }));
    }
  }
}
