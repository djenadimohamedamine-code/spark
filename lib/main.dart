import 'package:flutter/material.dart';
import 'ui/dashboard.dart';
import 'vocal/tts_service.dart';

import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Request mandatory permissions for OBD2 WiFi (Android 9+)
  await [
    Permission.location,
    Permission.nearbyWifiDevices,
  ].request();

  final ttsService = TtsService();
  await ttsService.init();
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
