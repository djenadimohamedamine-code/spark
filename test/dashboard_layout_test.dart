import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimo_spark/ui/dashboard.dart';
import 'package:mimo_spark/ui/fuel_gauge_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mimo_spark/data/database_helper.dart';
import 'helpers/fake_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'last_fuel_level': 19.3,
      'fuel_price_da': 50.0,
    });
    DatabaseHelper().setDatabaseForTesting(FakeDatabase());
  });

  group('Dashboard Layout V3.1 — Sans grande horloge', () {
    testWidgets('Dashboard se monte correctement en portrait sans overflow', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(375 * 2, 812 * 2);
      tester.view.devicePixelRatio = 2.0;

      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const Dashboard(),
        ),
      );

      await tester.pump();

      // Vérifier la présence des instruments clés
      expect(find.byType(Dashboard), findsOneWidget);
      expect(find.text('CARBURANT'), findsOneWidget);
      expect(find.text('+ Plein'), findsOneWidget);
      expect(find.text('CAL'), findsOneWidget);
      expect(find.text('AUTONOMIE ESTIMÉE'), findsOneWidget);
      // Sur le viewport iPhone 11 Pro, la jauge photo passe de 132 à 156 pt.
      final heroGauge = tester.widgetList<FuelGaugeWidget>(find.byType(FuelGaugeWidget)).first;
      expect(heroGauge.size, 156.0);
      expect(tester.takeException(), isNull);

      // Vérifier que le bouton menu drawer est présent
      expect(find.byIcon(Icons.menu), findsOneWidget);
    });

    testWidgets('Dashboard Drawer contient l\'accès Faire le plein et Horloge Standalone', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(375 * 2, 812 * 2);
      tester.view.devicePixelRatio = 2.0;

      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const Dashboard(),
        ),
      );

      await tester.pump();

      // Ouvrir le Drawer
      final menuButton = find.byIcon(Icons.menu);
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      // Vérifier la présence de "⛽ Faire le plein"
      final refillFinder = find.text('⛽ Faire le plein');
      expect(refillFinder, findsOneWidget);

      // Vérifier la présence de "Calibrage Essence"
      final calibFinder = find.text('Calibrage Essence');
      expect(calibFinder, findsOneWidget);

      // Vérifier la présence de l'horloge autonome dans le drawer en faisant défiler si nécessaire
      final clockFinder = find.text('Horloge (Plein Écran)');
      await tester.scrollUntilVisible(clockFinder, 50, scrollable: find.byType(Scrollable).last);
      expect(clockFinder, findsOneWidget);
    });
  });
}
