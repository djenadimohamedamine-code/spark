import 'package:flutter/material.dart';
import 'ui/dashboard.dart';
import 'vocal/tts_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ttsService = TtsService();
  await ttsService.init();
  await ttsService.speak('Système Mimo Smart Car prêt');
  
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
