import 'dart:async';
import 'package:flutter/material.dart';
// MIMO SPARK V3.4 - RESTART DUAL BUILD APK & IPA
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

  runApp(const MimoSmartCarApp());
}

class MimoSmartCarApp extends StatelessWidget {
  const MimoSmartCarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MIMO_SPARK',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    TtsService().speak('Salut Mimo. Système Mimo Spark prêt.');
    Timer(const Duration(seconds: 4), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const Dashboard()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: Image.asset(
          'assets/images/IMG_1056.PNG',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}


