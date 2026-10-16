import 'dart:async';
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
import 'performance_page.dart';
import 'fuel_gauge_widget.dart';
import 'add_fuel_dialog.dart';
import '../vocal/voice_service.dart';
import '../vocal/tts_service.dart';
import '../core/gps_debug_logger.dart';
import 'gps_debug_log_page.dart';


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
  final TtsService _ttsService = TtsService();
  
  bool alert98Triggered = false;
  bool alert103Triggered = false;

  // Optimisations PRO+++ (Tesla Level)
  Timer? _uiTimer;
  final Map<String, dynamic> _buffer = {};
  double _smoothVoltage = 0.0;
  double _smoothLph = 0.0;
  double _smoothTemp = 0.0;
  double _iat = 25.0; // Température d'admission d'air
  
  // Cooldowns d'alertes par label (Pro Style)
  final Map<String, DateTime> _alertCooldowns = {};

  StreamSubscription<String>? _obdSubscription;
  Timer? _dataSyncTimer;
  Timer? _startupTimer;
  DateTime? _lastSpeedTime;
  DateTime? _lastRpmTime;

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
    _fuelCalculator.init().then((_) {
      if (mounted) {
        setState(() {});
        if (!_fuelCalculator.isCalibrated) {
          _addLog("⚠️ Jauge non calibrée : Touchez la carte carburant pour caler l'aiguille.");
        }
      }
    }).catchError((Object error) {
      if (mounted) _addLog('FuelCalc init: $error');
    });
    _startDataSync();
    _voiceService.init().catchError((Object e) {
      _addLog("Voice init: $e");
      return false;
    });
    _addLog("MIMO_OBD Démarré");
    
    // On attend 2 secondes pour activer le bouclier puis connecter l'OBD
    _startupTimer = Timer(const Duration(seconds: 2), () async {
      await _activateNativeShield();
      if (mounted) _connectObd();
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
    _dataSyncTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) return;
      final now = DateTime.now();
      final speedAge = _lastSpeedTime == null ? null : now.difference(_lastSpeedTime!);
      final rpmAge = _lastRpmTime == null ? null : now.difference(_lastRpmTime!);
      final speedFresh = speedAge != null && speedAge >= Duration.zero &&
          speedAge <= const Duration(seconds: 2);
      final rpmFresh = rpmAge != null && rpmAge >= Duration.zero &&
          rpmAge <= const Duration(seconds: 6);
      final validSpeed = speedFresh ? speed : 0.0;
      setState(() {
        currentGear = (!rpmFresh || validSpeed < 5 || rpm < 1000)
            ? 'N'
            : GearCalculator.calculateGear(rpm.toInt(), validSpeed.toInt());
        if (isRideActive && validSpeed > 0) {
          rideDistance += validSpeed * (0.5 / 3600.0);
        }
      });
    });
  }

  bool _wasPaused = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _wasPaused = true;
      _lastSpeedTime = null;
      _lastRpmTime = null;
      _smoothLph = 0.0;
      lastMafTime = DateTime.now();
      unawaited(_fuelCalculator.save().catchError((Object error, StackTrace stack) {
        debugPrint('Sauvegarde carburant cycle de vie: $error');
      }));
    }
    if (state == AppLifecycleState.resumed && _wasPaused) {
      _wasPaused = false;
      // Sur iOS, la socket TCP peut survivre un court passage en arrière-plan
      // (ex: 10-15 secondes dans Messenger). On vérifie la fraîcheur des données
      // avant de décider de déconnecter, pour éviter de casser une connexion encore valide.
      //
      // checkConnectionHealth() lit uniquement _lastDataReceived — aucune écriture réseau,
      // aucune commande ELM327 concurrente avec le polling existant.
      //
      // Seuil : 8 secondes. Si la dernière donnée OBD2 date de moins de 8s,
      // la socket est considérée comme vivante et on ne fait rien.
      // Si elle date de plus de 8s (ou si socket == null), on reconnecte.
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        final isHealthy = _obdService.checkConnectionHealth(maxAgeSeconds: 8);
        if (isHealthy) {
          _addLog('🟢 OBD2 : connexion encore active — pas de reconnexion nécessaire.');
        } else {
          _addLog('🔄 OBD2 : connexion absente ou données trop anciennes (>8s) — reconnexion...');
          _obdService.disconnect();
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) _connectObd();
          });
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
              // Jauge analogique photo avec aiguille déplaçable
              FuelGaugeWidget(
                fuelLiters: tempFuel,
                isDraggable: true,
                size: 240,
                onValueChanged: (val) {
                  setLocal(() => tempFuel = val);
                },
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
                try {
                  await _fuelCalculator.calibrate(tempFuel);
                  if (!mounted) return;
                  setState(() {});
                  _addLog('Calibrage du carburant enregistré.');
                } catch (error) {
                  if (mounted) _addLog('Calibrage non enregistré: $error');
                }
              },
              child: const Text('CALER AIGUILLE', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddFuelDialog() {
    AddFuelDialog.show(
      context,
      fuelCalculator: _fuelCalculator,
      onFuelUpdated: () {
        if (mounted) setState(() {});
        _addLog('Niveau carburant mis à jour : ${_fuelCalculator.currentLiters.toStringAsFixed(1)} L');
      },
    );
  }

  // Garde anti-concurrence : évite d'appeler connect() une deuxième fois
  // si un premier appel est déjà en cours (ex: retour de Messenger pendant
  // une reconnexion watchdog).
  bool _isConnecting = false;

  void _connectObd() async {
    if (_isConnecting) {
      _addLog('⚠️ OBD2 : connexion déjà en cours — ignoré.');
      return;
    }
    _isConnecting = true;
    try {
      bool connected = await _obdService.connect();
      if (connected && mounted) {
        _obdSubscription?.cancel();
        _obdSubscription = _obdService.dataStream.listen((data) {
          if (mounted) {
            _appendLog(data);
            _parseObdData(data);
          }
        });
        _addLog('✅ OBD2 : connecté.');
      } else if (mounted) {
        _addLog('❌ OBD2 : échec de connexion — nouvelle tentative dans 5s.');
      }
    } finally {
      _isConnecting = false;
    }
  }

  void _appendLog(String line) {
    _addLog(line);
  }

  // DRY Alert Helper (Tesla Style) avec Synthèse Vocale
  void _checkAlert(String label, double value, double threshold, int cooldownSec, String message, {bool lessThan = false}) {
    final now = DateTime.now();
    final lastTime = _alertCooldowns[label] ?? now.subtract(const Duration(hours: 1));

    bool triggered = lessThan ? (value <= threshold) : (value >= threshold);

    if (triggered && now.difference(lastTime).inSeconds > cooldownSec) {
      _addLog("ALERTE : $message");
      _alertCooldowns[label] = now;
      _ttsService.speak(message, key: label, cooldownSeconds: cooldownSec);
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
              final a = int.tryParse(parts[i + 2], radix: 16);
              final b = int.tryParse(parts[i + 3], radix: 16);
              if (a != null && b != null && a >= 0 && b >= 0 && a <= 255 && b <= 255) {
                final double newRpm = ((a * 256) + b) / 4.0;
                _lastRpmTime = DateTime.now();
                _buffer['rpm'] = newRpm;
                _buffer['gear'] = (speed < 5 || newRpm < 1000) ? 'N' : GearCalculator.calculateGear(newRpm.toInt(), speed.toInt());
                _checkAlert("RPM_HIGH", newRpm, 3500, 7, "Mimo, réduit les gaz, 3500 tours !");
              }
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

          case '0D': // SPEED (1 octet) - valeur brute OBD2
            if (i + 2 < parts.length) {
              final parsedSpeed = int.tryParse(parts[i + 2], radix: 16);
              if (parsedSpeed != null && parsedSpeed >= 0 && parsedSpeed <= 255) {
                _buffer['speed'] = parsedSpeed.toDouble();
                _lastSpeedTime = DateTime.now();
              }
            }
            break;

          case '0F': // IAT (Température d'admission d'air)
            if (i + 2 < parts.length) {
              final parsedIat = int.tryParse(parts[i + 2], radix: 16);
              if (parsedIat != null && parsedIat >= 0 && parsedIat <= 255) {
                _iat = parsedIat.toDouble() - 40.0;
              }
            }
            break;

          case '0B': // MAP (pour MAF Virtuel)
            if (i + 2 < parts.length) {
              final parsedMap = int.tryParse(parts[i + 2], radix: 16);
              if (parsedMap == null || parsedMap <= 0 || parsedMap > 255) break;
              final now = DateTime.now();
              final delta = now.difference(lastMafTime).inMilliseconds / 1000.0;
              lastMafTime = now;
              final rpmAge = _lastRpmTime == null ? null : now.difference(_lastRpmTime!);
              final rpmFresh = rpmAge != null && rpmAge >= Duration.zero &&
                  rpmAge <= const Duration(seconds: 6);
              final double currentRpm = _buffer['rpm'] ?? rpm;
              if (!rpmFresh || currentRpm <= 0) {
                _smoothLph = 0.0;
                break;
              }
              final double tempK = _iat + 273.15;
              final double ve = 0.75 + (currentRpm / 10000.0);
              final double mafGs = (currentRpm * parsedMap / 120.0) * ve *
                  (28.97 / 8.314) / tempK * 0.8;
              final double rawLph = _fuelCalculator.calculateConsumptionLph(mafGs);
              if (delta <= 0 || delta > 3.0) {
                _smoothLph = rawLph;
              } else {
                _smoothLph = (_smoothLph == 0)
                    ? rawLph
                    : (_smoothLph * 0.9) + (rawLph * 0.1);
                _fuelCalculator.updateVirtualFuel(_smoothLph, delta);
              }
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
          
          final double currentRpm = _buffer['rpm'] ?? rpm;
          if (currentRpm > 500) {
            _checkAlert("BATT_LOW", rawVolt, 11.8, 180, "Attention Mimo, batterie faible !", lessThan: true);
          }
        }
      } catch (_) {}
    }

    _scheduleUpdate();
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
              // ── Entrée diagnostic GPS (accessible pour activer/consulter les logs) ──
              ListTile(
                leading: Icon(
                  Icons.bug_report,
                  color: GpsDebugLogger.enabled ? Colors.redAccent : Colors.amberAccent,
                ),
                title: const Text(
                  'Log GPS — Diagnostic',
                  style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  GpsDebugLogger.enabled ? '● Enregistrement en cours' : 'Journalisation temporaire (en pause)',
                  style: TextStyle(
                    color: GpsDebugLogger.enabled ? Colors.redAccent : Colors.white38,
                    fontSize: 10,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const GpsDebugLogPage(),
                  ));
                },
              ),
              // ── Fin entrée diagnostic GPS ──────────────────────────────────
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
                leading: const Icon(Icons.local_gas_station, color: Colors.greenAccent),
                title: const Text('⛽ Faire le plein', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text('Ajouter des litres d\'essence (station-service)', style: TextStyle(color: Colors.white70, fontSize: 11)),
                onTap: () {
                  Navigator.pop(context);
                  _showAddFuelDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.tune, color: Colors.orangeAccent),
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
                leading: const Icon(Icons.timer, color: Colors.orangeAccent),
                title: const Text('Chrono Performance', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text('Mesurer le 0-50 km/h et 0-100 km/h', style: TextStyle(color: Colors.white38, fontSize: 10)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const PerformancePage()));
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
                      child: LayoutBuilder(
                        builder: (context, viewport) => SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: viewport.maxHeight),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
                              child: Column(
                                // Occupe la hauteur libérée par l'horloge ; reste scrollable
                                // quand le texte/accessibilité agrandit les instruments.
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (!isHudMode) ...[
                                    _buildCompactTempWidget(),
                                    const SizedBox(height: 10),
                                    _buildFuelHeroCard(),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(child: _buildRpmGauge()),
                                        const SizedBox(width: 4),
                                        Expanded(child: _buildSpeedGauge()),
                                      ],
                                    ),
                                  ] else ...[
                                    // Mode HUD : Uniquement Vitesse (En haut) et RPM (En bas)
                                    _buildSpeedGauge(),
                                    const SizedBox(height: 20),
                                    _buildRpmGauge(),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // CONSOLE DE LOG + BATTERY + CONSUMPTION
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
                          _buildFuelConsumptionMini(),
                          const SizedBox(width: 8),
                          _buildBatteryMini(),
                          const SizedBox(width: 8),
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Espace REEL après la SafeArea, y compris les encoches latérales iPhone.
            const headerHeight = 42.0;
            final cockpitHeight = (constraints.maxHeight - headerHeight)
                .clamp(200.0, 420.0).toDouble();
            final speedHeight = (cockpitHeight - 68.0)
                .clamp(140.0, 352.0).toDouble();
            final rpmHeight = (cockpitHeight - 20.0)
                .clamp(180.0, 400.0).toDouble();

            return Column(
              children: [
                SizedBox(
                  height: headerHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(
                        Icons.circle,
                        color: _obdService.socket != null
                            ? Colors.greenAccent
                            : Colors.redAccent,
                        size: 9,
                      ),
                      const SizedBox(width: 8),
                      const Text('MIMO SPARK',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2)),
                      const Spacer(),
                      Builder(builder: (context) {
                        return IconButton(
                          icon: const Icon(Icons.menu,
                              color: Color(0xFFFF3333), size: 26),
                          onPressed: () => Scaffold.of(context).openEndDrawer(),
                        );
                      }),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 28,
                        child: _buildLandscapeFuelPanel(cockpitHeight),
                      ),
                      Expanded(
                        flex: 39,
                        child: Column(
                          children: [
                            Expanded(
                              child: Center(
                                key: const Key('landscape_speed_pole'),
                                child: _buildSpeedGauge(
                                  isLandscape: true,
                                  heightOverride: speedHeight,
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 50,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.thermostat,
                                        size: 15,
                                        color: temperature > 108
                                            ? Colors.redAccent
                                            : Colors.greenAccent),
                                    const SizedBox(width: 3),
                                    Text(
                                      temperature > 0
                                          ? '${temperature.toStringAsFixed(0)}°C'
                                          : '--°C',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(width: 6),
                                    _buildFuelConsumptionMini(),
                                    _buildBatteryMini(),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 33,
                        child: Center(
                          key: const Key('landscape_rpm_pole'),
                          child: _buildRpmGauge(
                            isLandscape: true,
                            heightOverride: rpmHeight,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // Pôle gauche du cockpit paysage : indépendant du panneau portrait.
  // Conserve le widget photographique et la logique de calibrage existants.
  Widget _buildLandscapeFuelPanel(double availableHeight) {
    final gaugeSize = (availableHeight * 0.39)
        .clamp(92.0, 130.0).toDouble();
    final calibrated = _fuelCalculator.isCalibrated;
    final fuelLiters = _fuelCalculator.currentLiters;

    return Container(
      key: const Key('landscape_fuel_pole'),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A).withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: const Color(0xFFFF3333).withOpacity(0.35),
            width: 1.5),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('CARBURANT',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 3),
            InkWell(
              key: const Key('landscape_fuel_calibration'),
              onTap: _showFuelCalibrationDialog,
              child: FuelGaugeWidget(
                fuelLiters: fuelLiters,
                size: gaugeSize,
                showGlow: true,
              ),
            ),
            Text(
              calibrated ? '${fuelLiters.toStringAsFixed(1)} L / 35 L' : '-- L / 35 L',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold),
            ),
            Text(
              calibrated
                  ? '${_fuelCalculator.kmRestants} KM ESTIMÉS'
                  : 'À CALIBRER',
              style: TextStyle(
                  color: calibrated ? Colors.greenAccent : Colors.orangeAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 30,
              child: TextButton.icon(
                key: const Key('landscape_add_fuel_button'),
                onPressed: _showAddFuelDialog,
                icon: const Icon(Icons.add, color: Colors.greenAccent, size: 14),
                label: const Text('+ Plein',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  backgroundColor: Colors.greenAccent.withOpacity(0.12),
                ),
              ),
            ),
          ],
        ),
      ),
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

  Widget _buildFuelConsumptionMini({bool isLandscape = false}) {
    // Calcul de la consommation aux 100km si le véhicule roule, sinon en L/h
    final double lph = _smoothLph;
    final bool isStopped = speed < 5.0;
    final String valueStr = isStopped 
        ? '${lph.toStringAsFixed(1)} L/h' 
        : '${(lph / speed * 100).toStringAsFixed(1)} L/100';

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
          Icon(Icons.local_gas_station, 
               color: isStopped ? Colors.orangeAccent : Colors.greenAccent, 
               size: isLandscape ? 18 : 14),
          const SizedBox(width: 6),
          Text(valueStr, 
               style: TextStyle(color: Colors.white, fontSize: isLandscape ? 16 : 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void toggleRide() {
    setState(() => isRideActive = !isRideActive);
    if (isRideActive) {
      rideDistance = 0.0;
      _addLog("Course démarrée. Bonne route Mimo.");
    } else {
      _addLog("Course terminée. Distance: ${rideDistance.toStringAsFixed(1)} km.");
    }
  }

  // --- GAUGE DESIGN METRICS ---
  
  Widget _buildGlassCard({
    required Widget child,
    required double height,
    EdgeInsetsGeometry margin = const EdgeInsets.all(8),
  }) {
    return Container(
      height: height,
      margin: margin,
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

  Widget _buildCompactTempWidget() {
    final bool hasValidTemp = temperature > 0.0;
    final double tempVal = temperature;

    // Seuils thermiques réalistes moteur essence Daewoo F8CV 0.8L :
    // - Thermostat mécanique s'ouvre vers 82-88°C
    // - Ventilateur déclenche en petite vitesse à ~98-102°C
    // - Bleu : phase de chauffe (< 75°C)
    // - Vert : température nominale optimale (75°C à 102°C) -> 96°C reste nominal
    // - Orange : surveillance / moteur très chaud (103°C à 108°C)
    // - Rouge : alerte critique de surchauffe (> 108°C)
    final Color statusColor;
    final String statusLabel;
    final String tempText;

    if (!hasValidTemp) {
      statusColor = Colors.white38;
      statusLabel = "EN ATTENTE";
      tempText = "—";
    } else if (tempVal < 75.0) {
      statusColor = Colors.lightBlueAccent;
      statusLabel = "FROID";
      tempText = tempVal.toStringAsFixed(0);
    } else if (tempVal <= 102.0) {
      statusColor = Colors.greenAccent;
      statusLabel = "OPTIMAL";
      tempText = tempVal.toStringAsFixed(0);
    } else if (tempVal <= 108.0) {
      statusColor = Colors.orangeAccent;
      statusLabel = "CHAUD";
      tempText = tempVal.toStringAsFixed(0);
    } else {
      statusColor = Colors.redAccent;
      statusLabel = "ALERTE";
      tempText = tempVal.toStringAsFixed(0);
    }

    // Ratio sur l'échelle 50°C à 130°C (amplitude 80°C)
    final double tempRatio = hasValidTemp 
        ? ((tempVal - 50.0) / 80.0).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2.0),
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 9.0),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F).withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF3333).withOpacity(0.25), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor.withOpacity(0.15),
              border: Border.all(color: statusColor.withOpacity(0.4), width: 1.2),
            ),
            child: Icon(Icons.thermostat, color: statusColor, size: 15),
          ),
          const SizedBox(width: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                tempText,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                " °C",
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: statusColor.withOpacity(0.35), width: 0.8),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                color: statusColor,
                fontSize: 8.0,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const Spacer(),
          // Mini indicateur visuel (bargraph 4 couleurs : 31% Bleu, 34% Vert, 8% Orange, 27% Rouge)
          SizedBox(
            width: 75,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 5,
                    color: Colors.white10,
                    child: Stack(
                      children: [
                        Row(
                          children: [
                            Expanded(flex: 31, child: Container(color: Colors.lightBlueAccent.withOpacity(0.25))),
                            Expanded(flex: 34, child: Container(color: Colors.greenAccent.withOpacity(0.25))),
                            Expanded(flex: 8, child: Container(color: Colors.orangeAccent.withOpacity(0.25))),
                            Expanded(flex: 27, child: Container(color: Colors.redAccent.withOpacity(0.25))),
                          ],
                        ),
                        if (hasValidTemp)
                          FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: tempRatio,
                            child: Container(
                              decoration: BoxDecoration(
                                color: statusColor,
                                boxShadow: [
                                  BoxShadow(
                                    color: statusColor.withOpacity(0.8),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("50", style: TextStyle(color: Colors.white30, fontSize: 8)),
                    Text("90", style: TextStyle(color: Colors.greenAccent, fontSize: 8, fontWeight: FontWeight.bold)),
                    Text("130", style: TextStyle(color: Colors.white30, fontSize: 8)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFuelHeroCard() {
    final double fuelVal = _fuelCalculator.currentLiters;
    // 156 pt sur iPhone 11 Pro (375 pt), réduit sur les écrans étroits.
    final double gaugeSize = (MediaQuery.of(context).size.width - 219.0).clamp(132.0, 156.0).toDouble();
    final int kmRestants = _fuelCalculator.kmRestants;
    final double fuelPercent = (fuelVal / 35.0).clamp(0.0, 1.0);

    final Color statusColor = kmRestants <= 70
        ? Colors.redAccent
        : (kmRestants <= 120 ? Colors.orangeAccent : Colors.greenAccent);

    // Consommation instantanée distincte
    final double lph = _smoothLph;
    final bool isStopped = speed < 5.0;
    final String instantConsoStr = isStopped 
        ? '${lph.toStringAsFixed(1)} L/h' 
        : '${(lph / (speed > 0 ? speed : 1.0) * 100).toStringAsFixed(1)} L/100';

    return Container(
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A).withOpacity(0.9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFFF3333).withOpacity(0.35), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.8),
            blurRadius: 15,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: const Color(0xFFFF3333).withOpacity(0.08),
            blurRadius: 20,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: _showFuelCalibrationDialog,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Jauge photo conservée ; seul son encombrement responsive change (pivot/angles inchangés)
                FuelGaugeWidget(
                  fuelLiters: fuelVal,
                  size: gaugeSize,
                  showGlow: true,
                ),
                const SizedBox(width: 10),
                // Bloc télémétrique droit haute visibilité
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Header : Titre + Bouton Plein + Badge CAL
                      Row(
                        children: [
                          const Icon(Icons.local_gas_station, color: Colors.orangeAccent, size: 13),
                          const SizedBox(width: 3),
                          const Expanded(
                            child: Text(
                              "CARBURANT",
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                letterSpacing: 0.8,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            key: const Key('hero_add_fuel_button'),
                            onTap: _showAddFuelDialog,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                              decoration: BoxDecoration(
                                color: Colors.greenAccent.withOpacity(0.18),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.greenAccent.withOpacity(0.5), width: 1.0),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.add, color: Colors.greenAccent, size: 10),
                                  SizedBox(width: 2),
                                  Text(
                                    "+ Plein",
                                    style: TextStyle(color: Colors.greenAccent, fontSize: 8.5, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
                            decoration: BoxDecoration(
                              color: _fuelCalculator.isCalibrated
                                  ? Colors.orangeAccent.withOpacity(0.18)
                                  : Colors.orangeAccent.withOpacity(0.35),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: _fuelCalculator.isCalibrated
                                    ? Colors.orangeAccent.withOpacity(0.4)
                                    : Colors.orangeAccent,
                                width: 1.0,
                              ),
                            ),
                            child: const Text(
                              "CAL",
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 8.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      // Autonomie héro
                      const Text(
                        "AUTONOMIE ESTIMÉE",
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 8.0,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        _fuelCalculator.isCalibrated ? '$kmRestants KM' : 'À CALIBRER',
                        style: TextStyle(
                          color: _fuelCalculator.isCalibrated ? statusColor : Colors.orangeAccent,
                          fontSize: _fuelCalculator.isCalibrated ? 27 : 19,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Litres restants
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            _fuelCalculator.isCalibrated ? '${fuelVal.toStringAsFixed(1)} L' : '-- L',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _fuelCalculator.isCalibrated
                                  ? '/ 35 L (${(fuelPercent * 100).toStringAsFixed(0)}%)'
                                  : '/ 35 L (Touchez pour caler)',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      // Barre de progression carburant
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          height: 5,
                          color: Colors.white10,
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: fuelPercent,
                            child: Container(
                              color: statusColor,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      // Consommation instantanée distincte
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              instantConsoStr,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Text(
                            "Toucher = CAL",
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 8.0,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRpmGauge({bool isLandscape = false, double? heightOverride}) {
    return _buildGlassCard(
      height: heightOverride ?? (isLandscape ? 180 : (isHudMode ? 320 : 220)),
      margin: isLandscape ? const EdgeInsets.all(8) : const EdgeInsets.all(4),
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

  Widget _buildSpeedGauge({bool isLandscape = false, double? heightOverride}) {
    return _buildGlassCard(
      height: heightOverride ?? (isLandscape ? 180 : (isHudMode ? 320 : 220)),
      margin: isLandscape ? const EdgeInsets.all(8) : const EdgeInsets.all(4),
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
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _startupTimer?.cancel();
    _uiTimer?.cancel();
    _dataSyncTimer?.cancel();
    _obdSubscription?.cancel();
    _obdService.dispose();
    unawaited(_fuelCalculator.save().catchError((Object error, StackTrace stack) {
      debugPrint('Sauvegarde carburant fermeture: $error');
    }));
    super.dispose();
  }
}
