import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../vocal/tts_service.dart';
import '../logic/fuel_calculator.dart';
import '../core/obd_service.dart';
import '../core/gear_calculator.dart';
import 'diagnostic.dart';
import 'mileage_page.dart';
import 'map_page.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  // Gauges Data
  double temperature = 0.0;
  double rpm = 0.0;
  double speed = 0.0;
  double tension = 0.0;
  String currentGear = 'N';
  bool isHudMode = false;

  DateTime lastMafTime = DateTime.now();
  bool rpmAlertTriggered = false;
  
  // Console de Log pour Mimo
  final Queue<String> _logQueue = Queue<String>();
  String rawLog = "En attente de données...";
  
  final TtsService _ttsService = TtsService();
  final FuelCalculator _fuelCalculator = FuelCalculator();
  final ObdService _obdService = ObdService();
  
  bool alert98Triggered = false;
  bool alert103Triggered = false;

  // Optimisations PRO+++ (Tesla Level)
  Timer? _uiTimer;
  final Map<String, dynamic> _buffer = {};
  double _smoothVoltage = 0.0;
  double _smoothLph = 0.0;
  double _smoothTemp = 0.0;
  
  // Cooldowns d'alertes par label (Pro Style)
  final Map<String, DateTime> _alertCooldowns = {};

  StreamSubscription<String>? _obdSubscription;

  // Calcul du score de santé (Health Score)
  int get healthScore {
    int score = 100;
    if (temperature > 100) score -= 15;
    else if (temperature > 95) score -= 5;
    if (rpm > 4500) score -= 10;
    if (tension < 12.5 && tension > 0 && tension < 20) score -= 10;
    return score.clamp(0, 100);
  }

  void _scheduleUpdate() {
    if (_uiTimer != null) return;
    _uiTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          rpm = _buffer['rpm'] ?? rpm;
          speed = _buffer['speed'] ?? speed;
          temperature = _buffer['temp'] ?? temperature;
          tension = _buffer['tension'] ?? tension;
          currentGear = _buffer['gear'] ?? currentGear;
        });
      }
      _uiTimer = null;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _fuelCalculator.init();
    _loadFuelCalibration(); // Charger le calibrage sauvegardé
    _connectObd();
  }

  Future<void> _loadFuelCalibration() async {
    final prefs = await SharedPreferences.getInstance();
    double savedFuel = prefs.getDouble('fuel_calibration') ?? 15.0; // 15L par défaut
    _fuelCalculator.calibrate(savedFuel);
    if (mounted) setState(() {});
  }

  Future<void> _saveFuelCalibration(double val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fuel_calibration', val);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // On vérifie si la connexion a survécu au passage en arrière-plan
      if (_obdService.socket == null) {
        print("Mimo Spark : Connexion perdue en arrière-plan. Reconnexion...");
        _connectObd();
      } else {
        print("Mimo Spark : Connexion maintenue. Reprise directe.");
      }
    }
  }

  void _showFuelCalibrationDialog() {
    double tempFuel = _fuelCalculator.currentLiters;
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF101010),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
          title: const Center(
             child: Text('CALIBRAGE ANALOGIQUE (AIGUILLE)', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Aligne l\'aiguille digitale exactement sur ton vrai cadran', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 11)),
              const SizedBox(height: 20),
              // Gauge superposée sur la photo ta.jpeg
              Container(
                width: 240, height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 2),
                  boxShadow: [BoxShadow(color: Colors.orangeAccent.withOpacity(0.15), blurRadius: 20)],
                  image: const DecorationImage(
                    image: AssetImage('assets/images/ta.jpeg'),
                    fit: BoxFit.cover,
                  ),
                ),
                child: SfRadialGauge(
                  axes: <RadialAxis>[
                    RadialAxis(
                      minimum: 0, maximum: 35,
                      startAngle: 215, endAngle: 315, // Calibrage optimal pour Spark : E=215° / F=315°
                      showLabels: false, showTicks: false,
                      axisLineStyle: const AxisLineStyle(thickness: 0, color: Colors.transparent),
                      pointers: <GaugePointer>[
                        NeedlePointer(
                          value: tempFuel, 
                          needleColor: Colors.orangeAccent,
                          tailStyle: const TailStyle(width: 8, color: Colors.orangeAccent),
                          needleStartWidth: 1, needleEndWidth: 7, 
                          needleLength: 0.85, 
                          knobStyle: const KnobStyle(color: Colors.white, knobRadius: 0.12),
                          enableAnimation: true,
                          enableDragging: true,
                          onValueChanged: (val) {
                            setLocal(() => tempFuel = val);
                          },
                        )
                      ]
                    )
                  ]
                )
              ),
              const SizedBox(height: 10),
              const Text('DRAGUEZ L\'AIGUILLE DIRECTEMENT', 
                style: TextStyle(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx), 
              child: const Text('ANNULER', style: TextStyle(color: Colors.grey))
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
              onPressed: () async {
                Navigator.pop(ctx);
                _fuelCalculator.calibrate(tempFuel);
                await _saveFuelCalibration(tempFuel); // Sauvegarde persistante
                setState(() {}); 
                _ttsService.speak("Calibrage du carburant enregistré.");
              },
              child: const Text('CALER AIGUILLE', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }



  void _connectObd() async {
    bool connected = await _obdService.connect();
    if (connected) {
      _obdSubscription?.cancel();
      _obdSubscription = _obdService.dataStream.listen((data) {
        if (mounted) {
          _appendLog(data);
          _parseObdData(data);
        }
      });
    }
  }

  void _appendLog(String line) {
    _logQueue.add(line);
    if (_logQueue.length > 8) _logQueue.removeFirst();
    setState(() {
      rawLog = _logQueue.join('\n');
    });
  }

  // DRY Alert Helper (Tesla Style)
  void _checkAlert(String label, double value, double threshold, int cooldownSec, String message) {
    final now = DateTime.now();
    final lastTime = _alertCooldowns[label] ?? now.subtract(const Duration(hours: 1));

    if (value >= threshold && now.difference(lastTime).inSeconds > cooldownSec) {
      _ttsService.speakAlert(message);
      _alertCooldowns[label] = now;
    }
  }

  void _parseObdData(String data) {
    if (data.trim().isEmpty || data.contains('SEARCHING') || data.contains('NO DATA') || data.contains('STOPPED')) return;
    
    // Version ELITE PRO : Parsing Séquentiel par Index pour éviter les confusions de trames
    List<String> parts = data.trim().toUpperCase().split(RegExp(r'\s+'));

    for (int i = 0; i < parts.length - 1; i++) {
      if (parts[i] == '41') {
        String pid = parts[i + 1];

        switch (pid) {
          case '0C': // RPM (2 octets)
            if (i + 3 < parts.length) {
              int a = int.tryParse(parts[i + 2], radix: 16) ?? 0;
              int b = int.tryParse(parts[i + 3], radix: 16) ?? 0;
              double newRpm = ((a * 256) + b) / 4.0;
              _buffer['rpm'] = newRpm;
              _buffer['gear'] = (speed < 5 || newRpm < 1000) ? 'N' : GearCalculator.calculateGear(newRpm.toInt(), speed.toInt());
              _checkAlert("RPM_HIGH", newRpm, 3500, 7, "Mimo, réduit les gaz, 3500 tours !");
            }
            break;

          case '05': // TEMP (1 octet)
            if (i + 2 < parts.length) {
              double rawVal = (int.tryParse(parts[i + 2], radix: 16) ?? 40).toDouble() - 40.0;
              // Filtrage anti-vibrations (EMA Smoothing)
              _smoothTemp = (_smoothTemp == 0) ? rawVal : (_smoothTemp * 0.85) + (rawVal * 0.15);
              _buffer['temp'] = _smoothTemp;
              _checkAlert("TEMP_98", _smoothTemp, 98, 10, "Attention Mimo, 98 degrés.");
              _checkAlert("TEMP_103", _smoothTemp, 103, 5, "Critique ! temp 103 !");
            }
            break;

          case '0D': // SPEED (1 octet)
            if (i + 2 < parts.length) {
              double newSpeed = (int.tryParse(parts[i + 2], radix: 16) ?? 0).toDouble();
              _buffer['speed'] = newSpeed;
            }
            break;

          case '0B': // MAP (pour MAF Virtuel)
            if (i + 2 < parts.length) {
              int mapKpa = int.tryParse(parts[i + 2], radix: 16) ?? 0;
              final double tempK = _obdService.lastIatKelvin;
              double mafGs = (rpm * mapKpa / 120.0) * 0.8 * 1.0 * (28.97 / 8.314) / tempK;
              double rawLph = _fuelCalculator.calculateConsumptionLph(mafGs);
              _smoothLph = (_smoothLph == 0) ? rawLph : (_smoothLph * 0.9) + (rawLph * 0.1);
              
              DateTime now = DateTime.now();
              double delta = now.difference(lastMafTime).inMilliseconds / 1000.0;
              lastMafTime = now;
              _fuelCalculator.updateVirtualFuel(_smoothLph, delta);
            }
            break;
        }
      }
    }

    // Gestion ATRV (Batterie) - N'est pas préfixé par 41
    if (data.contains('V') && data.contains('.')) {
      try {
        String volStr = data.replaceAll(RegExp(r'[^0-9.]'), '');
        double rawVolt = double.tryParse(volStr) ?? 0.0;
        if (rawVolt > 0) {
          _smoothVoltage = (_smoothVoltage == 0) ? rawVolt : (_smoothVoltage * 0.8) + (rawVolt * 0.2);
          _buffer['tension'] = _smoothVoltage;
        }
      } catch (_) {}
    }

    _scheduleUpdate();
  }

  void _shareLog() async {
    File? logFile = await _obdService.getLogFile();
    if (logFile != null) await Share.shareXFiles([XFile(logFile.path)], text: 'Journal de bord Mimo Spark OBD2 Dashboard');
  }

  Widget _buildHudTransform({required Widget child}) {
    return Transform(
      alignment: Alignment.center,
      transform: isHudMode ? (Matrix4.identity()..rotateY(3.14159)) : Matrix4.identity(),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050505),
      endDrawer: Drawer(
        child: Container(
          color: const Color(0xFF0F0F0F),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              UserAccountsDrawerHeader(
                accountName: const Text('Mimo', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                accountEmail: const Text('Directeur Technique', style: TextStyle(color: Colors.cyanAccent)),
                currentAccountPicture: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.cyanAccent, width: 2),
                    boxShadow: [BoxShadow(color: Colors.cyanAccent.withOpacity(0.5), blurRadius: 10)],
                  ),
                  child: const CircleAvatar(backgroundImage: AssetImage('assets/images/IMG_0730.JPG')),
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF151828), Colors.black], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.dashboard, color: Colors.white),
                title: const Text('Dashboard', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.warning, color: Colors.redAccent),
                title: const Text('Analyse DTC', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => DiagnosticPage(obdService: _obdService)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.radar, color: Colors.orangeAccent),
                title: const Text('Mileage Analyzer PRO', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => MileagePage(obdService: _obdService)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.map, color: Colors.lightBlueAccent),
                title: const Text('Navigation GPS', style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text('Vue satellite + trafic temps réel', style: TextStyle(color: Colors.white38, fontSize: 10)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const MapPage()));
                },
              ),
              ListTile(
                leading: Icon(isHudMode ? Icons.flip_to_front : Icons.flip_to_back, color: Colors.cyanAccent),
                title: Text(isHudMode ? 'Mode Normal' : 'Mode HUD (Miroir)', style: const TextStyle(color: Colors.cyanAccent)),
                onTap: () {
                  setState(() => isHudMode = !isHudMode);
                  Navigator.pop(context);
                  _ttsService.speak(isHudMode ? "Mode miroir activé" : "Mode normal");
                },
              ),
              ListTile(
                leading: const Icon(Icons.local_gas_station, color: Colors.orangeAccent),
                title: const Text('Calibrage Essence', style: TextStyle(color: Colors.orangeAccent)),
                subtitle: const Text('Caler l\'aiguille sur ton vrai compteur', style: TextStyle(color: Colors.grey, fontSize: 11)),
                onTap: () {
                  Navigator.pop(context);
                  _showFuelCalibrationDialog();
                },
              ),
            ],
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [Color(0xFF151828), Color(0xFF000000)],
          ),
        ),
        child: Column(
          children: [
            // App Bar Personnalisée
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.share, color: Colors.cyanAccent),
                      onPressed: _shareLog,
                      tooltip: "Partager les logs",
                    ),
                    Expanded(
                      child: _buildHudTransform(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.speed, color: Colors.redAccent, size: 24),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'MIMO SPARK V4.31',
                                style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.0, fontStyle: FontStyle.italic),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Indicateur de statut
                            Container(
                              width: 8, height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _obdService.socket != null ? Colors.greenAccent : Colors.redAccent,
                                boxShadow: [BoxShadow(color: (_obdService.socket != null ? Colors.greenAccent : Colors.redAccent).withOpacity(0.5), blurRadius: 4, spreadRadius: 1)],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Builder(builder: (context) {
                      return IconButton(
                        icon: const Icon(Icons.menu, color: Colors.cyanAccent),
                        onPressed: () => Scaffold.of(context).openEndDrawer(),
                      );
                    }),
                  ],
                ),
              ),
            ),
            // GESTION DU CORPS DE L'APPLICATION
            Expanded(
              child: _buildHudTransform(
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
                          child: Column(
                            children: [
                              if (!isHudMode) ...[
                                _buildBatteryStatus(),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(child: _buildFuelGauge()),
                                    Expanded(child: _buildTempGauge()),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(child: _buildRpmGauge()),
                                    Expanded(child: _buildSpeedGauge()),
                                  ],
                                ),
                              ] else ...[
                                // Mode HUD : Uniquement Vitesse (En haut) et RPM (En bas)
                                _buildSpeedGauge(),
                                const SizedBox(height: 20),
                                _buildRpmGauge(),
                              ]
                            ],
                          ),
                        ),
                      ),
                    ),
                    // CONSOLE DE LOG
                    Container(
                      height: 40,
                      width: double.infinity,
                      color: Colors.black.withOpacity(0.8),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: Text(rawLog, style: const TextStyle(color: Colors.greenAccent, fontSize: 8, fontFamily: 'monospace')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatteryStatus() {
    int health = healthScore;
    Color healthColor = health > 90 ? Colors.greenAccent : (health > 70 ? Colors.orangeAccent : Colors.redAccent);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: healthColor.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite, color: healthColor, size: 14),
              const SizedBox(width: 6),
              Text('ENGINE HEALTH: $health%', style: TextStyle(color: healthColor, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.black87, Colors.grey.shade900],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: tension > 13.5 ? Colors.green.withOpacity(0.5) : Colors.orange.withOpacity(0.5), width: 1.5),
            boxShadow: [
              BoxShadow(color: (tension > 13.5 ? Colors.green : Colors.orange).withOpacity(0.2), blurRadius: 10, spreadRadius: 1)
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(tension > 13.5 ? Icons.battery_charging_full : Icons.battery_alert, 
                   color: tension > 13.5 ? Colors.greenAccent : Colors.orangeAccent, size: 24),
              const SizedBox(width: 8),
              Text('${tension.toStringAsFixed(1)} V', 
                   style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
            ],
          ),
        ),
      ],
    );
  }

  // --- GAUGE DESIGN METRICS ---
  
  Widget _buildGlassCard({required Widget child, required double height}) {
    return Container(
      height: height,
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFF121212).withOpacity(0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 15, offset: const Offset(0, 5))
        ],
      ),
      child: child,
    );
  }

  Widget _buildFuelGauge() {
    double fuelVal = _fuelCalculator.currentLiters;
    int kmRestants = (fuelVal / 9.5 * 100).toInt();
    
    return _buildGlassCard(
      height: isHudMode ? 240 : 180, 
      child: SfRadialGauge(
        axes: <RadialAxis>[
          RadialAxis(
            minimum: 0, maximum: 35,
            startAngle: 160, endAngle: 20,
            showLabels: false, showTicks: false,
            axisLineStyle: const AxisLineStyle(thickness: 12, cornerStyle: CornerStyle.bothCurve, color: Colors.white10),
            pointers: <GaugePointer>[
              RangePointer(
                value: fuelVal, width: 12, cornerStyle: CornerStyle.bothCurve,
                gradient: const SweepGradient(colors: [Colors.red, Colors.orange, Colors.greenAccent], stops: [0.1, 0.4, 0.9]),
              ),
              MarkerPointer(value: fuelVal, markerType: MarkerType.circle, color: Colors.white, markerHeight: 15, markerWidth: 15)
            ],
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.local_gas_station, color: Colors.white70, size: 20),
                    const SizedBox(height: 4),
                    Text('$kmRestants KM', style: TextStyle(color: kmRestants <= 70 ? Colors.redAccent : (kmRestants <= 120 ? Colors.orangeAccent : Colors.greenAccent), fontSize: 26, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text('${fuelVal.toStringAsFixed(1)} L', style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                angle: 90, positionFactor: 0.1
              )
            ],
          )
        ],
      )
    );
  }

  Widget _buildTempGauge() {
    return _buildGlassCard(
      height: isHudMode ? 240 : 180, 
      child: SfRadialGauge(
        axes: <RadialAxis>[
          RadialAxis(
            minimum: 50, maximum: 130,
            startAngle: 160, endAngle: 20,
            showLabels: false, showTicks: false,
            axisLineStyle: const AxisLineStyle(thickness: 12, cornerStyle: CornerStyle.bothCurve, color: Colors.white10),
            pointers: <GaugePointer>[
              RangePointer(
                value: temperature == 0 ? 50 : temperature, width: 12, cornerStyle: CornerStyle.bothCurve,
                gradient: const SweepGradient(colors: [Colors.lightBlue, Colors.orange, Colors.redAccent], stops: [0.3, 0.7, 0.9]),
              ),
              MarkerPointer(value: temperature == 0 ? 50 : temperature, markerType: MarkerType.circle, color: Colors.white, markerHeight: 15, markerWidth: 15)
            ],
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.thermostat, color: Colors.white70, size: 20),
                    const SizedBox(height: 4),
                    Text('${temperature.toStringAsFixed(0)}°C', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  ],
                ),
                angle: 90, positionFactor: 0.1
              )
            ],
          )
        ],
      )
    );
  }

  Widget _buildRpmGauge() {
    return _buildGlassCard(
      height: isHudMode ? 320 : 220, 
      child: SfRadialGauge(
        axes: <RadialAxis>[
          RadialAxis(
            minimum: 0, maximum: 8000,
            startAngle: 140, endAngle: 40,
            axisLineStyle: const AxisLineStyle(thickness: 0.1, color: Colors.transparent),
            majorTickStyle: const MajorTickStyle(length: 12, thickness: 2, color: Colors.white),
            minorTickStyle: const MinorTickStyle(length: 6, thickness: 1, color: Colors.white54),
            axisLabelStyle: const GaugeTextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
            ranges: <GaugeRange>[
              GaugeRange(startValue: 0, endValue: 6000, color: Colors.cyanAccent.withOpacity(0.3), startWidth: 10, endWidth: 10), 
              GaugeRange(startValue: 6000, endValue: 8000, color: Colors.redAccent.withOpacity(0.6), startWidth: 10, endWidth: 15)
            ], 
            pointers: <GaugePointer>[
              NeedlePointer(
                value: rpm, needleColor: Colors.cyanAccent, tailStyle: const TailStyle(width: 8, color: Colors.cyanAccent),
                needleStartWidth: 1, needleEndWidth: 5, knobStyle: const KnobStyle(color: Colors.white, knobRadius: 0.08),
                enableAnimation: true, animationDuration: 300, animationType: AnimationType.ease
              )
            ], 
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(currentGear, style: const TextStyle(color: Colors.redAccent, fontSize: 36, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                    const Text('GEAR', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 2)),
                    const SizedBox(height: 10),
                    Text('${rpm.toInt()}', style: const TextStyle(color: Colors.cyanAccent, fontSize: 22, fontWeight: FontWeight.bold)),
                    const Text('RPM', style: TextStyle(color: Colors.white54, fontSize: 9, letterSpacing: 1)),
                  ],
                ), 
                angle: 90, positionFactor: 0.7
              )
            ]
          )
        ],
      )
    );
  }

  Widget _buildSpeedGauge() {
    return _buildGlassCard(
      height: isHudMode ? 320 : 220, 
      child: SfRadialGauge(
        axes: <RadialAxis>[
          RadialAxis(
            minimum: 0, maximum: 200,
            startAngle: 140, endAngle: 40,
            axisLineStyle: const AxisLineStyle(thickness: 0.1, color: Colors.transparent),
            majorTickStyle: const MajorTickStyle(length: 12, thickness: 2, color: Colors.white),
            minorTickStyle: const MinorTickStyle(length: 6, thickness: 1, color: Colors.white54),
            axisLabelStyle: const GaugeTextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
            ranges: <GaugeRange>[
              GaugeRange(startValue: 0, endValue: 120, color: Colors.purpleAccent.withOpacity(0.3), startWidth: 10, endWidth: 10), 
              GaugeRange(startValue: 120, endValue: 200, color: Colors.redAccent.withOpacity(0.6), startWidth: 10, endWidth: 15)
            ], 
            pointers: <GaugePointer>[
              NeedlePointer(
                value: speed, needleColor: Colors.purpleAccent, tailStyle: const TailStyle(width: 8, color: Colors.purpleAccent),
                needleStartWidth: 1, needleEndWidth: 5, knobStyle: const KnobStyle(color: Colors.white, knobRadius: 0.08),
                enableAnimation: true, animationDuration: 300, animationType: AnimationType.ease
              )
            ], 
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${speed.toInt()}', style: const TextStyle(color: Colors.white, fontSize: 46, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                    const Text('KM/H', style: TextStyle(color: Colors.purpleAccent, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  ],
                ), 
                angle: 90, positionFactor: 0.7
              )
            ]
          )
        ],
      )
    );
  }



  @override
  void dispose() {
    WakelockPlus.disable();
    _uiTimer?.cancel();
    _obdSubscription?.cancel();
    _obdService.dispose();
    super.dispose();
  }
}
