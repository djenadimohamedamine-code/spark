import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_spark/core/gps_debug_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapPage - Bouton retour GPS & préservation de l\'état', () {
    test('GpsDebugLogger.close() préserve l\'état enabled et les logs accumulés', () async {
      GpsDebugLogger.enabled = true;
      GpsDebugLogger.mark('TEST_BEFORE_POP');
      expect(GpsDebugLogger.lines.isNotEmpty, isTrue);
      expect(GpsDebugLogger.lines.last, contains('TEST_BEFORE_POP'));

      // Simuler dispose() de MapPage qui appelle GpsDebugLogger.close()
      await GpsDebugLogger.close();

      // Vérifier que le logger reste actif et que les logs n'ont pas été effacés
      expect(GpsDebugLogger.enabled, isTrue);
      expect(GpsDebugLogger.lines.isNotEmpty, isTrue);
      expect(GpsDebugLogger.lines.last, contains('TEST_BEFORE_POP'));

      // Remettre à l'état par défaut (désactivé)
      GpsDebugLogger.enabled = false;
    });

    testWidgets('Bouton retour déclenche Navigator.maybePop sans erreur', (WidgetTester tester) async {
      bool popped = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => Scaffold(
                            body: Stack(
                              children: [
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  child: SafeArea(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 8, left: 12),
                                      child: Material(
                                        color: Colors.black87,
                                        shape: const CircleBorder(),
                                        elevation: 6,
                                        shadowColor: Colors.black54,
                                        child: IconButton(
                                          key: const Key('map_back_button'),
                                          tooltip: 'Retour au tableau de bord',
                                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                                          onPressed: () {
                                            popped = true;
                                            Navigator.maybePop(context);
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Open Map'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      // Ouvrir la page simulée
      await tester.tap(find.text('Open Map'));
      await tester.pumpAndSettle();

      // Vérifier que le bouton de retour est visible
      expect(find.byKey(const Key('map_back_button')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      // Cliquer sur le bouton retour
      await tester.tap(find.byKey(const Key('map_back_button')));
      await tester.pumpAndSettle();

      // Vérifier que maybePop a été exécuté et que nous sommes de retour sur la page précédente
      expect(popped, isTrue);
      expect(find.text('Open Map'), findsOneWidget);
    });
  });
}
