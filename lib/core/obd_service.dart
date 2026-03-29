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

      // Réactivation PRO de l'adaptateur - Optimisé Spark
      await sendCommandWait('ATZ');   // Reset
      await sendCommandWait('ATE0');  // Echo Off
      await sendCommandWait('ATL0');  // Linefeed Off
      await sendCommandWait('ATSP6'); // Force Protocole CAN (Mimo Spark Style)
      await sendCommandWait('0100');  // Check Supported PIDs
      
      _ttsService.speak("Scanner Mimo Spark prêt.");
      _startPolling();
      return true;
    } catch (e) {
      _ttsService.speak("Connexion Wi-Fi perdue.");
      return false;
    }
  }

  Future<void> sendCommandWait(String cmd) async {
    sendCommand(cmd);
    await Future.delayed(const Duration(milliseconds: 400));
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
      _socket!.write('$command\r');
    }
  }
  
  void dispose() {
    _handleDisconnect();
    _dataStreamController.close();
  }
}
