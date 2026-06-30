import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/obd_service.dart';

class PerformancePage extends StatefulWidget {
  const PerformancePage({super.key});

  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  final ObdService _obdService = ObdService();
  StreamSubscription<String>? _sub;

  double _speed = 0.0;
  int _targetSpeed = 50; // Cible par défaut (idéal pour 0.8L)
  
  // États du chrono
  bool _isActive = false;
  bool _isFinished = false;
  DateTime? _startTime;
  double _elapsedSeconds = 0.0;
  Timer? _timer;

  double _best50 = 0.0;
  double _best100 = 0.0;

  String _statusMessage = "Arrêtez-vous pour démarrer";

  @override
  void initState() {
    super.initState();
    _loadBests();
    _sub = _obdService.dataStream.listen(_parseSpeed);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadBests() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _best50 = prefs.getDouble('best_0_50') ?? 0.0;
      _best100 = prefs.getDouble('best_0_100') ?? 0.0;
    });
  }

  Future<void> _saveBest(int target, double value) async {
    final prefs = await SharedPreferences.getInstance();
    if (target == 50) {
      if (_best50 == 0.0 || value < _best50) {
        await prefs.setDouble('best_0_50', value);
        setState(() => _best50 = value);
      }
    } else {
      if (_best100 == 0.0 || value < _best100) {
        await prefs.setDouble('best_0_100', value);
        setState(() => _best100 = value);
      }
    }
  }

  void _parseSpeed(String data) {
    final parts = data.trim().toUpperCase().split(RegExp(r'\s+'));
    for (int i = 0; i < parts.length - 1; i++) {
      if (parts[i] == '41' && i + 1 < parts.length) {
        final pid = parts[i + 1];
        if (pid == '0D' && i + 2 < parts.length) {
          try {
            double rawSpeed = int.parse(parts[i + 2], radix: 16).toDouble();
            _onSpeedUpdate(rawSpeed);
          } catch (_) {}
        }
      }
    }
  }

  void _onSpeedUpdate(double currentSpeed) {
    if (!mounted) return;
    setState(() {
      _speed = currentSpeed;
    });

    // 1. En attente de départ (doit être à 0 km/h)
    if (!_isActive && !_isFinished) {
      if (currentSpeed == 0.0) {
        setState(() {
          _statusMessage = "Prêt ! Accélérez !";
        });
      } else if (currentSpeed > 0.0 && _statusMessage == "Prêt ! Accélérez !") {
        // Départ détecté !
        _startChrono();
      }
    }
    // 2. Pendant le chrono
    else if (_isActive && !_isFinished) {
      if (currentSpeed >= _targetSpeed) {
        _stopChrono(success: true);
      }
    }
  }

  void _startChrono() {
    _startTime = DateTime.now();
    _isActive = true;
    _isFinished = false;
    _elapsedSeconds = 0.0;
    _statusMessage = "Plein gaz !";

    _timer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_startTime != null && mounted) {
        setState(() {
          _elapsedSeconds = DateTime.now().difference(_startTime!).inMilliseconds / 1000.0;
        });
      }
    });
  }

  void _stopChrono({required bool success}) {
    _timer?.cancel();
    setState(() {
      _isActive = false;
      _isFinished = true;
      if (success) {
        _statusMessage = "Terminé !";
        _saveBest(_targetSpeed, _elapsedSeconds);
      } else {
        _statusMessage = "Annulé";
      }
    });
  }

  void _resetChrono() {
    _timer?.cancel();
    setState(() {
      _isActive = false;
      _isFinished = false;
      _elapsedSeconds = 0.0;
      _startTime = null;
      _statusMessage = _speed == 0.0 ? "Prêt ! Accélérez !" : "Arrêtez-vous pour démarrer";
    });
  }

  @override
  Widget build(BuildContext context) {
    double currentBest = _targetSpeed == 50 ? _best50 : _best100;

    return Scaffold(
      appBar: AppBar(
        title: Text("CHRONO 0-$_targetSpeed km/h", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.5,
            colors: [Color(0xFF1F0303), Colors.black],
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Sélecteur de cible
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildTargetButton(50),
                const SizedBox(width: 20),
                _buildTargetButton(100),
              ],
            ),

            // Compteur de Vitesse géant
            Column(
              children: [
                Text(
                  _speed.toStringAsFixed(0),
                  style: const TextStyle(
                    fontSize: 90,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: -4,
                  ),
                ),
                const Text(
                  "KM/H",
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white38,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            // Temps Écoulé
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  Text(
                    "${_elapsedSeconds.toStringAsFixed(2)}s",
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: _isFinished ? Colors.greenAccent : (_isActive ? Colors.orangeAccent : Colors.white60),
                    ),
                  ),
                  Text(
                    _statusMessage.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                      color: _isActive ? Colors.orangeAccent : (_isFinished ? Colors.greenAccent : Colors.white30),
                    ),
                  ),
                ],
              ),
            ),

            // Record Personnel (Best Time)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.emoji_events, color: Color(0xFFFFD700), size: 20),
                const SizedBox(width: 8),
                Text(
                  "RECORD 0-$_targetSpeed : ${currentBest > 0.0 ? '${currentBest.toStringAsFixed(2)}s' : 'Aucun'}",
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            // Bouton de réinitialisation
            ElevatedButton.icon(
              onPressed: _resetChrono,
              icon: const Icon(Icons.refresh, color: Colors.black),
              label: const Text("RÉINITIALISER", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF3333),
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTargetButton(int target) {
    bool isSelected = _targetSpeed == target;
    return GestureDetector(
      onTap: () {
        if (!_isActive) {
          setState(() {
            _targetSpeed = target;
            _resetChrono();
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFF3333) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? Colors.transparent : Colors.white10,
          ),
        ),
        child: Text(
          "0-$target km/h",
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white70,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
