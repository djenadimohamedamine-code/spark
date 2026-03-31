import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../vocal/tts_service.dart';
import '../logic/fuel_calculator.dart';
import '../core/obd_service.dart';
import '../core/gear_calculator.dart';
import 'diagnostic.dart';

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
  String rawLog = "En attente de données...";
  
  final TtsService _ttsService = TtsService();
  final FuelCalculator _fuelCalculator = FuelCalculator();
  final ObdService _obdService = ObdService();
  
  bool alert98Triggered = false;
  bool alert103Triggered = false;

  StreamSubscription<String>? _obdSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _fuelCalculator.init();
    _connectObd();

  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Forcer la fermeture du socket TCP pour éviter le "Broken Pipe" fantôme iOS/Android
      print("Mimo Spark : App en arrière-plan. Déconnexion agressive OBD.");
      _obdService.disconnect();
    } else if (state == AppLifecycleState.resumed) {
      // Reconnexion propre au retour
      print("Mimo Spark : App de retour. Reconnexion OBD...");
      _connectObd();
    }
  }

  void _showFuelCalibrationDialog() {
    double tempFuel = _fuelCalculator.currentLiters;
    // 10 segments pour caler selon les reperes (slashes) du tableau Spark
    // Chaque segment = 35 / 10 = 3.5 Litres
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF101010),
          title: const Column(
            children: [
              Icon(Icons.local_gas_station, color: Colors.orange, size: 30),
              SizedBox(height: 6),
              Text('Calibrage Réel', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              Text('Touche tes segments (slashes) Spark', style: TextStyle(color: Colors.grey, fontSize: 11)),
            ],
          ),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Visualisation des slashes de jauge
              Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(10, (index) {
                  int segId = 10 - index; // De 10 (Haut) à 1 (Bas)
                  bool isActive = tempFuel >= (segId * 3.5) - 1.75; // Seuil median pour le clic
                  
                  Color segColor;
                  if (segId <= 2) segColor = Colors.redAccent;
                  else if (segId <= 5) segColor = Colors.orangeAccent;
                  else segColor = Colors.greenAccent;
                  
                  return GestureDetector(
                    onTap: () => setLocal(() => tempFuel = segId * 3.5),
                    child: Container(
                      width: 80, height: 18,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      decoration: BoxDecoration(
                        color: isActive ? segColor : Colors.white10,
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: isActive ? [BoxShadow(color: segColor.withOpacity(0.5), blurRadius: 4)] : null,
                      ),
                      child: Center(
                        child: Text(segId == 10 ? 'FULL' : (segId == 1 ? 'E' : ''), 
                             style: const TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(width: 25),
              // Affichage du volume calcule
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${tempFuel.toStringAsFixed(1)}L', style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900)),
                  const Text('LITRES', style: TextStyle(color: Colors.grey, fontSize: 10)),
                  const SizedBox(height: 20),
                  Text('${(tempFuel / 9.5 * 100).toInt()} km', style: const TextStyle(color: Colors.cyanAccent, fontSize: 18, fontWeight: FontWeight.bold)),
                  const Text('AUTONOMIE', style: TextStyle(color: Colors.grey, fontSize: 10)),
                ],
              )
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ANNULER', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              onPressed: () {
                Navigator.pop(ctx);
                _fuelCalculator.calibrate(tempFuel);
                setState(() {});
              },
              child: const Text('CALER LE NIVEAU', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }



  void _connectObd() async {
    bool connected = await _obdService.connect();
    if (connected) {
      _obdSubscription?.cancel(); // Nettoyer l'ancienne écoute
      _obdSubscription = _obdService.dataStream.listen((data) {
        if (mounted) {
          setState(() {
            rawLog += "\n$data";
            List<String> lines = rawLog.split('\n');
            if (lines.length > 10) rawLog = lines.sublist(lines.length - 10).join('\n');
          });
          _parseObdData(data);
        }
      });
    }
  }

  void _parseObdData(String data) {
    String cleanData = data.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');

    // RPM (410C)
    if (cleanData.contains('410C')) {
      try {
        int idx = cleanData.indexOf('410C') + 4;
        if (cleanData.length >= idx + 4) {
          int a = int.parse(cleanData.substring(idx, idx + 2), radix: 16);
          int b = int.parse(cleanData.substring(idx + 2, idx + 4), radix: 16);
          setState(() {
            rpm = ((a * 256) + b) / 4.0;
            currentGear = GearCalculator.calculateGear(rpm.toInt(), speed.toInt());
          });
          if (rpm >= 3200 && !rpmAlertTriggered) {
             _ttsService.speakAlert("Bip, Bip ! Dépassement 3200 tours !");
             rpmAlertTriggered = true;
          } else if (rpm < 3000) {
             rpmAlertTriggered = false;
          }
        }
      } catch (_) {}
    }

    // TEMP (4105)
    if (cleanData.contains('4105')) {
      try {
        int idx = cleanData.indexOf('4105') + 4;
        if (cleanData.length >= idx + 2) {
          double val = int.parse(cleanData.substring(idx, idx + 2), radix: 16) - 40.0;
          updateTemperature(val);
        }
      } catch (_) {}
    }

    // SPEED (410D)
    if (cleanData.contains('410D')) {
      try {
        int idx = cleanData.indexOf('410D') + 4;
        if (cleanData.length >= idx + 2) {
          setState(() {
            speed = int.parse(cleanData.substring(idx, idx + 2), radix: 16).toDouble();
            currentGear = GearCalculator.calculateGear(rpm.toInt(), speed.toInt());
          });
        }
      } catch (_) {}
    }

    // IAT - Température d'admission (410F) → mise à jour dans ObdService
    if (cleanData.contains('410F')) {
      try {
        int idx = cleanData.indexOf('410F') + 4;
        if (cleanData.length >= idx + 2) {
          int iatRaw = int.parse(cleanData.substring(idx, idx + 2), radix: 16);
          // Formule OBD2 : IAT(°C) = valeur - 40 ; Kelvin = IAT + 273.15
          _obdService.lastIatKelvin = (iatRaw - 40) + 273.15;
        }
      } catch (_) {}
    }

    // MAP -> MAF Virtuel (010B)
    if (cleanData.contains('410B')) {
      try {
        int idx = cleanData.indexOf('410B') + 4;
        if (cleanData.length >= idx + 2) {
          int mapKpa = int.parse(cleanData.substring(idx, idx + 2), radix: 16);

          // SPEED DENSITY FORMULA: MAF(g/s) = (RPM * MAP / 120) * VE * ED * (MM / R) / TempK
          // Mimo Spark 1.0L : VE=0.8, ED=1.0, MM_air=28.97, R=8.314
          // IAT dynamique via PID 010F (sinon 313 K par défaut = 40°C)
          final double tempK = _obdService.lastIatKelvin;
          double mafGs = (rpm * mapKpa / 120.0) * 0.8 * 1.0 * (28.97 / 8.314) / tempK;
          
          double lph = _fuelCalculator.calculateConsumptionLph(mafGs);
          DateTime now = DateTime.now();
          double delta = now.difference(lastMafTime).inMilliseconds / 1000.0;
          lastMafTime = now;
          setState(() {
            _fuelCalculator.updateVirtualFuel(lph, delta);
          });
        }
      } catch (_) {}
    }

    // BATTERY (ATRV) - Réponse type "14.2V"
    if (data.contains('V') && data.contains('.')) {
      try {
        String volStr = data.replaceAll(RegExp(r'[^0-9.]'), '');
        setState(() {
          tension = double.parse(volStr);
        });
      } catch (_) {}
    }
  }

  void updateTemperature(double newTemp) {
    setState(() => temperature = newTemp);
    if (temperature >= 98 && temperature < 103 && !alert98Triggered) {
      _ttsService.speakAlert("Mimo, attention. Température à 98 degrés.");
      alert98Triggered = true;
    } else if (temperature >= 103 && !alert103Triggered) {
      _ttsService.speakAlert("Alerte critique Mimo ! Température à 103 degrés.");
      alert103Triggered = true;
    }
    if (temperature < 95) { alert98Triggered = false; alert103Triggered = false; }
  }

  void _shareLog() async {
    File? logFile = await _obdService.getLogFile();
    if (logFile != null) await Share.shareXFiles([XFile(logFile.path)], text: 'Journal de bord Mimo Spark OBD2 Dashboard');
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
                      child: Transform(
                        alignment: Alignment.center,
                        transform: isHudMode ? (Matrix4.identity()..rotateY(3.14159)) : Matrix4.identity(),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.speed, color: Colors.redAccent, size: 24),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'MIMO SPARK V4.31',
                                style: const TextStyle(color: Colors.greenAccent, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.0, fontStyle: FontStyle.italic),
                                overflow: TextOverflow.ellipsis,
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
              child: Transform(
                alignment: Alignment.center,
                transform: isHudMode ? (Matrix4.identity()..rotateY(3.14159)) : Matrix4.identity(),
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
                          child: Column(
                            children: [
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
    return Container(
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
      height: isHudMode ? 280 : 220, 
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
      height: isHudMode ? 280 : 220, 
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
    _obdSubscription?.cancel();
    _obdService.dispose();
    super.dispose();
  }
}
