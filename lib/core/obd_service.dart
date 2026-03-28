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

  Future<void> connect() async {
    try {
      _socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      _socket!.listen(
        (List<int> event) {
          final String data = String.fromCharCodes(event).trim();
          _dataStreamController.add(data);
        },
        onError: (error) {
          print('Erreur Socket: $error');
          _ttsService.speak("Mimo, j'ai perdu la connexion avec la Spark");
          _handleDisconnect();
        },
        onDone: () {
          print('Socket fermé');
          _ttsService.speak("Mimo, j'ai perdu la connexion avec la Spark");
          _handleDisconnect();
        },
      );
      // Initialisation PRO ELM327
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand('ATZ'); // Reset
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand('ATE0'); // Echo OFF
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand('ATL0'); // Linefeeds OFF
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand('ATSP0'); // Auto Protocol Search
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand('01 00'); // Test OBD Ping
      
      _ttsService.speak("Connexion établie avec la Spark.");
      _startPolling();
    } catch (e) {
      print('Erreur de connexion ELM327: $e');
      _ttsService.speak("Mimo, impossible de se connecter au boîtier Wi-Fi.");
    }
  }

  void _startPolling() {
    int tick = 0;
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      switch (tick % 5) {
        case 0:
          sendCommand('01 05'); // Coolant Temp
          break;
        case 1:
          sendCommand('01 0C'); // RPM
          break;
        case 2:
          sendCommand('01 0D'); // Speed
          break;
        case 3:
          sendCommand('01 10'); // MAF
          break;
        case 4:
          sendCommand('01 2F'); // Fuel Level
          break;
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
