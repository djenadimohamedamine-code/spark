import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

class ObdService {
  static final ObdService _instance = ObdService._internal();
  factory ObdService() => _instance;
  ObdService._internal();

  final String ip = '192.168.0.10';
  final int port = 35000;

  Socket? _socket;
  Socket? get socket => _socket;

  bool get isConnected => _socket != null;

  // --- Flux de données pour les jauges du dashboard ---
  final StreamController<String> _dataStreamController =
      StreamController<String>.broadcast();
  Stream<String> get dataStream => _dataStreamController.stream;

  final StreamController<String> _dtcStreamController =
      StreamController<String>.broadcast();
  Stream<String> get dtcStream => _dtcStreamController.stream;

  final StreamController<String> _mileageStreamController =
      StreamController<String>.broadcast();
  Stream<String> get mileageStream => _mileageStreamController.stream;

  // --- Valeurs temps réel exposées ---
  double lastRpm     = 0.0;
  double lastSpeed   = 0.0;
  double lastTemp    = 0.0;
  double lastVoltage = 0.0;
  double lastMapKpa  = 0.0;
  double lastFuelLph = 0.0;

  String _tcpBuffer = '';
  double lastIatKelvin = 313.0;

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
  bool _isDiagnosticMode = false;

  // --- Watchdog Intelligent (Version 5.0) ---
  void _startWatchdog() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (t) {
      if (_socket == null) { t.cancel(); return; }

      final secondsSinceLastData = DateTime.now().difference(_lastDataReceived).inSeconds;
      
      // Sécurité 1 : Reconnexion si mort depuis 30 secondes
      if (secondsSinceLastData > 30 && !_isDiagnosticMode && _isPolling) {
        _log('WATCHDOG: Silence radio (30s) -> Reconnexion');
        t.cancel();
        _handleDisconnect();
        return;
      }
      
      // Sécurité 2 : Heartbeat léger (seulement si silence > 5s)
      if (secondsSinceLastData > 5 && !_isDiagnosticMode) {
        try {
          _socket!.write('0100\r'); 
        } catch (e) {
          _log('WATCHDOG WRITE FAIL: $e');
          t.cancel();
          _handleDisconnect();
        }
      }
    });
  }

  void forceReconnect() {
    _log("Mimo Spark: Reconnexion forcée demandée");
    _handleDisconnect(autoReconnect: true);
  }

  Future<void> _wakeUpEcu() async {
    _isDiagnosticMode = true;
    _log("Mimo Spark: Réveil ECU...");
    await sendCommandWait('ATZ', delay: 2000);
    await sendCommandWait('ATSP0', delay: 1500); 
    await sendCommandWait('0100', delay: 1500);
    _isDiagnosticMode = false;
    _noDataCount = 0;
  }

  Future<bool> connect() async {
    await _initLogFile();
    try {
      _log("Mimo Spark: Connexion Socket directe (IP Statique conseillée)...");
      
      _socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 10));
      _socket!.setOption(SocketOption.tcpNoDelay, true); // Réduit la latence réseau (Important pour ELM327)

      _tcpBuffer = '';
      _socket!.listen(
        (List<int> event) {
          final String chunk = String.fromCharCodes(event);
          _tcpBuffer += chunk;

          while (_tcpBuffer.contains('>')) {
            int promptIdx = _tcpBuffer.indexOf('>');
            String frame = _tcpBuffer.substring(0, promptIdx);
            _tcpBuffer = _tcpBuffer.substring(promptIdx + 1);

            List<String> lines = frame.split(RegExp(r'[\r\n]+'));
            for (String line in lines) {
              String telegram = line.trim();
              if (telegram.isEmpty) continue;
              if (_isConfigResponse(telegram)) continue;
              
              if (telegram == 'NO DATA' || telegram == 'UNABLE TO CONNECT') {
                _noDataCount++;
                if (_noDataCount >= 4 && !_isDiagnosticMode) _wakeUpEcu();
              } else if (telegram.length >= 4) {
                _noDataCount = 0;
                _lastDataReceived = DateTime.now(); 
              }

              _updateLastValues(telegram);
              if (!_dataStreamController.isClosed) _dataStreamController.add(telegram);
              if (!_dtcStreamController.isClosed) _dtcStreamController.add(telegram);
              if (!_mileageStreamController.isClosed) _mileageStreamController.add(telegram);
            }
          }
        },
        onError: (error) {
          _log("SOCKET ERROR: $error");
          _handleDisconnect();
        },
        onDone: () => _handleDisconnect(),
      );

      // Gérer le future 'done' pour éviter les crashs asynchrones (ex: SocketException au moment de l'écriture)
      _socket!.done.catchError((error) {
        _log("SOCKET DONE ASYNC ERROR: $error");
        _handleDisconnect();
      });

      // Initialisation Standard
      await sendCommandWait('ATZ', delay: 1200);   
      await sendCommandWait('ATE0', delay: 500);    
      await sendCommandWait('ATL0', delay: 500);    
      await sendCommandWait('ATH0', delay: 500);    
      await sendCommandWait('ATSP0', delay: 1000);  
      await sendCommandWait('0100', delay: 1000);   
      await sendCommandWait('ATSTFF', delay: 500); 

      _log("Scanner Mimo Spark prêt.");
      _isReconnecting = false;
      _lastDataReceived = DateTime.now();
      _startWatchdog();
      _startPolling();
      return true;
    } catch (e) {
      _log("CONNECTION FAILED: $e");
      if (!_isReconnecting) _isReconnecting = true;
      Future.delayed(const Duration(seconds: 5), () {
        if (_socket == null) connect();
      });
      return false;
    }
  }

  bool _isConfigResponse(String s) {
    final upper = s.toUpperCase();
    return upper == 'OK' || upper.startsWith('ELM327') || upper.startsWith('AT');
  }

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
          }
        }
      }
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

  bool _isPolling = false;

  void _startPolling() async {
    if (_isPolling) return;
    _isPolling = true;
    int tick = 0;
    while (_socket != null && _isPolling) {
      if (_isDiagnosticMode) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      try {
        sendCommand('010C'); // RPM
        await Future.delayed(const Duration(milliseconds: 450));
        sendCommand('010D'); // Speed
        await Future.delayed(const Duration(milliseconds: 450));
        if (tick % 5 == 0) {
          sendCommand('0105'); // Temp
          await Future.delayed(const Duration(milliseconds: 400));
        }
        if (tick % 10 == 0) {
          sendCommand('ATRV'); // Volts
          await Future.delayed(const Duration(milliseconds: 400));
        }
        tick++;
      } catch (e) {
        break;
      }
    }
  }

  void _handleDisconnect({bool autoReconnect = true}) {
    _heartbeatTimer?.cancel();
    try { _socket?.destroy(); } catch (_) {}
    _socket = null;
    _isPolling = false;
    _tcpBuffer = '';
    _noDataCount = 0;
    if (autoReconnect) {
      Future.delayed(const Duration(seconds: 5), () {
        if (_socket == null) connect();
      });
    }
  }

  Future<void> scanTroubleCodes() async {
    _isDiagnosticMode = true;
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand("03"); 
      await Future.delayed(const Duration(seconds: 3)); 
      sendCommand("07");
      await Future.delayed(const Duration(seconds: 3));
    } finally {
      _isDiagnosticMode = false;
    }
  }

  void sendCommand(String command) {
    if (_socket != null) {
      try {
        _socket!.write('$command\r');
      } catch (e) {
        _handleDisconnect();
      }
    } else {
      FlutterBackgroundService().invoke('sendCommand', {'command': command});
    }
  }

  void disconnect() {
    _log("Mimo Spark: Déconnexion manuelle demandée");
    _handleDisconnect(autoReconnect: false);
  }

  Future<File?> getLogFile() async {
    return _logFile;
  }

  Future<bool> clearCodes() async {
    _isDiagnosticMode = true;
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand("04"); // Effacer les codes défaut
      await Future.delayed(const Duration(seconds: 2));
      return true;
    } catch (e) {
      return false;
    } finally {
      _isDiagnosticMode = false;
    }
  }

  Future<void> scanMileage() async {
    _isDiagnosticMode = true;
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      // Mode 01 PID A6 pour Odometer (ou autre requête spécifique selon le véhicule)
      sendCommand("01A6"); 
      await Future.delayed(const Duration(seconds: 2));
    } finally {
      _isDiagnosticMode = false;
    }
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _handleDisconnect(autoReconnect: false);
    _dataStreamController.close();
    _dtcStreamController.close();
    _mileageStreamController.close();
  }
}
