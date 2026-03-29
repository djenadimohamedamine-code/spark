import 'package:flutter/material.dart';
// MIMO SPARK V3.3 - DUAL ANDROID & IOS BUILD
import 'ui/dashboard.dart';
import 'vocal/tts_service.dart';

import 'package:permission_handler/permission_handler.dart';

Future<void> requestSparkPermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.location,
    Permission.nearbyWifiDevices,
  ].request();
  
  if (statuses[Permission.location]!.isGranted) {
    print("Autorisation accordée : Le flux OBD2 peut démarrer.");
  } else {
    print("Autorisation refusée : Les jauges resteront à zéro.");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final ttsService = TtsService();
  await ttsService.init();
  
  // Appeler le forçage des permissions selon le brief de Mimo
  await requestSparkPermissions();

  await ttsService.speak('Salut Mimo. Système Mimo Spark prêt.');
  
  runApp(const MimoSmartCarApp());
}

class MimoSmartCarApp extends StatelessWidget {
  const MimoSmartCarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MIMO_SPARK',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
      ),
      // Prépare l'UI pour être flexible (mode HUD plus tard)
      home: const Dashboard(),
    );
  }
}
