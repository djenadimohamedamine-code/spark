import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../vocal/tts_service.dart';

class ObdService {
  final String ip = '192.168.0.10';
  final int port = 35000;
  
  Socket? _socket;
  Socket? get socket => _socket; // Exposé pour vérification depuis le Dashboard
  final StreamController<String> _dataStreamController = StreamController<String>.broadcast();
  Stream<String> get dataStream => _dataStreamController.stream;
  Timer? _pollingTimer;
  final TtsService _ttsService = TtsService();

  // Système de Log "Boite Noire" Mimo Spark
  File? _logFile;

  Future<void> _initLogFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      _logFile = File('${directory.path}/debug_mimo.txt');
        await _logFile!.writeAsString('\n--- MIMO SPARK LOG START ${DateTime.now()} ---\n', mode: FileMode.append);
    } catch (e) {
      print("Erreur Init Log: $e");
    }
  }

  Future<void> _log(String message) async {
    if (_logFile != null) {
      final stamp = DateTime.now().toString().substring(11, 19);
      await _logFile!.writeAsString('[$stamp] $message\n', mode: FileMode.append);
    }
    print(message);
  }

  Future<bool> connect() async {
    await _initLogFile();
    _log("Mimo Spark: Tentative de connexion Wi-Fi...");
    
    try {
      _socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 10));
      
      String responseBuffer = "";
      _socket!.listen(
        (List<int> event) {
          final String chunk = String.fromCharCodes(event);
          _log("BRUT: $chunk");
          responseBuffer += chunk;
          
          if (responseBuffer.contains('\r') || responseBuffer.contains('>')) {
            List<String> lines = responseBuffer.split(RegExp(r'[\r\n>]'));
            for (String line in lines) {
              String telegram = line.trim();
              if (telegram.isNotEmpty && telegram != "OK" && telegram != "SEARCHING") {
                _log("CLEAN: $telegram");
                if (!_dataStreamController.isClosed) {
                  _dataStreamController.add(telegram);
                }
              }
            }
            responseBuffer = (chunk.endsWith('\r') || chunk.endsWith('>')) ? "" : lines.last;
          }
        },
        onError: (error) {
           _log("SOCKET ERROR: $error");
           _handleDisconnect();
        },
        onDone: () => _handleDisconnect(),
      );

      // Séquence de réveil MIMO SPARK - Version Originale (Auto)
      _log("INIT: Séquence de réveil...");
      await sendCommandWait('ATZ', delay: 1200);   // Reset long
      await sendCommandWait('ATE0', delay: 500);    // Echo Off
      await sendCommandWait('ATL0', delay: 500);    // Linefeed Off
      await sendCommandWait('ATH0', delay: 500);    // Pas de headers (Format simple, permet au parser DTC ancien de marcher
      await sendCommandWait('ATSP0', delay: 1000);  // Protocole Automatique (Fait confience à l'ELM327 pour le Fast Init)
      
      await sendCommandWait('0100', delay: 1000);   // Test de communication et Sync
      
      _ttsService.speak("Scanner Mimo Spark prêt avec protocole Auto original.");
      _startPolling();
      return true;
    } catch (e) {
      _log("CONNECTION FAILED: $e");
      _ttsService.speak("Connexion Wi-Fi perdue.");
      return false;
    }
  }

  Future<void> sendCommandWait(String cmd, {int delay = 400}) async {
    sendCommand(cmd);
    await Future.delayed(Duration(milliseconds: delay));
  }

  bool _isPolling = false;

  void _startPolling() async {
    if (_isPolling) return;
    _isPolling = true;
    _log("Mimo Spark: Lancement du polling séquentiel...");
    
    int tick = 0;
    while (_socket != null && _isPolling) {
      try {
        // PRIORITÉ HAUTE : RPM et Vitesse à chaque fois
        sendCommand('010C'); // RPM
        await Future.delayed(const Duration(milliseconds: 350));
        
        sendCommand('010D'); // Speed
        await Future.delayed(const Duration(milliseconds: 350));

        // PRIORITÉ BASSE : Les autres selon le tick
        if (tick % 5 == 0) {
          sendCommand('0105'); // Temp
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (tick % 3 == 0) {
          sendCommand('010B'); // MAP (Intake Manifold Pressure) - REMPLACE MAF
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (tick % 10 == 0) {
          sendCommand('ATRV'); // Voltage Batterie directement depuis l'ELM327 (100% fiable)
          await Future.delayed(const Duration(milliseconds: 300));
        }
        
        tick++;
      } catch (e) {
        _log("POLLING ERROR: $e");
        break;
      }
    }
  }

  void _handleDisconnect() {
    _socket?.destroy();
    _socket = null;
    _isPolling = false;
    
    // On attend 5 secondes et on retente la connexion pour Mimo
    Future.delayed(const Duration(seconds: 5), () {
      if (_socket == null) {
        print("Mimo Spark : Tentative de reconnexion...");
        connect();
      }
    });
  }

  // Stoppe le polling et Scanne les erreurs (Mode 03 + 07 + 0A)
  Future<void> scanTroubleCodes() async {
    try {
      _isPolling = false; // Stopper les aiguilles pour éviter les collisions
      await Future.delayed(const Duration(milliseconds: 1000));
      
      _log("SCAN: Réveil forcé du calculateur Chevrolet (V4.26)");

      // 1. Initialisation Protocole KWP Fast
      sendCommand('ATSP 5');
      await Future.delayed(const Duration(milliseconds: 500));

      // 2. Paramétrage Daewoo / Chevrolet
      sendCommand('ATAL'); // TRÈS IMPORTANT : Autorise les réponses de plus de 1 ligne (DTC multiples)
      await Future.delayed(const Duration(milliseconds: 300));
      
      sendCommand("ATSH 81 11 F1"); // Header Daewoo Spark
      await Future.delayed(const Duration(milliseconds: 500));

      sendCommand("ATFI"); // Electrochoc "Fast Init" (Réveil du bus K)
      await Future.delayed(const Duration(milliseconds: 1500));

      // 3. Demande des Codes Erreurs
      _log("SCAN: Envoi des requêtes 03 et 07...");
      sendCommand("03"); 
      await Future.delayed(const Duration(seconds: 4)); 
      
      sendCommand("07");
      await Future.delayed(const Duration(seconds: 4));

      // 4. Remise à zéro pour le Dashboard
      sendCommand("ATSP 0");
      sendCommand("ATH0");
      
      _log("SCAN: Scan terminé. Mimo, regarde l'écran.");
      _startPolling(); 
    } catch (e) {
      _log("Erreur Scan: $e");
      _startPolling();
    }
  }

  // Effacer les codes (Mode 04) - À n'utiliser qu'après réparation !
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
    _dataStreamController.close();
  }

  // Permet au Dashboard de forcer la déconnexion en arrière-plan
  void disconnect() {
    _handleDisconnect();
  }
}
