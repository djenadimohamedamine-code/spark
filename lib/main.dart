import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
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

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(seconds: 3), vsync: this);
    _scaleAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutQuart));
    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    
    _controller.forward();
    _playStartupSequence();
    
    Timer(const Duration(seconds: 5), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const Dashboard()),
        );
      }
    });
  }

  void _playStartupSequence() async {
    try {
      await _audioPlayer.play(AssetSource('sounds/dragon-studio-car-engine-372477.mp3'));
      await Future.delayed(const Duration(milliseconds: 1500));
      TtsService().speak('Salut Mimo. Système Mimo Spark prêt.');
    } catch (e) {
      print('Erreur Audio: $e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: FadeTransition(
          opacity: _opacityAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Image.asset(
              'assets/images/spark2.png',
              fit: BoxFit.fill, // Remplit tout l'écran 9:16, plus de bandes noires
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        ),
      ),
    );
  }
}


