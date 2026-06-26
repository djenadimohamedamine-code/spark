import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'ui/dashboard.dart';
import 'core/background_service.dart';
import 'core/spark_theme.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> requestSparkPermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.location,
    Permission.nearbyWifiDevices,
    Permission.notification,
    Permission.microphone,
  ].request();
  
  if (statuses[Permission.location]!.isGranted) {
    print("Autorisation accordée : Le flux OBD2 peut démarrer.");
  } else {
    print("Autorisation refusée : Les jauges resteront à zéro.");
  }
}

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Capture les erreurs de Flutter (UI, etc.)
    FlutterError.onError = (FlutterErrorDetails details) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_crash', "FLUTTER ERROR: ${details.exception}\n${details.stack}");
      FlutterError.presentError(details);
    };

    await initializeDateFormatting('fr_FR', null);
    await requestSparkPermissions();
    
    runApp(const MimoSmartCarApp());
  }, (error, stack) async {
    // Capture les erreurs asynchrones
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_crash', "ASYNC ERROR: $error\n$stack");
    print("CRASH CAPTURÉ: $error");
  });
}

class MimoSmartCarApp extends StatelessWidget {
  const MimoSmartCarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MIMO_SPARK',
      debugShowCheckedModeBanner: false,
      theme: SparkTheme.theme,
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
    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutQuart));
    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    
    _controller.forward();
    _playStartupSequence();
    
    // Après 5s : fade-out puis navigation vers le Dashboard
    Timer(const Duration(seconds: 5), () async {
      if (!mounted) return;
      await _controller.reverse(from: 1.0); // Fade out en douceur
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const Dashboard(),
            transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
            transitionDuration: const Duration(milliseconds: 600),
          ),
        );
      }
    });
  }

  void _playStartupSequence() async {
    try {
      await _audioPlayer.play(AssetSource('sounds/dragon-studio-car-engine-372477.mp3'));
      await Future.delayed(const Duration(milliseconds: 1500));
      print('Salut Mimo. Système Mimo Spark prêt.');
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
            child: Container(
              color: Colors.black,
              child: Image.asset(
                'assets/images/spark2.png',
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
