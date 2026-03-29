import 'dart:async';
import 'dart:io';
import '../vocal/tts_service.dart';

class ObdService {
  final String ip = '192.168.0.10';
  final int port = 35000;
  
  Socket? _socket;
  final StreamController<String> _dataStreamController = StreamController<String>.broadcast();
  Stream<String> get dataStream => _dataStreamController.stream;
  Timer? _pollingTimer;
  final TtsService _ttsService = TtsService();

  Future<bool> connect() async {
    try {
      _socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 10));
      
      String responseBuffer = "";
      _socket!.listen(
        (List<int> event) {
          final String chunk = String.fromCharCodes(event);
          responseBuffer += chunk;
          
          // Technique Mimo : On traite les lignes dès qu'elles arrivent
          if (responseBuffer.contains('\r') || responseBuffer.contains('>')) {
            List<String> lines = responseBuffer.split(RegExp(r'[\r\n>]'));
            for (String line in lines) {
              String telegram = line.trim();
              if (telegram.isNotEmpty && telegram != "OK" && telegram != "SEARCHING") {
                print("Spark Data Flow: $telegram");
                if (!_dataStreamController.isClosed) {
                  _dataStreamController.add(telegram);
                }
              }
            }
            // On ne garde que le reliquat incomplet
            responseBuffer = (chunk.endsWith('\r') || chunk.endsWith('>')) ? "" : lines.last;
          }
        },
        onError: (error) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
      );

      // Réactivation PRO de l'adaptateur
      await sendCommandWait('ATZ');
      await sendCommandWait('ATE0');
      await sendCommandWait('ATL0');
      await sendCommandWait('ATSP0');
      await sendCommandWait('0100');
      
      _ttsService.speak("Connexion établie avec la Spark.");
      _startPolling();
      return true;
    } catch (e) {
      _ttsService.speak("Mimo, impossible de se connecter au boîtier Wi-Fi.");
      return false;
    }
  }

  Future<void> sendCommandWait(String cmd) async {
    sendCommand(cmd);
    await Future.delayed(const Duration(milliseconds: 300));
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    int tick = 0;
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      if (_socket == null) return;
      switch (tick % 6) {
        case 0: sendCommand('0105'); break; // Temp
        case 1: sendCommand('010C'); break; // RPM
        case 2: sendCommand('010D'); break; // Speed
        case 3: sendCommand('0110'); break; // MAF
        case 4: sendCommand('0142'); break; // Battery (ECU Voltage)
        case 5: sendCommand('012F'); break; // Fuel Level
      }
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

  // Met le polling en pause pour scanner les erreurs (Mode 03)
  Future<void> scanTroubleCodes() async {
    _pollingTimer?.cancel();
    await Future.delayed(const Duration(milliseconds: 500));
    sendCommand('03'); // Commande pour lire les codes DTC
    // On laisse le temps à la réponse d'arriver avant de reprendre le dashboard
    Future.delayed(const Duration(seconds: 3), () => _startPolling());
  }

  // Effacer les codes (Mode 04) - À n'utiliser qu'après réparation !
  void clearCodes() {
    sendCommand('04');
    _ttsService.speak("Codes erreurs effacés.");
  }

  void sendCommand(String command) {
    if (_socket != null) {
      _socket!.write('$command\r');
    }
  }
  
  void dispose() {
    _handleDisconnect();
    _dataStreamController.close();
  }
}
