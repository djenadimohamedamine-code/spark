import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'dtc_scanner.dart';

class ObdService {
  static final ObdService _instance = ObdService._internal();
  factory ObdService() => _instance;
  ObdService._internal();

  // --- Protocole OBD détecté (CAN vs K-Line) ---
  ObdProtocolType detectedProtocol = ObdProtocolType.auto;
  String detectedProtocolName = 'AUTO';
  String? _savedProtocol;
  String? get savedProtocol => _savedProtocol;

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
  bool _isManualDisconnect = false;
  int _noDataCount = 0;
  int _unableCount = 0;
  int _savedProtocolFailureCount = 0;
  Timer? _heartbeatTimer;
  Timer? _retryTimer;
  DateTime _lastDataReceived = DateTime.now();
  bool _isDiagnosticMode = false;

  void _scheduleRetry() {
    if (_isManualDisconnect) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 4), () {
      if (_socket == null && !_isManualDisconnect) {
        _log("MIMO_OBD: 🔄 Tentative de reconnexion automatique (retry timer 4s)...");
        connect(isReconnect: true);
      }
    });
  }

  // --- Getter public : permet au dashboard de lire l'âge des données ---
  // Utilisé pour décider si une reconnexion est nécessaire au retour de
  // l'arrière-plan, sans envoyer de commande ELM327 en parallèle du polling.
  DateTime get lastDataReceived => _lastDataReceived;

  /// Retourne true si la socket existe ET a reçu des données dans les
  /// [maxAgeSeconds] dernières secondes.
  /// Ne fait aucune écriture réseau — lecture seule du timestamp.
  bool checkConnectionHealth({int maxAgeSeconds = 8}) {
    if (_socket == null) return false;
    final age = DateTime.now().difference(_lastDataReceived).inSeconds;
    return age <= maxAgeSeconds;
  }

  /// Retourne true si des données fraîches ont été reçues depuis [since].
  bool hasReceivedDataSince(DateTime since) {
    if (_socket == null) return false;
    return _lastDataReceived.isAfter(since);
  }

  // --- Watchdog Intelligent (Version 5.1) ---
  void _startWatchdog() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (t) {
      if (_socket == null) { t.cancel(); return; }

      final secondsSinceLastData = DateTime.now().difference(_lastDataReceived).inSeconds;
      
      // Sécurité 1 : Reconnexion si mort depuis 15 secondes (au lieu de 30s)
      if (secondsSinceLastData > 15 && !_isDiagnosticMode && _isPolling) {
        _log('WATCHDOG: Silence radio (15s) -> Reconnexion automatique');
        t.cancel();
        _handleDisconnect();
        return;
      }
      
      // Sécurité 2 : Heartbeat léger (seulement si silence > 4s)
      if (secondsSinceLastData > 4 && !_isDiagnosticMode) {
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
    _log("MIMO_OBD: Reconnexion forcée demandée");
    _isManualDisconnect = false;
    _retryTimer?.cancel();
    _handleDisconnect(autoReconnect: true);
  }

  Completer<String>? _promptCompleter;

  /// Envoie une commande AT ou PID et attend activement l'arrivée du prompt '>'
  /// de l'ELM327. Évite d'interrompre l'adaptateur pendant sa négociation de protocole.
  Future<String> sendCommandWaitPrompt(String cmd, {Duration timeout = const Duration(seconds: 4)}) async {
    if (_socket == null) return '';
    _promptCompleter?.completeError('cancelled');
    final completer = Completer<String>();
    _promptCompleter = completer;
    sendCommand(cmd);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => '');
    } catch (_) {
      return '';
    } finally {
      if (_promptCompleter == completer) {
        _promptCompleter = null;
      }
    }
  }

  Future<void> _wakeUpEcu() async {
    if (_isDiagnosticMode) return;
    _isDiagnosticMode = true;
    _log("MIMO_OBD: Réveil ECU & réinitialisation protocoles (Warm Start)...");
    try {
      await sendCommandWaitPrompt('\r', timeout: const Duration(milliseconds: 500));
      _tcpBuffer = '';
      await sendCommandWaitPrompt('ATWS', timeout: const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 200));
      _tcpBuffer = '';
      await sendCommandWaitPrompt('ATE0', timeout: const Duration(seconds: 1));
      await sendCommandWaitPrompt('ATL0', timeout: const Duration(seconds: 1));
      await sendCommandWaitPrompt('ATS0', timeout: const Duration(seconds: 1));
      await sendCommandWaitPrompt('ATH0', timeout: const Duration(seconds: 1));
      if (_savedProtocol != null) {
        await sendCommandWaitPrompt('ATSP$_savedProtocol', timeout: const Duration(seconds: 2));
      }
      await sendCommandWaitPrompt('0100', timeout: const Duration(seconds: 5));
    } catch (e) {
      _log("MIMO_OBD: Erreur réveil ECU: $e -> Reconnexion complète");
      forceReconnect();
    } finally {
      _isDiagnosticMode = false;
      _noDataCount = 0;
      _unableCount = 0;
    }
  }

  void _setupSocketListeners() {
    _tcpBuffer = '';
    _socket!.listen(
      (List<int> event) {
        final String chunk = String.fromCharCodes(event);
        _tcpBuffer += chunk;

        while (_tcpBuffer.contains('>')) {
          int promptIdx = _tcpBuffer.indexOf('>');
          String frame = _tcpBuffer.substring(0, promptIdx);
          _tcpBuffer = _tcpBuffer.substring(promptIdx + 1);

          // Débloque l'attente du prompt '>' pour les commandes d'initialisation
          if (_promptCompleter != null && !_promptCompleter!.isCompleted) {
            _promptCompleter!.complete(frame.trim());
            _promptCompleter = null;
          }

          // En mode diagnostic, diffuser le bloc de trame complet pour l'assembleur ISO-TP
          if (_isDiagnosticMode && !_dtcStreamController.isClosed) {
            _dtcStreamController.add(frame.trim());
          }

          List<String> lines = frame.split(RegExp(r'[\r\n]+'));
          for (String line in lines) {
            String telegram = line.trim();
            if (telegram.isEmpty) continue;

            // Détection dynamique du protocole véhicule (CAN vs K-Line)
            final upper = telegram.toUpperCase();
            if (upper.contains('CAN') || upper.contains('ISO 15765')) {
              detectedProtocol = ObdProtocolType.can;
              detectedProtocolName = telegram;
              _log("MIMO_OBD: Protocole détecté -> CAN ($telegram)");
            } else if (upper.contains('KWP') || upper.contains('ISO 14230') || upper.contains('ISO 9141')) {
              detectedProtocol = ObdProtocolType.kline;
              detectedProtocolName = telegram;
              _log("MIMO_OBD: Protocole détecté -> K-Line ($telegram)");
            }

            if (_isConfigResponse(telegram)) continue;
            
            final isErrorTelegram = telegram.contains('NO DATA') ||
                telegram.contains('UNABLE TO CONNECT') ||
                telegram.contains('BUS INIT') ||
                telegram.contains('CAN ERROR') ||
                telegram.contains('ERROR');

            if (isErrorTelegram) {
              if (telegram.contains('UNABLE TO CONNECT') || telegram.contains('BUS INIT')) {
                _unableCount++;
                _log("MIMO_OBD: Perte liaison ECU détectée ($telegram, count: $_unableCount)");
                if (!_isDiagnosticMode) {
                  if (_unableCount == 1) {
                    _wakeUpEcu();
                  } else {
                    _unableCount = 0;
                    _log("MIMO_OBD: 'UNABLE TO CONNECT' persistant -> Reconnexion socket complète");
                    forceReconnect();
                    return;
                  }
                }
              } else {
                _noDataCount++;
                if (_noDataCount >= 4 && !_isDiagnosticMode) {
                  _wakeUpEcu();
                }
              }
            } else if (telegram.length >= 4) {
              _noDataCount = 0;
              _unableCount = 0;
              _lastDataReceived = DateTime.now(); 
            }

            _updateLastValues(telegram);
            if (!_dataStreamController.isClosed) _dataStreamController.add(telegram);
            if (!_isDiagnosticMode && !_dtcStreamController.isClosed) _dtcStreamController.add(telegram);
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
  }

  Future<bool> _initializeElm327({bool isReconnect = false}) async {
    _tcpBuffer = '';

    // CAS 1 : Reconnexion / retour d'arrière-plan avec protocole mémorisé -> Warm Start (ATWS)
    if ((isReconnect || _savedProtocol != null) && _savedProtocol != null) {
      _log("MIMO_OBD: 🔄 Reconnexion rapide (ATWS) avec protocole mémorisé ATSP$_savedProtocol...");
      await sendCommandWaitPrompt('\r', timeout: const Duration(milliseconds: 500));
      _tcpBuffer = '';
      await sendCommandWaitPrompt('ATWS', timeout: const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 200));
      _tcpBuffer = '';
      await sendCommandWaitPrompt('ATE0', timeout: const Duration(seconds: 1));
      await sendCommandWaitPrompt('ATL0', timeout: const Duration(seconds: 1));
      await sendCommandWaitPrompt('ATH0', timeout: const Duration(seconds: 1));
      await sendCommandWaitPrompt('ATSTFF', timeout: const Duration(seconds: 1));
      await sendCommandWaitPrompt('ATSP$_savedProtocol', timeout: const Duration(seconds: 2));
      final res = await sendCommandWaitPrompt('0100', timeout: const Duration(seconds: 5));
      if (res.contains('UNABLE') || res.contains('ERROR')) {
        _savedProtocolFailureCount++;
        _log("MIMO_OBD: Échec avec protocole mémorisé ($_savedProtocol, tentative $_savedProtocolFailureCount/3)");
        if (_savedProtocolFailureCount >= 3) {
          _log("MIMO_OBD: 3 échecs consécutifs -> Réinitialisation protocole mémorisé (retour ATSP0)");
          _savedProtocol = null;
          _savedProtocolFailureCount = 0;
        }
        return false;
      }
      _savedProtocolFailureCount = 0;
      return true;
    }

    // CAS 2 : Premier démarrage à froid -> Initialisation complète (ATZ + ATSP0 + mémorisation ATDPN)
    _log("MIMO_OBD: Initialisation complète à froid (ATZ)...");
    await sendCommandWaitPrompt('ATZ', timeout: const Duration(seconds: 2));
    await Future.delayed(const Duration(milliseconds: 500));
    _tcpBuffer = '';
    await sendCommandWaitPrompt('ATE0', timeout: const Duration(seconds: 1));
    await sendCommandWaitPrompt('ATL0', timeout: const Duration(seconds: 1));
    await sendCommandWaitPrompt('ATH0', timeout: const Duration(seconds: 1));
    await sendCommandWaitPrompt('ATSP0', timeout: const Duration(seconds: 2));
    final initResp = await sendCommandWaitPrompt('0100', timeout: const Duration(seconds: 8));

    if (initResp.contains('UNABLE') || initResp.contains('ERROR')) {
      _log("MIMO_OBD: Échec négociation protocole initiale (0100 -> $initResp)");
      return false;
    }

    // Lecture du protocole exact avec ATDPN
    final dpnRaw = await sendCommandWaitPrompt('ATDPN', timeout: const Duration(seconds: 2));
    _log("MIMO_OBD: Réponse ATDPN = '$dpnRaw'");
    String cleaned = dpnRaw.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
    if (cleaned.startsWith('A') && cleaned.length > 1) {
      cleaned = cleaned.substring(1);
    }
    if (cleaned.isNotEmpty) {
      _savedProtocol = cleaned[0];
      _savedProtocolFailureCount = 0;
      _log("MIMO_OBD: ✅ Protocole Spark mémorisé -> ATSP$_savedProtocol (DPN: $dpnRaw)");
    }

    await sendCommandWaitPrompt('ATDP', timeout: const Duration(seconds: 2));
    await sendCommandWaitPrompt('ATSTFF', timeout: const Duration(seconds: 1));
    return true;
  }

  Future<bool> connect({bool isReconnect = false, int maxRetries = 3}) async {
    _isManualDisconnect = false;
    _retryTimer?.cancel();
    _retryTimer = null;

    if (_isReconnecting) {
      _log("MIMO_OBD: Connexion déjà en cours — appel ignoré.");
      return false;
    }
    _isReconnecting = true;
    await _initLogFile();

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        _log("MIMO_OBD: Tentative connexion Socket ($attempt/$maxRetries)...");
        
        // Nettoyage socket résiduelle
        _heartbeatTimer?.cancel();
        try { _socket?.destroy(); } catch (_) {}
        _socket = null;
        _isPolling = false;

        String? wifiIp;
        try {
          wifiIp = await NetworkInfo().getWifiIP();
          _log("MIMO_OBD: IP WiFi locale = $wifiIp");
        } catch (_) {}

        try {
          _socket = await Socket.connect(
            ip, 
            port, 
            timeout: const Duration(seconds: 2),
            sourceAddress: wifiIp,
          );
        } catch (e) {
          _log("MIMO_OBD: Connexion directe sans sourceAddress (fallback)...");
          _socket = await Socket.connect(
            ip, 
            port, 
            timeout: const Duration(seconds: 2),
          );
        }
        _socket!.setOption(SocketOption.tcpNoDelay, true);

        _setupSocketListeners();

        bool initOk = await _initializeElm327(isReconnect: isReconnect);
        if (initOk) {
          _log("Scanner MIMO_OBD prêt.");
          _retryTimer?.cancel();
          _retryTimer = null;
          _isReconnecting = false;
          _lastDataReceived = DateTime.now();
          _startWatchdog();
          _startPolling();
          return true;
        } else {
          _log("MIMO_OBD: Échec initialisation ELM327 (tentative $attempt)");
        }
      } catch (e) {
        _log("CONNECTION FAILED ($attempt/$maxRetries): $e");
      }

      _heartbeatTimer?.cancel();
      try { _socket?.destroy(); } catch (_) {}
      _socket = null;
      _isPolling = false;

      if (attempt < maxRetries) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    _isReconnecting = false;
    if (!_isManualDisconnect && _socket == null) {
      _scheduleRetry();
    }
    return false;
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
        await Future.delayed(const Duration(milliseconds: 300));
        sendCommand('010D'); // Speed
        await Future.delayed(const Duration(milliseconds: 300));
        sendCommand('010B'); // MAP (pour Carburant)
        await Future.delayed(const Duration(milliseconds: 300));
        if (tick % 3 == 0) {
          sendCommand('0111'); // TPS (Papillon)
          await Future.delayed(const Duration(milliseconds: 300));
          sendCommand('0104'); // Charge moteur
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (tick % 5 == 0) {
          sendCommand('0105'); // Temp
          await Future.delayed(const Duration(milliseconds: 350));
          sendCommand('010F'); // IAT
          await Future.delayed(const Duration(milliseconds: 350));
        }
        if (tick % 7 == 0) {
          sendCommand('0106'); // Short Fuel Trim
          await Future.delayed(const Duration(milliseconds: 350));
          sendCommand('0107'); // Long Fuel Trim
          await Future.delayed(const Duration(milliseconds: 350));
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
    _unableCount = 0;
    if (autoReconnect && !_isManualDisconnect) {
      _scheduleRetry();
    }
  }

  Future<void> scanTroubleCodes() async {
    _isDiagnosticMode = true;
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      sendCommand("03"); 
      await Future.delayed(const Duration(seconds: 2)); 
      sendCommand("07");
      await Future.delayed(const Duration(seconds: 2));
      sendCommand("0A");
      await Future.delayed(const Duration(seconds: 2));
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
    }
    // Si pas de socket, on ignore silencieusement (pas de fallback background service)
  }

  void disconnect() {
    _log("MIMO_OBD: Déconnexion manuelle demandée");
    _isManualDisconnect = true;
    _retryTimer?.cancel();
    _retryTimer = null;
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
    _isManualDisconnect = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _heartbeatTimer?.cancel();
    _handleDisconnect(autoReconnect: false);
    _dataStreamController.close();
    _dtcStreamController.close();
    _mileageStreamController.close();
  }
}
