import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import '../vocal/tts_service.dart';
import '../logic/fuel_calculator.dart';
import '../core/obd_service.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'diagnostic.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  // Gauges Data (Initialized at 0)
  double temperature = 0.0;
  double rpm = 0.0;
  double speed = 0.0;
  double tension = 0.0;
  bool isHudMode = false;
  double gX = 0.0;
  double gY = 0.0;
  
  // Console de Log pour Mimo (Directeur Technique)
  String rawLog = "En attente de données...";
  
  final TtsService _ttsService = TtsService();
  final FuelCalculator _fuelCalculator = FuelCalculator();
  final ObdService _obdService = ObdService();
  
  bool alert98Triggered = false;
  bool alert103Triggered = false;

  @override
  void initState() {
    super.initState();
    _connectObd();
    _initSensors();
  }

  void _initSensors() {
    accelerometerEvents.listen((AccelerometerEvent event) {
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
            rawLog = data; // Affiche le texte brut en bas pour Mimo
          });
          _parseObdData(data);
        }
      });
    }
  }

  void _parseObdData(String data) {
    // Nettoyage de la trame (ex: 410C1AF8 >)
    String cleanData = data.replaceAll(' ', '').replaceAll('>', '');

    // RPM (410C) - Formule: ((A*256)+B)/4
    if (cleanData.contains('410C')) {
      try {
        int idx = cleanData.indexOf('410C') + 4;
        String hexA = cleanData.substring(idx, idx + 2);
        String hexB = cleanData.substring(idx + 2, idx + 4);
        int a = int.parse(hexA, radix: 16);
        int b = int.parse(hexB, radix: 16);
        setState(() {
          rpm = ((a * 256) + b) / 4.0;
        });
      } catch (_) {}
    }

    // Temp (4105) - Formule: A-40
    if (cleanData.contains('4105')) {
      try {
        int idx = cleanData.indexOf('4105') + 4;
        String hex = cleanData.substring(idx, idx + 2);
        double val = int.parse(hex, radix: 16) - 40.0;
        updateTemperature(val);
      } catch (_) {}
    }

    // Speed (410D) - Formule: A
    if (cleanData.contains('410D')) {
      try {
        int idx = cleanData.indexOf('410D') + 4;
        String hex = cleanData.substring(idx, idx + 2);
        setState(() {
          speed = int.parse(hex, radix: 16).toDouble();
        });
      } catch (_) {}
    }

    // Battery (4142) - Formule: ((A*256)+B)/1000
    if (cleanData.contains('4142')) {
      try {
        int idx = cleanData.indexOf('4142') + 4;
        String hexA = cleanData.substring(idx, idx + 2);
        String hexB = cleanData.substring(idx + 2, idx + 4);
        int a = int.parse(hexA, radix: 16);
        int b = int.parse(hexB, radix: 16);
        setState(() {
          tension = ((a * 256) + b) / 1000.0;
        });
      } catch (_) {}
    }
  }

  void updateTemperature(double newTemp) {
    setState(() => temperature = newTemp);
    if (temperature >= 98 && temperature < 103 && !alert98Triggered) {
      _ttsService.speak("Mimo, attention. Température à 98 degrés.");
      alert98Triggered = true;
    } else if (temperature >= 103 && !alert103Triggered) {
      _ttsService.speak("Alerte critique Mimo ! Température à 103 degrés.");
      alert103Triggered = true;
    }
    if (temperature < 95) {
      alert98Triggered = false;
      alert103Triggered = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MIMO_SPARK'),
        backgroundColor: Colors.black,
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
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              accountName: const Text('Mimo'),
              accountEmail: const Text('Directeur Technique'),
              currentAccountPicture: CircleAvatar(backgroundImage: AssetImage('assets/images/IMG_0730.JPG')),
              decoration: const BoxDecoration(color: Colors.black),
            ),
            ListTile(leading: const Icon(Icons.dashboard), title: const Text('Dashboard'), onTap: () => Navigator.pop(context)),
            ListTile(leading: const Icon(Icons.warning), title: const Text('Analyse DTC'), onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (context) => const DiagnosticPage()));
            }),
            ListTile(
              leading: Icon(isHudMode ? Icons.flip_to_front : Icons.flip_to_back),
              title: Text(isHudMode ? 'Mode Normal' : 'Mode HUD (Miroir)'),
              onTap: () {
                setState(() => isHudMode = !isHudMode);
                Navigator.pop(context);
                _ttsService.speak(isHudMode ? "Mode miroir activé" : "Mode normal");
              },
            ),
          ],
        ),
      ),
      backgroundColor: Colors.black,
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
            // CONSOLE DE LOG (LE TEST DE VERITE)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.blueGrey[900],
              child: Text(
                "CONSOLE: $rawLog",
                style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontFamily: 'monospace'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
    return SizedBox(
      height: 180,
      child: SfRadialGauge(
        title: const GaugeTitle(text: 'Carburant (L)', textStyle: TextStyle(color: Colors.white, fontSize: 14)),
        axes: <RadialAxis>[
          RadialAxis(minimum: 0, maximum: 35,
            ranges: <GaugeRange>[GaugeRange(startValue: 0, endValue: 5, color: Colors.red), GaugeRange(startValue: 5, endValue: 35, color: Colors.green)],
            pointers: <GaugePointer>[NeedlePointer(value: _fuelCalculator.currentLiters, needleColor: Colors.white)],
            annotations: <GaugeAnnotation>[GaugeAnnotation(widget: Text('${_fuelCalculator.currentLiters.toStringAsFixed(1)}L', style: const TextStyle(color: Colors.white, fontSize: 14)), angle: 90, positionFactor: 0.8)],
          )
        ],
      ),
    );
  }

  Widget _buildTempGauge() {
    return SizedBox(
      height: 180,
      child: SfRadialGauge(
        title: const GaugeTitle(text: 'Temp (°C)', textStyle: TextStyle(color: Colors.white, fontSize: 14)),
        axes: <RadialAxis>[
          RadialAxis(minimum: 50, maximum: 130,
            ranges: <GaugeRange>[GaugeRange(startValue: 50, endValue: 90, color: Colors.blue), GaugeRange(startValue: 90, endValue: 103, color: Colors.orange), GaugeRange(startValue: 103, endValue: 130, color: Colors.red)],
            pointers: <GaugePointer>[NeedlePointer(value: temperature == 0 ? 50 : temperature, needleColor: Colors.white)],
            annotations: <GaugeAnnotation>[GaugeAnnotation(widget: Text('${temperature.toStringAsFixed(1)}°', style: const TextStyle(color: Colors.white, fontSize: 14)), angle: 90, positionFactor: 0.8)]
          )
        ],
      ),
    );
  }

  Widget _buildRpmGauge() {
    return SizedBox(
      height: 180,
      child: SfRadialGauge(
        title: const GaugeTitle(text: 'RPM', textStyle: TextStyle(color: Colors.white, fontSize: 14)),
        axes: <RadialAxis>[
          RadialAxis(minimum: 0, maximum: 8000,
            ranges: <GaugeRange>[GaugeRange(startValue: 0, endValue: 6000, color: Colors.green), GaugeRange(startValue: 6000, endValue: 8000, color: Colors.red)],
            pointers: <GaugePointer>[NeedlePointer(value: rpm, needleColor: Colors.white)],
            annotations: <GaugeAnnotation>[GaugeAnnotation(widget: Text('${rpm.toInt()}', style: const TextStyle(color: Colors.white, fontSize: 14)), angle: 90, positionFactor: 0.8)]
          )
        ],
      ),
    );
  }

  Widget _buildSpeedGauge() {
    return SizedBox(
      height: 180,
      child: SfRadialGauge(
        title: const GaugeTitle(text: 'KM/H', textStyle: TextStyle(color: Colors.white, fontSize: 14)),
        axes: <RadialAxis>[
          RadialAxis(minimum: 0, maximum: 200,
            ranges: <GaugeRange>[GaugeRange(startValue: 0, endValue: 120, color: Colors.green), GaugeRange(startValue: 120, endValue: 200, color: Colors.red)],
            pointers: <GaugePointer>[NeedlePointer(value: speed, needleColor: Colors.white)],
            annotations: <GaugeAnnotation>[GaugeAnnotation(widget: Text('${speed.toInt()}', style: const TextStyle(color: Colors.white, fontSize: 14)), angle: 90, positionFactor: 0.8)]
          )
        ],
      ),
    );
  }

  Widget _buildGForceMeter() {
    return Column(
      children: [
        const Text('G-FORCE METER', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Container(width: 120, height: 120, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white24), color: Colors.black),
          child: Stack(children: [Center(child: Container(width: 120, height: 1, color: Colors.white12)), Center(child: Container(width: 1, height: 120, color: Colors.white12)),
            AnimatedPositioned(duration: const Duration(milliseconds: 100), left: 60 - 8 - (gX * 40), top: 60 - 8 + (gY * 40), child: Container(width: 16, height: 16, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle))),
          ]),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _obdService.dispose();
    super.dispose();
  }
}
