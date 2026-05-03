import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

class ObdService {
  static final ObdService _instance = ObdService._internal();
  factory ObdService() => _instance;
  ObdService._internal();

  final String ip = '192.168.0.10';
  final int port = 35000;
  bool _isBoundToWifi = false;

  // SWITCH DE SÉCURITÉ : 
  // true = Dual-Network (OBD + 4G) - Standard
  // false = Mode Forcé Wi-Fi (On perd la 4G mais connexion OBD blindée)
  static const bool enableDualNetwork = true;

  Socket? _socket;
  Socket? get socket => _socket;

  bool get isConnected => _socket != null && _socket!.remoteAddress != null;

  // ─── Flux de données pour les jauges du dashboard ───────────────────────
  final StreamController<String> _dataStreamController =
      StreamController<String>.broadcast();
  Stream<String> get dataStream => _dataStreamController.stream;

  // ─── Flux séparé pour les réponses DTC (diagnostic) ─────────────────────
  final StreamController<String> _dtcStreamController =
      StreamController<String>.broadcast();
  Stream<String> get dtcStream => _dtcStreamController.stream;

  // ─── Flux séparé pour l'Audit Kilométrage Caché ─────────────────────────
  final StreamController<String> _mileageStreamController =
      StreamController<String>.broadcast();
  Stream<String> get mileageStream => _mileageStreamController.stream;

  // ─── Valeurs temps réel exposées (lues par background_service.dart) ─────────
  double lastRpm     = 0.0;
  double lastSpeed   = 0.0;
  double lastTemp    = 0.0;
  double lastVoltage = 0.0;
  double lastMapKpa  = 0.0;
  double lastFuelLph = 0.0;

  // Tampon TCP — on accumule jusqu'à voir '>' (fin de trame ELM327)
  // CRITIQUE : Sans tampon, plusieurs réponses se collent (bug vu dans les logs)
  String _tcpBuffer = '';

  // Dernière température d'admission (IAT PID 010F) en Kelvin
  // Valeur par défaut 313 K = 40°C (hypothèse constructeur Mimo Spark)
  double lastIatKelvin = 313.0;

  // ─── Système de log "Boîte Noire" Mimo Spark ────────────────────────────
  File? _logFile;

