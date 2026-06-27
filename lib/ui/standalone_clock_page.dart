import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:ui';
import 'dart:math' as math;

class StandaloneClockPage extends StatelessWidget {
  const StandaloneClockPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Arrière-plan Voiture Spark (redressée +45°) avec effet de transparence
          Positioned.fill(
            child: Opacity(
              opacity: 0.12, // Très subtil pour faire premium
              child: Transform.rotate(
                angle: 45 * math.pi / 180, // On la redresse pour qu'elle soit droite
                child: Transform.scale(
                  scale: 1.5, // On l'agrandit pour qu'elle remplisse bien l'écran
                  child: Image.asset(
                    'assets/images/Adobe Express - file.png',
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                  ),
                ),
              ),
            ),
          ),
          
          // Dégradé radial pour assombrir les bords et centrer l'attention
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [Colors.transparent, Colors.black.withOpacity(0.95)],
                stops: const [0.3, 1.0],
              ),
            ),
          ),
          
          // Horloge Numérique Premium
          SafeArea(
            child: StreamBuilder(
              stream: Stream.periodic(const Duration(seconds: 1)),
              builder: (context, snapshot) {
                final now = DateTime.now();
                final timeStr = DateFormat('HH:mm').format(now);
                final secStr = DateFormat('ss').format(now);
                final dateStr = DateFormat('EEEE d MMMM').format(now).toUpperCase();

                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Glassmorphism Card
                    ClipRRect(
                      borderRadius: BorderRadius.circular(40),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 30),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(40),
                            border: Border.all(color: const Color(0xFFFF3333).withOpacity(0.3), width: 1.5),
                            boxShadow: [
                              BoxShadow(color: const Color(0xFFFF3333).withOpacity(0.1), blurRadius: 40, spreadRadius: -5),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Heure Numérique
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    timeStr,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 150,
                                      fontWeight: FontWeight.w900,
                                      fontFamily: 'Roboto',
                                      letterSpacing: 2,
                                      shadows: [
                                        Shadow(color: const Color(0xFFFF3333), blurRadius: 25)
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    secStr,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 55,
                                      fontWeight: FontWeight.w300,
                                      fontFamily: 'Roboto',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 15),
                              // Date
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Text(
                                  dateStr,
                                  style: const TextStyle(
                                    color: Colors.white70, 
                                    fontSize: 18, 
                                    letterSpacing: 3,
                                    fontWeight: FontWeight.w500
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 60),
                    
                    // Signature MIMO_OBD
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.speed, color: const Color(0xFFFF3333), size: 20),
                        const SizedBox(width: 10),
                        Text(
                          "MIMO SPARK OS",
                          style: TextStyle(
                            color: const Color(0xFFFF3333).withOpacity(0.7),
                            fontSize: 14,
                            letterSpacing: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          
          // Bouton Retour
          Positioned(
            top: 20,
            left: 20,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 30),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
