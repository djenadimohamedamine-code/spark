import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../vocal/tts_service.dart';

class ObdService {
  final String ip = '192.168.0.10';
  final int port = 35000;

  Socket? _socket;
  Socket? get socket => _socket;

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

  final TtsService _ttsService = TtsService();

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

  Future<bool> connect() async {
    await _initLogFile();
    _log("Mimo Spark: Tentative de connexion Wi-Fi...");

    try {
      _socket =
          await Socket.connect(ip, port, timeout: const Duration(seconds: 10));

      // ── Écoute TCP avec tampon "attend le '>'" ────────────────────────
      _tcpBuffer = '';
      _socket!.listen(
        (List<int> event) {
          final String chunk = String.fromCharCodes(event);
          _log("BRUT: $chunk");
          _tcpBuffer += chunk;

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

              _log("CLEAN: $telegram");
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

      // ── Séquence d'initialisation ELM327 ──────────────────────────────
      _log("INIT: Séquence de réveil...");
      await sendCommandWait('ATZ', delay: 1200);
      await sendCommandWait('ATE0', delay: 500);
      await sendCommandWait('ATL0', delay: 500);
      await sendCommandWait('ATH0', delay: 500);
      await sendCommandWait('ATSP0', delay: 1000);
      await sendCommandWait('0100', delay: 1000); // Test de com + sync protocole

      _ttsService.speak("Scanner Mimo Spark prêt.");
      _startPolling();
      return true;
    } catch (e) {
      _log("CONNECTION FAILED: $e");
      _ttsService.speak("Connexion Wi-Fi perdue.");
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
        upper.startsWith('ATH') ||
        upper.startsWith('ATSP') ||
        upper.startsWith('ATSH') ||
        upper.startsWith('SEARCHING');
  }

  Future<void> sendCommandWait(String cmd, {int delay = 400}) async {
    sendCommand(cmd);
    await Future.delayed(Duration(milliseconds: delay));
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
        await Future.delayed(const Duration(milliseconds: 350));

        if (!_isDiagnosticMode) sendCommand('010D'); // Vitesse
        await Future.delayed(const Duration(milliseconds: 350));

        // Priorité basse selon cycle de tick
        if (tick % 5 == 0 && !_isDiagnosticMode) {
          sendCommand('0105'); // Temp liquide refroidissement
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (tick % 3 == 0 && !_isDiagnosticMode) {
          sendCommand('010B'); // MAP (pression d'admission en kPa)
          await Future.delayed(const Duration(milliseconds: 300));
        }
        // IAT toutes les ~15 itérations (≈7 s) pour la formule MAF dynamique
        if (tick % 15 == 0 && !_isDiagnosticMode) {
          sendCommand('010F'); // IAT — Température d'admission
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (tick % 10 == 0 && !_isDiagnosticMode) {
          sendCommand('ATRV'); // Tension batterie
          await Future.delayed(const Duration(milliseconds: 300));
        }

        tick++;
      } catch (e) {
        _log("POLLING ERROR: $e");
        break;
      }
    }
  }

  void _handleDisconnect({bool autoReconnect = true}) {
    _socket?.destroy();
    _socket = null;
    _isPolling = false;
    _tcpBuffer = '';

    if (autoReconnect) {
      Future.delayed(const Duration(seconds: 5), () {
        if (_socket == null) {
          _log("Mimo Spark : Tentative de reconnexion automatique...");
          connect();
        }
      });
    }
  }

  // ── Scan des codes DTC (Mode 03 + 07) ───────────────────────────────────
  Future<void> scanTroubleCodes() async {
    _isDiagnosticMode = true;
    _log("SCAN: Arrêt du polling et bascule en mode Diagnostic...");

    try {
      // Attendre fin de la dernière commande polling (évite Erreur 103)
      await Future.delayed(const Duration(milliseconds: 1000));
      _tcpBuffer = ''; // Vider le tampon avant le scan

      _log("SCAN: Prise de contrôle du canal OBD (V4.30 - Sans Reset)");

      // Mode 03 — Codes confirmés (stockés, voyant allumé)
      _log("SCAN: Envoi codes confirmés (03)...");
      sendCommand("03");
      await Future.delayed(const Duration(seconds: 4));

      // Mode 07 — Codes en attente (voyant éteint mais panne détectée)
      _log("SCAN: Envoi codes en attente (07)...");
      sendCommand("07");
      await Future.delayed(const Duration(seconds: 4));

      _log("SCAN: Libération du canal. Reprise du polling.");
    } catch (e) {
      _log("Erreur Scan Force: $e");
    } finally {
      // Pas besoin de forcer ATSP0 ou ATZ car nous n'avons pas changé de protocole !
      _log("SCAN: Fin du diagnostic. Reprise Auto.");
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

      // Reset + protocol Daewoo/Chevrolet KWP
      await sendCommandWait('ATZ', delay: 1500);
      await sendCommandWait('ATSP5', delay: 800);

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
  void clearCodes() {
    sendCommand('04');
    _ttsService.speak("Codes erreurs effacés.");
  }

  void sendCommand(String command) {
    if (_socket != null) {
      _log("SENT: $command");
      _socket!.write('$command\r');
    }
  }

  Future<File?> getLogFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/debug_mimo.txt');
    if (await file.exists()) return file;
    return null;
  }

  void dispose() {
    _handleDisconnect();
    if (!_dataStreamController.isClosed) _dataStreamController.close();
    if (!_dtcStreamController.isClosed) _dtcStreamController.close();
    if (!_mileageStreamController.isClosed) _mileageStreamController.close();
  }

  void disconnect() {
    _handleDisconnect(autoReconnect: false);
  }
}
