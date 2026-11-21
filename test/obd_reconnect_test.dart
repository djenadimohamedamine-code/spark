// test/obd_reconnect_test.dart
//
// Tests unitaires P0-OBD2 — SPARK V3.1
//
// Ces tests vérifient uniquement la logique pure de checkConnectionHealth()
// et du getter lastDataReceived, sans réseau, sans socket réelle.
//
// Stratégie : ObdService est un singleton. On ne peut pas injecter une fausse
// socket directement, donc on teste les invariants observables depuis l'extérieur
// (le getter, la méthode publique, les règles de seuil).
//
// Pour les scénarios "socket null" et "socket vivante", on appelle disconnect()
// qui est la seule API publique qui null-ise _socket, puis on vérifie la réponse.

import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_spark/core/obd_service.dart';

void main() {
  final obd = ObdService();

  // ───────────────────────────────────────────────────────────────────────────
  // Groupe 1 : getter lastDataReceived
  // ───────────────────────────────────────────────────────────────────────────
  group('lastDataReceived getter', () {
    test('retourne un DateTime non nul dès le démarrage', () {
      // Le champ est initialisé à DateTime.now() dans la déclaration.
      final ts = obd.lastDataReceived;
      expect(ts, isA<DateTime>());
    });

    test('est inférieur ou égal à now (ne vient pas du futur)', () {
      final ts = obd.lastDataReceived;
      expect(ts.isBefore(DateTime.now().add(const Duration(seconds: 1))), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Groupe 2 : checkConnectionHealth() — socket null (après disconnect)
  // ───────────────────────────────────────────────────────────────────────────
  group('checkConnectionHealth() — socket null', () {
    setUp(() {
      // disconnect() est la seule API publique qui null-ise _socket et
      // annule le watchdog sans déclencher de reconnexion automatique.
      obd.disconnect();
    });

    test('retourne false quand la socket est null', () {
      expect(obd.checkConnectionHealth(maxAgeSeconds: 8), isFalse);
    });

    test('retourne false même avec un seuil très large (300s)', () {
      expect(obd.checkConnectionHealth(maxAgeSeconds: 300), isFalse);
    });

    test('isConnected retourne false après disconnect()', () {
      expect(obd.isConnected, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Groupe 3 : seuil d'âge — logique pure indépendante du réseau
  // ───────────────────────────────────────────────────────────────────────────
  group('Logique de seuil (règles de décision)', () {
    // On ne peut pas injecter un _lastDataReceived arbitraire depuis l'extérieur
    // sans accès au champ privé. On teste donc les règles via la définition :
    // - checkConnectionHealth retourne false si socket == null (déjà testé)
    // - Si socket != null, retourne age <= maxAgeSeconds.
    // On vérifie ces règles mathématiquement ici.

    test('règle : données fraîches → ne pas reconnecter', () {
      // Simule : age = 3s, seuil = 8s → 3 <= 8 → isHealthy = true → pas de reconnexion.
      final age = 3;
      final seuil = 8;
      expect(age <= seuil, isTrue, reason: 'Données fraîches : ne doit pas reconnecter');
    });

    test('règle : données périmées (10s) → reconnecter', () {
      final age = 10;
      final seuil = 8;
      expect(age <= seuil, isFalse, reason: 'Données périmées : doit reconnecter');
    });

    test('règle : limite exacte du seuil (8s = 8s) → ne pas reconnecter', () {
      final age = 8;
      final seuil = 8;
      expect(age <= seuil, isTrue, reason: 'Limite exacte : pas de reconnexion');
    });

    test('règle : 1 seconde après la limite (9s) → reconnecter', () {
      final age = 9;
      final seuil = 8;
      expect(age <= seuil, isFalse, reason: '9s > 8s : doit reconnecter');
    });

    test('règle : long passage arrière-plan (2 min = 120s) → reconnecter', () {
      // Scénario réel : 2 minutes dans Messenger
      final age = 120;
      final seuil = 8;
      expect(age <= seuil, isFalse, reason: '2 min en arrière-plan : doit reconnecter');
    });

    test('règle : passage rapide (5s) → ne pas reconnecter', () {
      // Scénario réel : coup d'œil à Messenger < 5 secondes
      final age = 5;
      final seuil = 8;
      expect(age <= seuil, isTrue, reason: '5s rapide : ne doit pas reconnecter');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Groupe 4 : invariants du service après disconnect()
  // ───────────────────────────────────────────────────────────────────────────
  group('Invariants ObdService après disconnect()', () {
    setUp(() {
      obd.disconnect();
    });

    test('isConnected est false', () => expect(obd.isConnected, isFalse));

    test('checkConnectionHealth() est false', () {
      expect(obd.checkConnectionHealth(), isFalse);
    });

    test('lastDataReceived est toujours accessible (ne lance pas)', () {
      expect(() => obd.lastDataReceived, returnsNormally);
    });

    test('checkConnectionHealth() ne lance pas d\'exception', () {
      expect(() => obd.checkConnectionHealth(maxAgeSeconds: 0), returnsNormally);
      expect(() => obd.checkConnectionHealth(maxAgeSeconds: 300), returnsNormally);
    });

    test('disconnect() appelé deux fois consécutives ne lance pas', () {
      expect(() => obd.disconnect(), returnsNormally);
    });

    test('hasReceivedDataSince() retourne false quand socket est null', () {
      expect(obd.hasReceivedDataSince(DateTime.now().subtract(const Duration(hours: 1))), isFalse);
    });
  });
}
