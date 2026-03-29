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
      await sendCommandWait('ATZ', delay: 1200);   // Reset long (1.2s pour les clones)
      await sendCommandWait('ATE0', delay: 500);    // Echo Off
      await sendCommandWait('ATL0', delay: 500);    // Linefeed Off
      await sendCommandWait('ATSP0', delay: 1000);  // Auto-protocole (Laisse la Spark décider)
      await sendCommandWait('0100', delay: 1000);   // Réveil du bus CAN (Check PIDs)
      
      _ttsService.speak("Scanner Mimo Spark prêt avec journal de bord.");
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

  void _startPolling() {
    _pollingTimer?.cancel();
    int tick = 0;
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (_socket == null) return;
      
      // PRIORITÉ HAUTE : RPM et Vitesse à chaque fois
      sendCommand('010C'); // RPM
      sendCommand('010D'); // Speed

      // PRIORITÉ BASSE : Les autres toutes les X itérations
      if (tick % 5 == 0) sendCommand('0105'); // Temp (tous les 1.5s)
      if (tick % 3 == 0) sendCommand('0110'); // MAF (tous les 0.9s)
      if (tick % 10 == 0) sendCommand('0142'); // Battery (tous les 3s)
      if (tick % 15 == 0) sendCommand('012F'); // Fuel (tous les 4.5s)
      
      tick++;
    });
  }

  void _handleDisconnect() {
    _socket?.destroy();
    _socket = null;
    _pollingTimer?.cancel();
    
    // On attend 5 secondes et on retente la connexion pour Mimo
    Future.delayed(const Duration(seconds: 5), () {
      if (_socket == null) {
        print("Mimo Spark : Tentative de reconnexion...");
        connect();
      }
    });
  }

  // Met le polling en pause pour scanner les erreurs (Mode 03 + 07 + 0A)
  Future<void> scanTroubleCodes() async {
    _pollingTimer?.cancel();
    await Future.delayed(const Duration(milliseconds: 500));
    
    sendCommand('03'); // Mode 03 : Codes confirmés
    await Future.delayed(const Duration(seconds: 2));
    
    sendCommand('07'); // Mode 07 : Codes en attente (Crucial sur Spark)
    await Future.delayed(const Duration(seconds: 2));

    sendCommand('0A'); // Mode 0A : Codes permanents
    await Future.delayed(const Duration(seconds: 2));
    
    _startPolling();
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
  
  void dispose() {
    _handleDisconnect();
    _dataStreamController.close();
  }
}
