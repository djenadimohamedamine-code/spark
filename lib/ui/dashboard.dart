import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import '../vocal/tts_service.dart';
import '../logic/fuel_calculator.dart';
import 'diagnostic.dart';

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  // Gauges Data
  double temperature = 90.0;
  double rpm = 2500.0;
  double speed = 80.0;
  
  final TtsService _ttsService = TtsService();
  final FuelCalculator _fuelCalculator = FuelCalculator();
  
  // Alert flags
  bool alert98Triggered = false;
  bool alert103Triggered = false;

  void updateTemperature(double newTemp) {
    setState(() {
      temperature = newTemp;
    });
    
    if (temperature >= 98 && temperature < 103 && !alert98Triggered) {
      _ttsService.speak("Mimo, attention. La température a atteint 98 degrés.");
      alert98Triggered = true;
    } else if (temperature >= 103 && !alert103Triggered) {
      _ttsService.speak("Mimo, alerte critique ! Température liquide de refroidissement à 103 degrés.");
      alert103Triggered = true;
    }
    
    if (temperature < 95) {
      alert98Triggered = false;
      alert103Triggered = false;
    }
  }

  void _resetFuel() {
    setState(() {
      _fuelCalculator.currentLiters = 35.0;
      _fuelCalculator.lowFuelAlerted = false;
    });
    _ttsService.speak("Plein de carburant effectué. Jauge remise à 35 litres.");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MIMO_SPARK'),
        backgroundColor: Colors.black,
        actions: [
          Builder(
            builder: (context) {
              return Padding(
                padding: const EdgeInsets.all(8.0),
                child: GestureDetector(
                  onTap: () => Scaffold.of(context).openEndDrawer(),
                  child: const CircleAvatar(
                    backgroundImage: AssetImage('assets/images/IMG_0730.JPG'),
                  ),
                ),
              );
            }
          )
        ],
      ),
      endDrawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              accountName: const Text('Mimo'),
              accountEmail: const Text('Directeur Technique'),
              currentAccountPicture: CircleAvatar(
                backgroundImage: AssetImage('assets/images/IMG_0730.JPG'),
              ),
              decoration: const BoxDecoration(color: Colors.black),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard),
              title: const Text('Dashboard'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.warning),
              title: const Text('Analyse DTC'),
              onTap: () {
                Navigator.pop(context);
                // Navigation vers la page diagnostic
                Navigator.push(context, MaterialPageRoute(builder: (context) => const DiagnosticPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Configuration'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
      backgroundColor: Colors.black,
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Ligne 1: Fuel et Temp
              Row(
                children: [
                  Expanded(
                    child: _buildFuelGauge(),
                  ),
                  Expanded(
                    child: _buildTempGauge(),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Ligne 2: RPM et Vitesse
              Row(
                children: [
                  Expanded(
                    child: _buildRpmGauge(),
                  ),
                  Expanded(
                    child: _buildSpeedGauge(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFuelGauge() {
    return GestureDetector(
      onLongPress: _resetFuel, // Bouton caché pour le plein
      child: SizedBox(
        height: 200,
        child: SfRadialGauge(
          title: const GaugeTitle(
            text: 'Carburant (L)',
            textStyle: TextStyle(color: Colors.white, fontSize: 16)
          ),
          axes: <RadialAxis>[
            RadialAxis(
              minimum: 0,
              maximum: 35,
              showLabels: true,
              ranges: <GaugeRange>[
                GaugeRange(startValue: 0, endValue: 5, color: Colors.red),
                GaugeRange(startValue: 5, endValue: 35, color: Colors.green),
              ],
              pointers: <GaugePointer>[
                NeedlePointer(
                  value: _fuelCalculator.currentLiters,
                  needleColor: Colors.white,
                )
              ],
              annotations: <GaugeAnnotation>[
                GaugeAnnotation(
                  widget: Text(
                    '${_fuelCalculator.currentLiters.toStringAsFixed(1)} L',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)
                  ),
                  angle: 90,
                  positionFactor: 0.8,
                )
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildTempGauge() {
    return SizedBox(
      height: 200,
      child: SfRadialGauge(
        title: const GaugeTitle(
          text: 'Temp (°C)',
          textStyle: TextStyle(color: Colors.white, fontSize: 16)
        ),
        axes: <RadialAxis>[
          RadialAxis(
            minimum: 50, maximum: 130,
            ranges: <GaugeRange>[
              GaugeRange(startValue: 50, endValue: 90, color: Colors.blue),
              GaugeRange(startValue: 90, endValue: 103, color: Colors.orange),
              GaugeRange(startValue: 103, endValue: 130, color: Colors.red)
            ],
            pointers: <GaugePointer>[
              NeedlePointer(value: temperature, needleColor: Colors.white)
            ],
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Text('${temperature.toStringAsFixed(1)}°',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                angle: 90,
                positionFactor: 0.8)
            ]
          )
        ],
      ),
    );
  }

  Widget _buildRpmGauge() {
    return SizedBox(
      height: 200,
      child: SfRadialGauge(
        title: const GaugeTitle(
          text: 'RPM',
          textStyle: TextStyle(color: Colors.white, fontSize: 16)
        ),
        axes: <RadialAxis>[
          RadialAxis(
            minimum: 0, maximum: 8000,
            ranges: <GaugeRange>[
              GaugeRange(startValue: 0, endValue: 6000, color: Colors.green),
              GaugeRange(startValue: 6000, endValue: 8000, color: Colors.red),
            ],
            pointers: <GaugePointer>[
              NeedlePointer(value: rpm, needleColor: Colors.white)
            ],
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Text('${rpm.toInt()}',
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                angle: 90,
                positionFactor: 0.8)
            ]
          )
        ],
      ),
    );
  }

  Widget _buildSpeedGauge() {
    return SizedBox(
      height: 200,
      child: SfRadialGauge(
        title: const GaugeTitle(
          text: 'KM/H',
          textStyle: TextStyle(color: Colors.white, fontSize: 16)
        ),
        axes: <RadialAxis>[
          RadialAxis(
            minimum: 0, maximum: 200,
            ranges: <GaugeRange>[
              GaugeRange(startValue: 0, endValue: 120, color: Colors.green),
              GaugeRange(startValue: 120, endValue: 200, color: Colors.red),
            ],
            pointers: <GaugePointer>[
              NeedlePointer(value: speed, needleColor: Colors.white)
            ],
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Text('${speed.toInt()}',
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                angle: 90,
                positionFactor: 0.8)
            ]
          )
        ],
      ),
    );
  }
}
