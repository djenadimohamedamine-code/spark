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
      _socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      
      String responseBuffer = "";
      _socket!.listen(
        (List<int> event) {
          final String chunk = String.fromCharCodes(event);
          responseBuffer += chunk;
          if (responseBuffer.contains('>')) {
            print("Spark Data: $responseBuffer"); // Debugging Wi-Fi Flow
            _dataStreamController.add(responseBuffer.trim());
            responseBuffer = "";
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
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (_socket == null) return;
      switch (tick % 5) {
        case 0: sendCommand('0105'); break; // Temp
        case 1: sendCommand('010C'); break; // RPM
        case 2: sendCommand('010D'); break; // Speed
        case 3: sendCommand('0110'); break; // MAF
        case 4: sendCommand('0142'); break; // Battery
      }
      tick++;
    });
  }

  void _handleDisconnect() {
    _socket?.destroy();
    _socket = null;
    _pollingTimer?.cancel();
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
