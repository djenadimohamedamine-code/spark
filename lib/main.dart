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
    
    FlutterError.onError = (FlutterErrorDetails details) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_crash', "FLUTTER ERROR: ${details.exception}\n${details.stack}");
      FlutterError.presentError(details);
    };

    String? initError;
    try {
      await initializeDateFormatting('fr_FR', null).timeout(const Duration(seconds: 5));
    } catch (e) {
      initError = "DateFormatting: $e";
    }

    try {
      await requestSparkPermissions().timeout(const Duration(seconds: 10));
    } catch (e) {
      initError ??= "Permissions: $e";
    }
    
    runApp(MimoSmartCarApp(initError: initError));
  }, (error, stack) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_crash', "ASYNC ERROR: $error\n$stack");
  });
}

class MimoSmartCarApp extends StatelessWidget {
  final String? initError;
  const MimoSmartCarApp({super.key, this.initError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MIMO_SPARK',
      debugShowCheckedModeBanner: false,
      theme: SparkTheme.theme,
      home: initError != null
          ? ErrorScreen(error: initError!)
          : const SplashScreen(),
    );
  }
}

class ErrorScreen extends StatelessWidget {
  final String error;
  const ErrorScreen({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 80),
              const SizedBox(height: 20),
              const Text(
                'ERREUR DE DÉMARRAGE',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
              ),
              const SizedBox(height: 10),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: () => main(),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent),
                child: const Text('RÉESSAYER'),
              )
            ],
          ),
        ),
      ),
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