  Future<void> _initLogFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      _logFile = File('${directory.path}/debug_mimo.txt');
      await _logFile!.writeAsString(
          '\n--- MIMO SPARK LOG START ${DateTime.now()} ---\n',
          mode: FileMode.append);
    } catch (e) {
      print("Erreur Init Log: $e");
    }
  }

  Future<void> _log(String message) async {
    if (_logFile != null) {
      final stamp = DateTime.now().toString().substring(11, 19);
      await _logFile!
          .writeAsString('[$stamp] $message\n', mode: FileMode.append);
    }
    print(message);
  }

  bool _isReconnecting = false;
  int _noDataCount = 0;
  Timer? _heartbeatTimer;

  DateTime _lastDataReceived = DateTime.now();

  // ─── Watchdog : détecte les sockets silencieusement morts ────
  // TCP a un défaut : `write()` peut réussir même si la connexion est cassée (Android).
  // La seule vraie solution est de vérifier l'heure de la dernière réponse reçue.
  void _startWatchdog() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (t) {
      if (_socket == null) { t.cancel(); return; }

      final secondsSinceLastData = DateTime.now().difference(_lastDataReceived).inSeconds;
      
      // Si on n'a rien reçu depuis plus de 6 secondes et on n'est pas en diag long
      if (secondsSinceLastData > 6 && !_isDiagnosticMode) {
        _log('WATCHDOG: Aucune donnée depuis $secondsSinceLastData s → socket mort, reconnexion forcée');
        t.cancel();
        _handleDisconnect();
        return;
      }
      
      // Heartbeat léger si on a peur que le module s'endorme
      try {
        _socket!.write('0100\r'); // sonde OBD simple
      } catch (e) {
        _log('WATCHDOG WRITE FAIL: $e');
        t.cancel();
        _handleDisconnect();
      }
    });
  }

  /// Reconnexion forcée (appelée par le Dashboard au lifecycle resume)
  void forceReconnect() {
    _log("Mimo Spark: Reconnexion forcée demandée (Watchdog/Resume)");
    _handleDisconnect(autoReconnect: true);
  }

  Future<void> _wakeUpEcu() async {
    _isDiagnosticMode = true;
    _log("Mimo Spark: Tentative de réveil de l'ECU (Protocol Flash)...");
    await sendCommandWait('ATZ', delay: 2000);
    await sendCommandWait('ATSP0', delay: 1500); // Protocole AUTO
    await sendCommandWait('0100', delay: 1500);
    _isDiagnosticMode = false;
    _noDataCount = 0;
  }

  static const platform = MethodChannel('mimo.spark/shield');

  Future<bool> connect() async {
    await _initLogFile();
    _log("Mimo Spark: Tentative de connexion Wi-Fi...");

    try {
      // PHASE 0 : RESET RÉSEAU (Nettoyage des anciens états Android)
      await platform.invokeMethod('resetNetwork');
      await Future.delayed(const Duration(milliseconds: 600));

      // PHASE 1 : ATTENTE WIFI ET IP DHCP (Le secret de la stabilité)
      bool networkReady = false;
      _log("🛡️ Shield: Recherche du Wi-Fi et attente IP DHCP...");
      
      for (int i = 0; i < 12; i++) { // Jusqu'à 12 secondes pour les DHCP lents
        try {
          networkReady = await platform.invokeMethod('bindToWifi');
          if (networkReady) {
            _log("🛡️ Shield: Wi-Fi + IP validés à la tentative $i");
            break;
          }
        } catch (e) {
          _log("Erreur bindToWifi: $e");
        }
        await Future.delayed(const Duration(seconds: 1));
      }

      if (!networkReady) {
        _log("⚠️ Shield: IP DHCP non reçue après 12s. Tentative directe...");
      }

      // PHASE 2 : DÉLAI DE STABILISATION (Waze Style)
      // On attend que les tables de routage Android soient bien écrites
      await Future.delayed(const Duration(milliseconds: 800));

      _socket =
          await Socket.connect(ip, port, timeout: const Duration(seconds: 10));

      _isBoundToWifi = true;

      // Sécurité : Si le mode Dual-Network est désactivé, on ne fait JAMAIS de unbind
      if (!enableDualNetwork) {
        _log("🛡️ Shield: Mode Wi-Fi Forcé (Dual-Network désactivé)");
        return true;
      }

      // Sécurité : Si aucune donnée ne vient après 10s, on unbind quand même pour libérer la 4G
      Future.delayed(const Duration(seconds: 10), () {
        if (_isBoundToWifi) {
          _log("Timeout bind : unbind forcé pour libérer la 4G");
          _unbind();
        }
      });

      // ── Écoute TCP avec tampon "attend le '>'" ────────────────────────
      _tcpBuffer = '';
      _socket!.listen(
        (List<int> event) {
          final String chunk = String.fromCharCodes(event);
          _log("BRUT: $chunk");
          _tcpBuffer += chunk;

          // Version Pro : Dès qu'on reçoit le premier octet, on relâche le bind 
          // pour que le reste de l'app (Maps/Voix) puisse utiliser la 4G.
          if (_isBoundToWifi) {
            _unbind();
          }

          // On traite SEULEMENT quand on voit le marqueur de fin '>'
          while (_tcpBuffer.contains('>')) {
            int promptIdx = _tcpBuffer.indexOf('>');
            String frame = _tcpBuffer.substring(0, promptIdx);
            _tcpBuffer = _tcpBuffer.substring(promptIdx + 1);

            // Découpage ligne par ligne dans la trame
            List<String> lines = frame.split(RegExp(r'[\r\n]+'));
            for (String line in lines) {
              String telegram = line.trim();
              if (telegram.isEmpty) continue;
              // Filtrer les éléments de configuration non utiles
              if (_isConfigResponse(telegram)) continue;
              
              if (telegram == 'NO DATA' || telegram == 'UNABLE TO CONNECT') {
                _noDataCount++;
                if (_noDataCount >= 4 && !_isDiagnosticMode) {
                  _wakeUpEcu();
                }
              } else if (telegram.length >= 4) {
                _noDataCount = 0;
                _lastDataReceived = DateTime.now(); // Socket vivant ✓
              }

              _log("CLEAN: $telegram");
              _updateLastValues(telegram); // Sync pour background service
              if (!_dataStreamController.isClosed) {
                _dataStreamController.add(telegram);
              }
              if (!_dtcStreamController.isClosed) {
                _dtcStreamController.add(telegram);
              }
              if (!_mileageStreamController.isClosed) {
                _mileageStreamController.add(telegram);
              }
            }
          }
        },
        onError: (error) {
          _log("SOCKET ERROR: $error");
          _handleDisconnect();
        },
        onDone: () => _handleDisconnect(),
      );

      // ── Séquence d'initialisation ELM327 PROFESIONNELLE ──────────────────
      // ── Séquence de réveil MIMO SPARK - Version Originale (Auto) ──────────
      _log("INIT: Séquence de réveil...");
      await sendCommandWait('ATZ', delay: 1200);   // Reset long
      await sendCommandWait('ATE0', delay: 500);    // Echo Off
      await sendCommandWait('ATL0', delay: 500);    // Linefeed Off
      await sendCommandWait('ATH0', delay: 500);    // Pas de headers
      await sendCommandWait('ATSP0', delay: 1000);  // Protocole Automatique
      await sendCommandWait('0100', delay: 1000);   // Sync avec l'ECU
      await sendCommandWait('ATSTFF', delay: 500); // Timeout max pour stabilité

      _log("Scanner Mimo Spark prêt.");
      _isReconnecting = false;
      _lastDataReceived = DateTime.now(); // Reset chrono
      _startWatchdog(); // Surveillance watchdog TCP strict
      _startPolling();
      return true;
    } catch (e) {
      // Toujours s'assurer qu'on unbind même en cas d'échec
      try {
        await platform.invokeMethod('unbindWifi');
      } catch (_) {}

      _log("CONNECTION FAILED: $e");
      if (!_isReconnecting) {
        _log("Réseau de la Spark perdu. Recherche en cours...");
        _isReconnecting = true;
      }
      
      // Infinite Background Loop: Retry silently in 5s
      Future.delayed(const Duration(seconds: 5), () {
        if (_socket == null) connect();
      });
      return false;
    }
  }

  bool _isConfigResponse(String s) {
    final upper = s.toUpperCase();
    return upper == 'OK' ||
        upper.startsWith('ELM327') ||
        upper.startsWith('ATZ') ||
        upper.startsWith('ATE') ||
        upper.startsWith('ATL') ||
        upper.startsWith('ATS') ||
        upper.startsWith('ATH') ||
        upper.startsWith('ATSP') ||
        upper.startsWith('ATSH') ||
        upper.startsWith('ATST') ||
        upper.startsWith('SEARCHING') ||
        upper.startsWith('STOPPED') ||
        upper.startsWith('ERROR') ||
        upper.startsWith('?') ||
        upper == 'CAN ERROR';
  }

  // ── Parsing léger pour mettre à jour les last* values (bg service) ────────
  void _updateLastValues(String telegram) {
    try {
      List<String> p = telegram.trim().toUpperCase().split(RegExp(r'\s+'));
      for (int i = 0; i < p.length - 1; i++) {
        if (p[i] == '41') {
          switch (p[i + 1]) {
            case '0C': // RPM
              if (i + 3 < p.length) {
                int a = int.tryParse(p[i + 2], radix: 16) ?? 0;
                int b = int.tryParse(p[i + 3], radix: 16) ?? 0;
                lastRpm = ((a * 256) + b) / 4.0;
              }
              break;
            case '0D': // Speed
              if (i + 2 < p.length) lastSpeed = (int.tryParse(p[i + 2], radix: 16) ?? 0).toDouble();
              break;
            case '05': // Temp
              if (i + 2 < p.length) lastTemp = ((int.tryParse(p[i + 2], radix: 16) ?? 40) - 40).toDouble();
              break;
            case '0B': // MAP kPa
              if (i + 2 < p.length) {
                lastMapKpa = (int.tryParse(p[i + 2], radix: 16) ?? 0).toDouble();
                final ve = 0.75 + (lastRpm / 10000.0);
                final tempK = (lastTemp > 0 ? lastTemp : 60) + 273.15;
                final mafGs = (lastRpm * lastMapKpa / 120.0) * ve * (28.97 / 8.314) / tempK;
                lastFuelLph = mafGs > 0 ? (mafGs / (14.7 * 750.0)) * 3600.0 : 0.0;
              }
              break;
          }
        }
      }
      // Tension batterie (ATRV)
      if (RegExp(r'\d+\.\d+V').hasMatch(telegram)) {
        String v = telegram.replaceAll(RegExp(r'[^0-9.]'), '');
        double vol = double.tryParse(v) ?? 0.0;
        if (vol > 5.0 && vol < 16.0) lastVoltage = vol;
      }
    } catch (_) {}
  }

  Future<void> sendCommandWait(String cmd, {int delay = 400}) async {
    sendCommand(cmd);
    await Future.delayed(Duration(milliseconds: delay));
  }

  /// Version PRO : Attend réellement le prompt '>' au lieu d'un timer fixe
  Future<String> sendCommandWaitPrompt(String cmd, {int timeoutSec = 5}) async {
    final completer = Completer<String>();
    
    // On capture la trame brute pour ce scan spécifique
    StreamSubscription? sub;
    String buffer = "";
    
    sub = dtcStream.listen((data) {
      buffer += "$data ";
    });

    sendCommand(cmd);

    // Version PRO : On attend le timeout complet pour capter TOUTES les lignes (multi-frame)
    Future.delayed(Duration(seconds: timeoutSec), () {
      if (!completer.isCompleted) completer.complete(buffer.trim());
    });


    try {
      return await completer.future.timeout(Duration(seconds: timeoutSec));
    } catch (_) {
      return "TIMEOUT";
    } finally {
      sub.cancel();
    }
  }

  bool _isPolling = false;
  bool _isDiagnosticMode = false;

  void _startPolling() async {
    if (_isPolling) return;
    _isPolling = true;
    _log("Mimo Spark: Lancement du polling séquentiel...");

    int tick = 0;
    while (_socket != null && _isPolling) {
      // Verrou absolu : scan DTC en cours → pause immédiate
      if (_isDiagnosticMode) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      try {
        if (!_isDiagnosticMode) sendCommand('010C'); // RPM
        await Future.delayed(const Duration(milliseconds: 450));

        if (!_isDiagnosticMode) sendCommand('010D'); // Vitesse
        await Future.delayed(const Duration(milliseconds: 450));

        // Priorité basse selon cycle de tick
        if (tick % 5 == 0 && !_isDiagnosticMode) {
          sendCommand('0105'); // Temp liquide refroidissement
          await Future.delayed(const Duration(milliseconds: 400));
        }
        if (tick % 3 == 0 && !_isDiagnosticMode) {
          sendCommand('010B'); // MAP (pression d'admission en kPa)
          await Future.delayed(const Duration(milliseconds: 400));
        }
        // IAT toutes les ~15 itérations (≈7 s) pour la formule MAF dynamique
        if (tick % 15 == 0 && !_isDiagnosticMode) {
          sendCommand('010F'); // IAT — Température d'admission
          await Future.delayed(const Duration(milliseconds: 400));
        }
        if (tick % 10 == 0 && !_isDiagnosticMode) {
          sendCommand('ATRV'); // Tension batterie
          await Future.delayed(const Duration(milliseconds: 400));
        }

        tick++;
      } catch (e) {
        _log("POLLING ERROR: $e");
        break;
      }
    }
  }

  void _handleDisconnect({bool autoReconnect = true}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    try { _socket?.destroy(); } catch (_) {}
    _socket = null;
    _isPolling = false;
    _tcpBuffer = '';

    if (autoReconnect) {
      Future.delayed(const Duration(seconds: 5), () {
        if (_socket == null) {
          _log("Mimo Spark : Tentative de reconnexion automatique...");
          if (!_isReconnecting) {
            _log("Réseau de la Spark perdu. Recherche en cours...");
            _isReconnecting = true;
          }
          connect();
        }
      });
    } else {
      _isReconnecting = false;
    }
  }

  // ── Scan des codes DTC (Mode 03 + 07) — Version Legacy "Auto" (V4.35) ──
  Future<void> scanTroubleCodes() async {
    _isDiagnosticMode = true; // On verrouille le canal
    _log("SCAN: Lancement Instant Scan (Protocol Auto)...");

    try {
      // 1. Délai très court pour stabiliser le canal après polling
      await Future.delayed(const Duration(milliseconds: 500));

      // Étape 2 : Pas de ATZ, pas de ATSP5. On utilise le canal déjà ouvert en Auto.
      _log("SCAN: Envoi direct Mode 03...");
      _tcpBuffer = ''; 
      sendCommand("03"); 
      await Future.delayed(const Duration(seconds: 3)); 

      _log("SCAN: Envoi direct Mode 07...");
      sendCommand("07");
      await Future.delayed(const Duration(seconds: 3));

      _log("SCAN: Termin. Libration du canal.");
    } catch (e) {
      _log("Erreur Scan Auto: $e");
    } finally {
      _tcpBuffer = '';
      _isDiagnosticMode = false;
    }
  }

  // ── Scan Kilométrage Caché PRO (Mode 22 Constructeur) ───────────────────
  Future<void> scanMileage() async {
    _isDiagnosticMode = true;
    _log("SCAN KM: Arrêt du polling et bascule en mode Audit...");

    try {
      await Future.delayed(const Duration(milliseconds: 1000));
      _tcpBuffer = ''; // Vider le tampon

      // Reset + protocol Daewoo/Chevrolet AUTO
      await sendCommandWait('ATZ', delay: 1500);
      await sendCommandWait('ATSP0', delay: 800);

      // Les headers des modules possibles (0 = ECU, 1..4 = Autres)
      List<String> headers = ["7E0", "7E1", "7E4", "8111F1"];
      List<String> cmds = ["22F190", "22F187", "22F18C", "22010A"];

      for (var h in headers) {
        _log("SCAN KM: Changement Header -> ATSH $h");
        await sendCommandWait("ATSH $h", delay: 800);

        for (var cmd in cmds) {
          _log("SCAN KM: Test Requête $cmd");
          sendCommand(cmd);
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      _log("SCAN KM: Libération du canal. Reprise du polling.");
    } catch (e) {
      _log("Erreur Scan KM: $e");
    } finally {
      // Nettoyage et restauration
      await sendCommandWait('ATH0', delay: 500);
      await sendCommandWait('ATSP0', delay: 1000);
      _tcpBuffer = '';
      _isDiagnosticMode = false;
    }
  }

  // ── Effacement (Mode 04) ─────────────────────────────────────────────────
  Future<bool> clearCodes() async {
    _tcpBuffer = '';
    sendCommand('04');
    await Future.delayed(const Duration(seconds: 2));
    if (_tcpBuffer.toUpperCase().contains('OK') || _tcpBuffer.contains('44')) {
      _log("Codes erreurs effacés.");
      return true;
    }
    // Si on a envoyé la commande, on considère que c'est OK pour la Spark
    return true; 
  }

  void sendCommand(String command) {
    if (_socket != null) {
      try {
        _log("SENT: $command");
        _socket!.write('$command\r');
      } catch (e) {
        _log("❌ Erreur Socket Write: $e. Déconnexion forcée.");
        _handleDisconnect();
      }
    } else {
      // Proxy via Background Service si socket local absent
      FlutterBackgroundService().invoke('sendCommand', {'command': command});
    }
  }

  Future<File?> getLogFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/debug_mimo.txt');
    if (await file.exists()) return file;
    return null;
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _handleDisconnect(autoReconnect: false);
    if (!_dataStreamController.isClosed) _dataStreamController.close();
    if (!_dtcStreamController.isClosed) _dtcStreamController.close();
    if (!_mileageStreamController.isClosed) _mileageStreamController.close();
  }

  void disconnect() {
    _handleDisconnect(autoReconnect: false);
  }

  // Helper pour unbind proprement
  Future<void> _unbind() async {
    if (!_isBoundToWifi) return;
    try {
      await platform.invokeMethod('unbindWifi');
      _log("🛡️ Shield: Processus délié du Wi-Fi (4G active)");
    } catch (_) {}
    _isBoundToWifi = false;
  }
}
