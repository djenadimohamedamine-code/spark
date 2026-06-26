import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../logic/fuel_calculator.dart';
import '../core/obd_service.dart';
import '../core/gear_calculator.dart';
import 'diagnostic.dart';
import 'map_page.dart';
import 'settings_page.dart';
import 'standalone_clock_page.dart';
import 'engine_data_page.dart';
import '../core/background_service.dart';
import '../vocal/voice_service.dart';


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
  bool showDebugConsole = true; // Affichée par défaut pour le debug

  DateTime lastMafTime = DateTime.now();
  bool rpmAlertTriggered = false;
  
  // Console de Log pour Mimo
  final List<String> _mimoLogs = [];
  String rawLog = "En attente de données...";
  
  void _addLog(String msg) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    setState(() {
      _mimoLogs.insert(0, "[$time] $msg");
      if (_mimoLogs.length > 50) _mimoLogs.removeLast();
    });
    print(msg);
  }
  
  final FuelCalculator _fuelCalculator = FuelCalculator();
  final ObdService _obdService = ObdService();
  final VoiceService _voiceService = VoiceService();
  
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
  Timer? _dataSyncTimer;

  // Ride Tracking (gardé pour compatibilité voix)
  bool isRideActive = false;
  double rideDistance = 0.0;

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
    _fuelCalculator.init().catchError((e) => _addLog("FuelCalc init: $e"));
    _loadFuelCalibration();
    _startDataSync();
    _voiceService.init().catchError((e) => _addLog("Voice init: $e"));
    _addLog("Mimo Spark Démarrée");
    
    // On attend 2 secondes pour activer le bouclier
    // AUCUN service en arrière-plan - connexion directe uniquement
    Timer(const Duration(seconds: 2), () {
      _activateNativeShield();
    });

    // Vérifier s'il y a eu un crash précédent
    _checkLastCrash();
  }

  Future<void> _checkLastCrash() async {
    _addLog("🔍 Vérification Crash précédent...");
    final prefs = await SharedPreferences.getInstance();
    final crash = prefs.getString('last_crash');
    if (crash != null) {
      _addLog("⚠️ Crash détecté !");
      // On affiche l'erreur dans un dialogue
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Dernière Erreur Détectée"),
          content: SingleChildScrollView(child: Text(crash)),
          actions: [
            TextButton(
              onPressed: () {
                prefs.remove('last_crash');
                Navigator.pop(context);
              }, 
              child: const Text("Effacer et Continuer")
            ),
          ],
        ),
      );
    }
  }

  void _handleVoiceCommand(String cmd) {
    if (!mounted) return;

    switch (cmd) {
      case 'MAP':
        _addLog("Affichage de la carte.");
        Navigator.push(
            context, MaterialPageRoute(builder: (context) => const MapPage()));
        break;
      case 'DASHBOARD':
        _addLog("Retour au tableau de bord.");
        break;
      case 'TOGGLE_SATELLITE':
        _addLog("Mode satellite.");
        // Note: La commande satellite est complexe car gérée dans MapPage.
        // On pourrait passer un paramètre si on navigue vers MapPage.
        Navigator.push(
            context, MaterialPageRoute(builder: (context) => const MapPage()));
        break;
    }
  }

  Future<void> _activateNativeShield() async {
    _addLog("🛡️ Armure Kotlin...");
    try {
      const platform = MethodChannel('mimo.spark/shield');
      final result = await platform.invokeMethod('activateShield');
      _addLog("✅ $result");
    } catch (e) {
      _addLog("❌ Crash Shield: $e");
    }
  }

  void _startDataSync() {
    _dataSyncTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      final prefs = await SharedPreferences.getInstance();
      
      if (mounted) {
        setState(() {
          rpm = prefs.getDouble(SparkServiceKeys.rpm) ?? rpm;
          speed = prefs.getDouble(SparkServiceKeys.speed) ?? speed;
          temperature = prefs.getDouble(SparkServiceKeys.temp) ?? temperature;
          tension = prefs.getDouble(SparkServiceKeys.voltage) ?? tension;
          
          // Update Gear
          currentGear = (speed < 5 || rpm < 1000) ? 'N' : GearCalculator.calculateGear(rpm.toInt(), speed.toInt());
          
          // Update Fuel from Service Lph
          double lph = prefs.getDouble(SparkServiceKeys.fuelLph) ?? 0.0;
          if (lph > 0) {
             _fuelCalculator.updateVirtualFuel(lph, 0.5); 
          }

          // Update Ride Distance if active
          if (isRideActive && speed > 0) {
            rideDistance += (speed * (0.5 / 3600.0));
          }
          // Sync raw telegram for Scan DTC / Logs
          String? raw = prefs.getString(SparkServiceKeys.rawTelegram);
          if (raw != null && _obdService.socket == null) {
             _appendLog(raw);
             _parseObdData(raw);
          }
        });
        
        // Clear to avoid duplicate processing (must be outside setState)
        String? raw = prefs.getString(SparkServiceKeys.rawTelegram);
        if (raw != null && _obdService.socket == null) {
             await prefs.remove(SparkServiceKeys.rawTelegram);
        }
      }
    });
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

  bool _wasPaused = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _wasPaused = true;
    }
    if (state == AppLifecycleState.resumed && _wasPaused) {
      _wasPaused = false;
      // Android tue les sockets TCP en arrière-plan même si Flutter croit qu'ils sont vivants.
      // On force un disconnect propre puis reconnexion immédiate.
      _obdService.disconnect();
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          _addLog("🔄 Reconnexion après retour app...");
          _connectObd();
        }
      });
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
                _addLog("Calibrage du carburant enregistré.");
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
    _addLog(line);
  }

  // DRY Alert Helper (Tesla Style)
  void _checkAlert(String label, double value, double threshold, int cooldownSec, String message) {
    final now = DateTime.now();
    final lastTime = _alertCooldowns[label] ?? now.subtract(const Duration(hours: 1));

    if (value >= threshold && now.difference(lastTime).inSeconds > cooldownSec) {
      _addLog("ALERTE : $message");
      _alertCooldowns[label] = now;
    }
  }

  void _parseObdData(String data) {
    if (data.trim().isEmpty || data.contains('SEARCHING') || data.contains('NO DATA') || data.contains('STOPPED')) return;
    
    // Afficher les données brutes dans la petite console du bas (Mimo style)
    setState(() {
      rawLog = data;
    });
    
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
              // Alerte sur valeur BRUTE pour la réactivité (conseil GPT)
              _checkAlert("TEMP_98", rawVal, 98, 15, "Attention Mimo, 98 degrés.");
              _checkAlert("TEMP_103", rawVal, 103, 5, "Critique ! temp 103 !");
              _scheduleUpdate();
            }
            break;

          case '0D': // SPEED (1 octet) - offset calibré -10 km/h pour Spark
            if (i + 2 < parts.length) {
              double rawSpeed = (int.tryParse(parts[i + 2], radix: 16) ?? 0).toDouble();
              double correctedSpeed = (rawSpeed - 10.0).clamp(0.0, 250.0);
              _buffer['speed'] = correctedSpeed;
            }
            break;

          case '0B': // MAP (pour MAF Virtuel)
            if (i + 2 < parts.length) {
              int mapKpa = int.tryParse(parts[i + 2], radix: 16) ?? 0;
              final double tempK = temperature + 273.15; // Utilise la température d'eau comme approximation si IAT indisponible
              double ve = 0.75 + (rpm / 10000.0); // VE dynamique estimée pour Spark 1.0L
              double mafGs = (rpm * mapKpa / 120.0) * ve * (28.97 / 8.314) / tempK;
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
    // Gestion ATRV (Batterie) avec Regex Robuste
    if (RegExp(r'\d+\.\d+V').hasMatch(data)) {
      try {
        String volStr = data.replaceAll(RegExp(r'[^0-9.]'), '');
        double rawVolt = double.tryParse(volStr) ?? 0.0;
        if (rawVolt > 5.0 && rawVolt < 16.0) { // Range de sécurité Spark
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
      body: Stack(
        children: [
          // L'interface principale (Tes jauges)
          OrientationBuilder(
            builder: (context, orientation) {
              if (orientation == Orientation.landscape) {
                return _buildLandscapeDashboard();
              } else {
                return _buildMainDashboard();
              }
            },
          ),
          
          // La Console de Debug (Style iPhone)
          if (showDebugConsole)
            Positioned(
              bottom: 80,
              left: 10,
              right: 10,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  height: 150,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFF3333).withOpacity(0.5)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("CONSOLE MIMO SPARK", style: TextStyle(color: const Color(0xFFFF3333), fontSize: 10, fontWeight: FontWeight.bold)),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.copy, color: Colors.white, size: 16),
                                onPressed: () {
                                  Share.share(_mimoLogs.join("\n"));
                                  _addLog("📋 Logs copiés !");
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.redAccent, size: 20),
                                onPressed: () => setState(() => showDebugConsole = false),
                              ),
                            ],
                          )
                        ],
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _mimoLogs.length,
                          itemBuilder: (context, index) => Text(_mimoLogs[index], style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Assistant Vocal supprimé
        ],
      ),
      endDrawer: Drawer(
        child: Container(
          color: const Color(0xFF0F0F0F),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              UserAccountsDrawerHeader(
                accountName: const Text('Mimo', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                accountEmail: const Text('Directeur Technique', style: TextStyle(color: const Color(0xFFFF3333))),
                currentAccountPicture: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFFF3333), width: 2),
                    boxShadow: [BoxShadow(color: const Color(0xFFFF3333).withOpacity(0.5), blurRadius: 10)],
                  ),
                  child: const CircleAvatar(backgroundImage: AssetImage('assets/images/IMG_0730.JPG')),
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF1A0505), Colors.black], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.dashboard, color: Colors.white),
                title: const Text('Dashboard', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.settings_input_component, color: const Color(0xFFFF3333)),
                title: const Text('Données Moteur', style: TextStyle(color: Color(0xFFFF3333), fontWeight: FontWeight.bold)),
                subtitle: const Text('Papillon · MAF · Fuel Trim · O2 · MAP…', style: TextStyle(color: Colors.white38, fontSize: 10)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => EngineDataPage(obdService: _obdService)));
                },
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
                leading: const Icon(Icons.map, color: Colors.lightBlueAccent),
                title: const Text('Navigation GPS', style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text('Vue satellite + trafic temps réel', style: TextStyle(color: Colors.white38, fontSize: 10)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const MapPage()));
                },
              ),
              ListTile(
                leading: Icon(isHudMode ? Icons.flip_to_front : Icons.flip_to_back, color: const Color(0xFFFF3333)),
                title: Text(isHudMode ? 'Mode Normal' : 'Mode HUD (Miroir)', style: const TextStyle(color: const Color(0xFFFF3333))),
                onTap: () {
                  setState(() => isHudMode = !isHudMode);
                  Navigator.pop(context);
                  _addLog(isHudMode ? "Mode miroir activé" : "Mode normal");
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
              ListTile(
                leading: const Icon(Icons.access_time, color: Colors.purpleAccent),
                title: const Text('Horloge (Plein Écran)', style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text('Afficher l\'horloge seule pour le client', style: TextStyle(color: Colors.white38, fontSize: 10)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const StandaloneClockPage()));
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings, color: Colors.grey),
                title: const Text('Configuration', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsPage()));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainDashboard() {
    return Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [Color(0xFF1A0505), Color(0xFF000000)],
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
                    const SizedBox(width: 40), // Espace pour équilibrer le menu à droite
                    Expanded(
                      child: _buildHudTransform(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
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
                        icon: const Icon(Icons.menu, color: const Color(0xFFFF3333)),
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
                                _buildClock(),
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
                    // CONSOLE DE LOG + BATTERY
                    Container(
                      height: 50,
                      width: double.infinity,
                      color: Colors.black.withOpacity(0.8),
                      child: Row(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              reverse: true,
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Text(rawLog, style: const TextStyle(color: Colors.greenAccent, fontSize: 8, fontFamily: 'monospace')),
                              ),
                            ),
                          ),
                          _buildBatteryMini(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
    );
  }

  Widget _buildLandscapeDashboard() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.5,
          colors: [Color(0xFF150202), Colors.black],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // Top Row: Temp (L) | Clock (C) | Distance (R)
                Expanded(
                  flex: 4,
                  child: Row(
                    children: [
                      Expanded(child: _buildTempGauge(isLandscape: true)),
                      Expanded(
                        flex: 2,
                        child: _buildClock(isLandscape: true),
                      ),
                      Expanded(child: _buildRpmGauge(isLandscape: true)), // Remplacé Distance par RPM
                    ],
                  ),
                ),
                // Bottom Row: Fuel (L) | RPM/Bat (C) | Speed (R)
                Expanded(
                  flex: 3,
                  child: Row(
                    children: [
                      Expanded(child: _buildFuelGauge(isLandscape: true)),
                      Expanded(
                        flex: 2,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _buildBatteryMini(isLandscape: true),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      Expanded(child: _buildSpeedGauge(isLandscape: true)),
                    ],
                  ),
                ),
              ],
            ),
            // Floating Menu Button for Landscape
            Positioned(
              top: 10,
              right: 10,
              child: Builder(builder: (context) {
                return IconButton(
                  icon: const Icon(Icons.menu, color: const Color(0xFFFF3333), size: 30),
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClock({bool isLandscape = false}) {
    // On force l'orientation landscape via MediaQuery pour plus de fiabilité
    final bool landscape = MediaQuery.of(context).orientation == Orientation.landscape;
    
    return StreamBuilder(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, snapshot) {
        final timeStr = DateFormat('HH:mm').format(DateTime.now());
        
        if (landscape) {
          final parts = timeStr.split(':');
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(parts[0], style: const TextStyle(color: Colors.white, fontSize: 85, fontWeight: FontWeight.bold, letterSpacing: -2, shadows: [Shadow(color: const Color(0xFFFF3333), blurRadius: 10)])),
                  Text(':', style: TextStyle(color: const Color(0xFFFF3333).withOpacity(0.5), fontSize: 65, fontWeight: FontWeight.w200)),
                  Text(parts[1], style: const TextStyle(color: Colors.white, fontSize: 85, fontWeight: FontWeight.w300, letterSpacing: -2)),
                  const SizedBox(width: 8),
                  Text(DateFormat('ss').format(DateTime.now()), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w400)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(width: 60, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, const Color(0xFFFF3333).withOpacity(0.3)]))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      DateFormat('EEEE d MMMM', 'fr_FR').format(DateTime.now()).toUpperCase(),
                      style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2),
                    ),
                  ),
                  Container(width: 60, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [const Color(0xFFFF3333).withOpacity(0.3), Colors.transparent]))),
                ],
              ),
            ],
          );
        }
        
        final parts = timeStr.split(':');
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(parts[0], style: const TextStyle(color: Colors.white, fontSize: 85, fontWeight: FontWeight.bold, letterSpacing: -2, shadows: [Shadow(color: const Color(0xFFFF3333), blurRadius: 10)])),
                Text(':', style: TextStyle(color: const Color(0xFFFF3333).withOpacity(0.5), fontSize: 65, fontWeight: FontWeight.w200)),
                Text(parts[1], style: const TextStyle(color: Colors.white, fontSize: 85, fontWeight: FontWeight.w300, letterSpacing: -2)),
                const SizedBox(width: 8),
                Text(DateFormat('ss').format(DateTime.now()), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w400)),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(width: 40, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, const Color(0xFFFF3333).withOpacity(0.3)]))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    DateFormat('EEEE d MMMM', 'fr_FR').format(DateTime.now()).toUpperCase(),
                    style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 2),
                  ),
                ),
                Container(width: 40, height: 1, decoration: BoxDecoration(gradient: LinearGradient(colors: [const Color(0xFFFF3333).withOpacity(0.3), Colors.transparent]))),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildBatteryMini({bool isLandscape = false}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isLandscape ? 20 : 12, vertical: isLandscape ? 4 : 0),
      decoration: isLandscape ? BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tension > 13.5 ? Icons.battery_charging_full : Icons.battery_std, 
               color: tension > 13.5 ? Colors.greenAccent : (tension < 12.0 ? Colors.redAccent : Colors.orangeAccent), 
               size: isLandscape ? 18 : 14),
          const SizedBox(width: 6),
          Text('${tension.toStringAsFixed(1)}V', 
               style: TextStyle(color: Colors.white, fontSize: isLandscape ? 16 : 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDistanceGauge({bool isLandscape = false}) {
    final kmStr = rideDistance.toStringAsFixed(1);
    if (isLandscape) {
      return Container(
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFF121212).withOpacity(0.7),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 15, offset: const Offset(0, 5))
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.straighten, color: Colors.purpleAccent, size: 18),
            const SizedBox(height: 6),
            Text(kmStr, style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.bold)),
            const Text("KM", style: TextStyle(color: Colors.purpleAccent, fontSize: 10, letterSpacing: 3, fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }
    return _buildGlassCard(
      height: 180,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text("KM PARCOURUS", style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 10),
          Text(kmStr, style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.bold)),
        ],
      )
    );
  }

  void _toggleRide() {
    setState(() => isRideActive = !isRideActive);
    if (isRideActive) {
      rideDistance = 0.0;
      _addLog("Course démarrée. Bonne route Mimo.");
    } else {
      _addLog("Course terminée. Distance: ${rideDistance.toStringAsFixed(1)} km.");
    }
  }

  // --- GAUGE DESIGN METRICS ---
  
  Widget _buildGlassCard({required Widget child, required double height}) {
    return Container(
      height: height,
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A).withOpacity(0.85),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFFF3333).withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.8), blurRadius: 15, offset: const Offset(0, 10)),
          BoxShadow(color: const Color(0xFFFF3333).withOpacity(0.08), blurRadius: 20, spreadRadius: -2),
        ],
      ),
      child: child,
    );
  }

  Widget _buildFuelGauge({bool isLandscape = false}) {
    double fuelVal = _fuelCalculator.currentLiters;
    int kmRestants = (fuelVal / 7.5 * 100).toInt();
    
    return _buildGlassCard(
      height: isLandscape ? 160 : (isHudMode ? 240 : 180), 
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
                    Icon(Icons.local_gas_station, color: Colors.white70, size: isLandscape ? 16 : 20),
                    const SizedBox(height: 4),
                    Text('$kmRestants KM', style: TextStyle(color: kmRestants <= 70 ? Colors.redAccent : (kmRestants <= 120 ? Colors.orangeAccent : Colors.greenAccent), fontSize: isLandscape ? 20 : 26, fontWeight: FontWeight.w900)),
                    if (!isLandscape) ...[
                      const SizedBox(height: 4),
                      Text('${fuelVal.toStringAsFixed(1)} L', style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                    ]
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

  Widget _buildTempGauge({bool isLandscape = false}) {
    return _buildGlassCard(
      height: isLandscape ? 160 : (isHudMode ? 240 : 180), 
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
                    Icon(Icons.thermostat, color: Colors.white70, size: isLandscape ? 16 : 20),
                    const SizedBox(height: 4),
                    Text('${temperature.toStringAsFixed(0)}°C', style: TextStyle(color: Colors.white, fontSize: isLandscape ? 18 : 22, fontWeight: FontWeight.bold)),
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

  Widget _buildRpmGauge({bool isLandscape = false}) {
    return _buildGlassCard(
      height: isLandscape ? 180 : (isHudMode ? 320 : 220), 
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
              GaugeRange(startValue: 0, endValue: 6000, color: const Color(0xFFFF3333).withOpacity(0.3), startWidth: 10, endWidth: 10), 
              GaugeRange(startValue: 6000, endValue: 8000, color: Colors.redAccent.withOpacity(0.6), startWidth: 10, endWidth: 15)
            ], 
            pointers: <GaugePointer>[
              NeedlePointer(
                value: rpm, needleColor: const Color(0xFFFF3333), tailStyle: const TailStyle(width: 8, color: const Color(0xFFFF3333)),
                needleStartWidth: 1, needleEndWidth: 5, knobStyle: const KnobStyle(color: Colors.white, knobRadius: 0.08),
                enableAnimation: true, animationDuration: 300, animationType: AnimationType.ease
              ),
              // Indicateur discret de rétrogradage
              MarkerPointer(
                value: 1500,
                markerType: MarkerType.rectangle,
                markerHeight: 15,
                markerWidth: 3,
                color: const Color(0xFFFF3333).withOpacity(0.8),
                markerOffset: -15,
              ),
              // Indicateur discret de passage de vitesse supérieure (ÉCO / VTC)
              MarkerPointer(
                value: 2500,
                markerType: MarkerType.rectangle,
                markerHeight: 15,
                markerWidth: 3,
                color: const Color(0xFFFF3333).withOpacity(0.8),
                markerOffset: -15,
              )
            ], 
            annotations: <GaugeAnnotation>[
              GaugeAnnotation(
                widget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(currentGear, style: TextStyle(color: Colors.white, fontSize: isLandscape ? 24 : 36, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                    const Text('GEAR', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 2)),
                    const SizedBox(height: 2),
                    Text('${rpm.toInt()}', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    const Text('RPM', style: TextStyle(color: Colors.white54, fontSize: 9, letterSpacing: 1)),
                  ],
                ), 
                angle: 90, positionFactor: isLandscape ? 0.6 : 0.7
              )
            ]
          )
        ],
      )
    );
  }

  Widget _buildSpeedGauge({bool isLandscape = false}) {
    return _buildGlassCard(
      height: isLandscape ? 180 : (isHudMode ? 320 : 220), 
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
                    Text('${speed.toInt()}', style: TextStyle(color: Colors.white, fontSize: isLandscape ? 36 : 46, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
                    const Text('KM/H', style: TextStyle(color: Colors.purpleAccent, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  ],
                ), 
                angle: 90, positionFactor: isLandscape ? 0.8 : 0.7
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
