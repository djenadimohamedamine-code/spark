import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../vocal/tts_service.dart';

class ObdService {
  final String ip = '192.168.0.10';
  final int port = 35000;
  
  Socket? _socket;
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
      await _logFile!.writeAsString('--- MIMO SPARK LOG START ${DateTime.now()} ---\n');
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

      // Séquence de réveil MIMO SPARK - Version "Ultra Robuste"
      _log("INIT: Séquence de réveil...");
      await sendCommandWait('ATZ', delay: 1200);   // Reset long
      await sendCommandWait('ATE0', delay: 500);    // Echo Off
      await sendCommandWait('ATL0', delay: 500);    // Linefeed Off
      await sendCommandWait('ATH1', delay: 500);    // AFFICHE LES HEADERS (Crucial pour le scan)
      await sendCommandWait('ATSP3', delay: 1000);  // ISO 9141-2 (Spark 2009 GM/Daewoo)
      await sendCommandWait('0100', delay: 1000);   // Réveil du bus CAN
      
      _ttsService.speak("Scanner Mimo Spark prêt avec journal de bord et forçage protocole.");
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
          sendCommand('0110'); // MAF
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (tick % 10 == 0) {
          sendCommand('0142'); // Battery
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (tick % 15 == 0) {
          sendCommand('012F'); // Fuel (if supported)
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
    // CRITIQUE: on arrête la boucle AVANT d'envoyer les commandes DTC
    _isPolling = false;
    await Future.delayed(const Duration(milliseconds: 800)); // attendre que la boucle finisse
    
    _log("SCAN: Démarrage scan DTC Mode 03/07/0A...");
    
    sendCommand('03'); // Codes confirmés
    await Future.delayed(const Duration(seconds: 3));
    
    sendCommand('07'); // Codes en attente
    await Future.delayed(const Duration(seconds: 3));

    sendCommand('0A'); // Codes permanents
    await Future.delayed(const Duration(seconds: 3));
    
    _log("SCAN: Fin du scan. Reprise du polling.");
    _startPolling(); // on relance le polling après
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
}
