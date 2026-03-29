import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../vocal/tts_service.dart';
import '../logic/fuel_calculator.dart';
import '../core/obd_service.dart';
import '../core/obd_service.dart';
import '../core/gear_calculator.dart';
import 'diagnostic.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  // Gauges Data
  double temperature = 0.0;
  double rpm = 0.0;
  double speed = 0.0;
  double tension = 0.0;
  String currentGear = 'N';
  bool isHudMode = false;
  double gX = 0.0;
  double gY = 0.0;
  DateTime lastMafTime = DateTime.now();
  bool rpmAlertTriggered = false;
  
  // Console de Log pour Mimo
  String rawLog = "En attente de données...";
  
  final TtsService _ttsService = TtsService();
  final FuelCalculator _fuelCalculator = FuelCalculator();
  final ObdService _obdService = ObdService();
  
  bool alert98Triggered = false;
  bool alert103Triggered = false;
  StreamSubscription? _accelerometerSubscription;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _connectObd();
    _initSensors();
  }

  void _initSensors() {
    _accelerometerSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      if (mounted) {
        setState(() {
          gX = event.x / 9.81;
          gY = event.y / 9.81;
        });
      }
    });
  }

  void _connectObd() async {
    bool connected = await _obdService.connect();
    if (connected) {
      _obdService.dataStream.listen((data) {
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
          if (rpm >= 3000 && !rpmAlertTriggered) {
             _ttsService.speakAlert("Dépassement 3000 tours !");
             rpmAlertTriggered = true;
          } else if (rpm < 2800) {
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

    // MAP -> MAF Virtuel (010B)
    if (cleanData.contains('410B')) {
      try {
        int idx = cleanData.indexOf('410B') + 4;
        if (cleanData.length >= idx + 2) {
          int mapKpa = int.parse(cleanData.substring(idx, idx + 2), radix: 16);
          
          // SPEED DENSITY FORMULA: MAF(g/s) = (RPM * MAP / 120) * VE * ED * (MM / R) / TempK
          // Hypothèse Mimo Spark : Moteur 1.0L (ED=1.0), Efficacité 80% (VE=0.8), Temp=40°C (313K)
          double mafGs = (rpm * mapKpa / 120.0) * 0.8 * 1.0 * (28.97 / 8.314) / 313.0;
          
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
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.share, color: Colors.blue),
          onPressed: _shareLog,
        ),
        actions: [
          Builder(builder: (context) {
            return Padding(
              padding: const EdgeInsets.all(8.0),
              child: GestureDetector(
                onTap: () => Scaffold.of(context).openEndDrawer(),
                child: const CircleAvatar(backgroundImage: AssetImage('assets/images/IMG_0730.JPG')),
              ),
            );
          })
        ],
      ),
      endDrawer: Drawer(
        child: Container(
          color: Colors.black,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              UserAccountsDrawerHeader(
                accountName: const Text('Mimo'),
                accountEmail: const Text('Directeur Technique'),
                currentAccountPicture: const CircleAvatar(backgroundImage: AssetImage('assets/images/IMG_0730.JPG')),
                decoration: const BoxDecoration(color: Colors.black),
              ),
              ListTile(
                leading: const Icon(Icons.dashboard, color: Colors.white),
                title: const Text('Dashboard', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.warning, color: Colors.white),
                title: const Text('Analyse DTC', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const DiagnosticPage()));
                },
              ),
              ListTile(
                leading: Icon(isHudMode ? Icons.flip_to_front : Icons.flip_to_back, color: Colors.white),
                title: Text(isHudMode ? 'Mode Normal' : 'Mode HUD (Miroir)', style: const TextStyle(color: Colors.white)),
                onTap: () {
                  setState(() => isHudMode = !isHudMode);
                  Navigator.pop(context);
                  _ttsService.speak(isHudMode ? "Mode miroir activé" : "Mode normal");
                },
              ),
            ],
          ),
        ),
      ),
      body: Transform(
        alignment: Alignment.center,
        transform: isHudMode ? (Matrix4.identity()..rotateY(3.14159)) : Matrix4.identity(),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      _buildBatteryStatus(),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _buildFuelGauge()),
                          Expanded(child: _buildTempGauge()),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(child: _buildRpmGauge()),
                          Expanded(child: _buildSpeedGauge()),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildGForceMeter(),
                    ],
                  ),
                ),
              ),
            ),
            // CONSOLE DE LOG
            Container(
              height: 60,
              width: double.infinity,
              color: Colors.black.withOpacity(0.8),
              child: SingleChildScrollView(
                reverse: true,
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Text(rawLog, style: const TextStyle(color: Colors.greenAccent, fontSize: 9, fontFamily: 'monospace')),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.battery_charging_full, color: tension > 13.5 ? Colors.green : Colors.orange),
          const SizedBox(width: 10),
          Text('Batterie : ${tension.toStringAsFixed(1)} V', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildFuelGauge() {
    double fuelVal = _fuelCalculator.currentLiters;
    return SizedBox(height: 160, child: SfRadialGauge(
      title: const GaugeTitle(text: 'Conso MAF (L)', textStyle: TextStyle(color: Colors.orange, fontSize: 11)),
      axes: <RadialAxis>[RadialAxis(
        minimum: 0, maximum: 35,
        ranges: <GaugeRange>[
          GaugeRange(startValue: 0, endValue: 5, color: Colors.red),
          GaugeRange(startValue: 5, endValue: 35, color: Colors.green)
        ],
        pointers: <GaugePointer>[
          NeedlePointer(value: fuelVal, needleColor: Colors.white, enableAnimation: true, animationDuration: 200)
        ],
        annotations: <GaugeAnnotation>[
          GaugeAnnotation(
            widget: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${fuelVal.toStringAsFixed(1)}L', style: const TextStyle(color: Colors.white, fontSize: 12)),
                const Text('virtuel', style: TextStyle(color: Colors.orange, fontSize: 9)),
              ],
            ),
            angle: 90, positionFactor: 0.8
          )
        ],
      )],
    ));
  }


  Widget _buildTempGauge() {
    return SizedBox(height: 160, child: SfRadialGauge(
      title: const GaugeTitle(text: 'Temp (°C)', textStyle: TextStyle(color: Colors.white, fontSize: 12)),
      axes: <RadialAxis>[RadialAxis(minimum: 50, maximum: 130, ranges: <GaugeRange>[GaugeRange(startValue: 50, endValue: 90, color: Colors.blue), GaugeRange(startValue: 90, endValue: 103, color: Colors.orange), GaugeRange(startValue: 103, endValue: 130, color: Colors.red)], pointers: <GaugePointer>[NeedlePointer(value: temperature == 0 ? 50 : temperature, needleColor: Colors.white, enableAnimation: true, animationDuration: 200)], annotations: <GaugeAnnotation>[GaugeAnnotation(widget: Text('${temperature.toStringAsFixed(1)}°', style: const TextStyle(color: Colors.white, fontSize: 12)), angle: 90, positionFactor: 0.8)])],
    ));
  }

  Widget _buildRpmGauge() {
    return SizedBox(height: 160, child: SfRadialGauge(
      title: const GaugeTitle(text: 'RPM', textStyle: TextStyle(color: Colors.white, fontSize: 12)),
      axes: <RadialAxis>[
        RadialAxis(
          minimum: 0, 
          maximum: 8000, 
          ranges: <GaugeRange>[
            GaugeRange(startValue: 0, endValue: 6000, color: Colors.green), 
            GaugeRange(startValue: 6000, endValue: 8000, color: Colors.red)
          ], 
          pointers: <GaugePointer>[
            NeedlePointer(value: rpm, needleColor: Colors.white, enableAnimation: true, animationDuration: 200)
          ], 
          annotations: <GaugeAnnotation>[
            GaugeAnnotation(
              widget: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${rpm.toInt()}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                  Text(currentGear, style: const TextStyle(color: Colors.orange, fontSize: 28, fontWeight: FontWeight.bold)),
                ],
              ), 
              angle: 90, 
              positionFactor: 0.8
            )
          ]
        )
      ],
    ));
  }

  Widget _buildSpeedGauge() {
    return SizedBox(height: 160, child: SfRadialGauge(
      title: const GaugeTitle(text: 'KM/H', textStyle: TextStyle(color: Colors.white, fontSize: 12)),
      axes: <RadialAxis>[RadialAxis(minimum: 0, maximum: 200, ranges: <GaugeRange>[GaugeRange(startValue: 0, endValue: 120, color: Colors.green), GaugeRange(startValue: 120, endValue: 200, color: Colors.red)], pointers: <GaugePointer>[NeedlePointer(value: speed, needleColor: Colors.white, enableAnimation: true, animationDuration: 200)], annotations: <GaugeAnnotation>[GaugeAnnotation(widget: Text('${speed.toInt()}', style: const TextStyle(color: Colors.white, fontSize: 12)), angle: 90, positionFactor: 0.8)])],
    ));
  }

  Widget _buildGForceMeter() {
    return Column(children: [
      const Text('G-FORCE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
      const SizedBox(height: 5),
      Container(width: 100, height: 100, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white24), color: Colors.black),
        child: Stack(children: [Center(child: Container(width: 100, height: 1, color: Colors.white12)), Center(child: Container(width: 1, height: 100, color: Colors.white12)),
          AnimatedPositioned(duration: const Duration(milliseconds: 100), left: 50 - 8 - (gX * 30), top: 50 - 8 + (gY * 30), child: Container(width: 16, height: 16, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle))),
        ]),
      ),
    ]);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _accelerometerSubscription?.cancel();
    _obdService.dispose();
    super.dispose();
  }
}
