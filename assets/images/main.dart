import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'scanner_screen.dart';
import 'members_list_screen.dart';
import 'history_screen.dart';
import 'data_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  String? initError;
  
  try {
    // Try to initialize Firebase
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 5), onTimeout: () {
      throw 'Timeout de configuration Firebase (Verifiez votre connexion)';
    });
    
    // Seed members in background
    DataManager.seedInitialMembers().catchError((e) {
      debugPrint("Seeding error: $e");
    });
  } catch (e) {
    debugPrint("Firebase init error: $e");
    initError = e.toString();
  }
  
  runApp(ClubApp(initError: initError));
}

class ClubApp extends StatelessWidget {
  final String? initError;
  const ClubApp({super.key, this.initError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASSIMA-10',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFD32F2F),
          onPrimary: Colors.white,
          secondary: Colors.black,
          surface: Colors.white,
          onSurface: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
      ),
      home: initError != null 
        ? ErrorScreen(error: initError!) 
        : const MainScreen(),
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
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFD32F2F), size: 80),
              const SizedBox(height: 20),
              const Text(
                'ERREUR DE CONFIGURATION',
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
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
                child: const Text('RÉESSAYER'),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const ScannerScreen(),
    const MembersListScreen(),
    const HistoryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(2),
                child: Image.asset('assets/images/logo.webp', height: 31, width: 31, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            const Text('ASSIMA-10', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
          ],
        ),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: _pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner),
            selectedIcon: Icon(Icons.camera_alt),
            label: 'Scanner',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'ZONE 14',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'Historique',
          ),
        ],
      ),
    );
  }
}
