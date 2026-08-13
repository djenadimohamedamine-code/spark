import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/switcher_provider.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SwitcherProvider()),
      ],
      child: const Mv7000App(),
    ),
  );
}

class Mv7000App extends StatelessWidget {
  const Mv7000App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sony MVS-7000 Live Switcher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111111),
        textTheme: GoogleFonts.interTextTheme(
          Theme.of(context).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
