import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import '../core/dtc_database.dart';
import '../vocal/tts_service.dart';
import '../core/obd_service.dart';
import 'package:share_plus/share_plus.dart';

class DiagnosticPage extends StatefulWidget {
  /// L'instance ObdService partagée avec le Dashboard (déjà connectée)
  final ObdService obdService;
  const DiagnosticPage({super.key, required this.obdService});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  final TtsService _ttsService = TtsService();
  // Utilise l'obdService partagé via widget.obdService (déjà connecté)
  ObdService get _obdService => widget.obdService;
  List<String> _currentErrors = [];
  List<Map<String, String>> _resolvedErrors = [];
  bool _isLoading = false;

  StreamSubscription? _dtcSubscription;

  @override
  void initState() {
    super.initState();
    _loadDtcDb();
    // On écoute le flux DTC dédié, pas le flux jauges général
    _dtcSubscription = _obdService.dtcStream.listen((data) {
      if (_isLoading) _parseDiagnosticData(data);
    });
  }

  @override
  void dispose() {
    _dtcSubscription?.cancel();
    // NE PAS appeler _obdService.dispose() — il appartient au Dashboard
    super.dispose();
  }

  Future<void> _loadDtcDb() async {
    await DtcDatabase.loadCodes();
  }

  void _scanDtc() async {
    setState(() {
      _isLoading = true;
      _currentErrors.clear();
      _resolvedErrors.clear();
    });
    _ttsService.speak("Lancement du diagnostic expert Mimo Spark.");
    
    // Attente dynamique du scan (Plus rapide et précis)
    await _obdService.scanTroubleCodes();

    // Résolution asynchrone des codes trouvés
    final resolved = await DtcDatabase.resolveAll(_currentErrors);

    if (mounted) {
      setState(() {
        _isLoading = false;
        _resolvedErrors = resolved;
      });
      
      if (_resolvedErrors.isEmpty) {
        _ttsService.speak("Diagnostic terminé. Aucun code d'erreur trouvé.");
      } else {
        _showClearConfirmDialog();
      }
    }
  }

  void _showClearConfirmDialog() {
    _ttsService.speak("Mimo, j'ai trouvé des pannes. Veux-tu les effacer ?");
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange, size: 28),
            SizedBox(width: 8),
            Text('Codes Panne Détectés', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Que veux-tu faire avec ces codes ?', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 12),
            const Text('⚠️  EFFACER = éteint le voyant moteur', style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
            const SizedBox(height: 4),
            const Text('📋  GARDER = les montrer au mécanicien', style: TextStyle(color: Colors.lightBlueAccent, fontSize: 12)),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.delete_forever, color: Colors.red),
            label: const Text('EFFACER', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            onPressed: () {
              Navigator.pop(ctx);
              _clearDtc();
            },
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.assignment, color: Colors.white),
            label: const Text('GARDER', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[700]),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  // ── Parsing DTC Expert (ISO-TP + NRC) ───────────────────────────────────
  static const Map<String, String> _nrcMap = {
    '10': 'General Reject',
    '11': 'Service Not Supported',
    '12': 'SubFunction Not Supported',
    '13': 'Incorrect Message Length',
    '21': 'Busy - Repeat Request',
    '22': 'Conditions Not Correct (Check Ignition)',
    '31': 'Request Out Of Range',
    '33': 'Security Access Denied',
    '78': 'Response Pending',
  };

  void _parseDiagnosticData(String data) {
    String raw = data.trim().toUpperCase();
    List<String> parts = raw.split(RegExp(r'\s+'));

    // 1. Détection NRC (7F) avec décodage expert
    if (parts.contains('7F')) {
      int idx = parts.indexOf('7F');
      if (idx + 2 < parts.length) {
        String service = parts[idx + 1];
        String reason = parts[idx + 2];
        String desc = _nrcMap[reason] ?? 'Unknown Error $reason';
        if (mounted) {
          setState(() {
            _currentErrors.add('ECU Refus (7F $service) : $desc');
          });
        }
      }
      return;
    }

    // 2. Détection ISO-TP (Multi-frame)
    // On ignore les octets de contrôle 10 (First Frame) et 21 (Consecutive)
    // On cherche les marqueurs 43, 47, 4A (DTC Responses)
    int markerIdx = parts.indexWhere((p) => p == '43' || p == '47' || p == '4A');
    if (markerIdx == -1) return;

    try {
      List<String> codesTrouves = [];
      
      // On commence après le marqueur 43/47/4A
      for (int i = markerIdx + 1; i + 1 < parts.length; i += 2) {
        String highByte = parts[i];
        String lowByte = parts[i + 1];

        // Ignorer les octets de contrôle CAN (21, 22...) s'ils apparaissent entre les paires
        if (highByte.length != 2 || lowByte.length != 2) continue;
        if (highByte == '00' && lowByte == '00') continue; // On continue au lieu de break (expert point 4)

        // Si l'octet ressemble à un index de frame ISO-TP (21 à 2F), on le saute
        int? val = int.tryParse(highByte, radix: 16);
        if (val != null && val >= 0x21 && val <= 0x2F) {
           i -= 1; // On décale pour reprendre la vraie paire de données DTC
           continue;
        }

        String obdCode = _convertBytesToDtc(highByte, lowByte);
        if (obdCode.isNotEmpty && obdCode != "P0000") codesTrouves.add(obdCode);
      }

      if (mounted && codesTrouves.isNotEmpty) {
        setState(() {
          _currentErrors.addAll(codesTrouves);
          _currentErrors = _currentErrors.toSet().toList();
        });
      }
    } catch (e) {
      // Sourd
    }
  }

  /// Convertit deux octets hex en code DTC standard OBD2
  /// Ex: "01" "13" → "P0113"
  String _convertBytesToDtc(String highHex, String lowHex) {
    try {
      int firstByte = int.parse(highHex, radix: 16);
      int prefixBits = (firstByte & 0xC0) >> 6;
      String letter;
      switch (prefixBits) {
        case 0: letter = 'P'; break;
        case 1: letter = 'C'; break;
        case 2: letter = 'B'; break;
        case 3: letter = 'U'; break;
        default: letter = 'P';
      }
      // Les 4 chiffres après la lettre
      String nibble1 = ((firstByte & 0x30) >> 4).toRadixString(16).toUpperCase();
      String nibble2 = (firstByte & 0x0F).toRadixString(16).toUpperCase();
      return '$letter$nibble1$nibble2${lowHex.toUpperCase()}';
    } catch (_) {
      return '';
    }
  }

  void _clearDtc() async {
    _obdService.clearCodes();
    setState(() => _currentErrors.clear());
    _ttsService.speak("Effacement en cours Mimo. Regarde le voyant moteur.");
  }

  void _lireBoiteNoire() async {
    try {
      File? file = await _obdService.getLogFile();
      if (file != null && await file.exists()) {
        String contenu = await file.readAsString();
        List<String> lignes = contenu.split('\n');
        String finDuLog = lignes.length > 30
            ? lignes.sublist(lignes.length - 30).join('\n')
            : contenu;

        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              title: const Text('Boîte Noire Mimo Spark', style: TextStyle(color: Colors.blueAccent, fontSize: 16)),
              content: SingleChildScrollView(
                child: Text(finDuLog, style: const TextStyle(fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace')),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('FERMER', style: TextStyle(color: Colors.white)),
                )
              ],
            ),
          );
        }
      } else {
        _ttsService.speak('Mimo, le journal est vide.');
      }
    } catch (e) {
      print('Erreur lecture log: $e');
    }
  }

  void _shareLog() async {
    File? logFile = await _obdService.getLogFile();
    if (logFile != null) {
      await Share.shareXFiles([XFile(logFile.path)], text: 'Journal de bord Mimo Spark OBD2');
    } else {
      _ttsService.speak('Aucun journal de bord disponible.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analyse DTC — Mimo Spark V4.31'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Colors.blue),
            onPressed: _shareLog,
            tooltip: 'Exporter le Log',
          )
        ],
      ),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // Barre de boutons
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ElevatedButton.icon(
                    icon: _isLoading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.search),
                    label: Text(_isLoading ? 'SCAN EN COURS...' : 'SCAN DTC'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[800]),
                    onPressed: _isLoading ? null : _scanDtc,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.history),
                    label: const Text('LOG'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[900]),
                    onPressed: _lireBoiteNoire,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.delete),
                    label: const Text('EFFACER'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[900]),
                    onPressed: _currentErrors.isEmpty ? null : _clearDtc,
                  ),
                ],
              ),
            ),
          ),

          // Zone de résultats
          Expanded(
            child: _resolvedErrors.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isLoading) ...[
                          const CircularProgressIndicator(color: Colors.cyanAccent),
                          const SizedBox(height: 16),
                          const Text('Scan en cours…\nAttente de réponse ECU', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                        ] else ...[
                          const Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 48),
                          const SizedBox(height: 12),
                          const Text(
                            'Aucun code détecté\nAppuyez sur SCAN DTC ou consultez le LOG',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        ]
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _resolvedErrors.length,
                    itemBuilder: (context, index) {
                      final item = _resolvedErrors[index];
                      String code = item['code'] ?? 'UNK';
                      String msg = item['msg'] ?? '...';
                      String sev = item['sev'] ?? 'info';
                      
                      bool isNrc = code.startsWith('ECU Refus');
                      Color textColor = sev == 'critique' ? Colors.redAccent : (sev == 'alerte' ? Colors.orangeAccent : Colors.grey);

                      return Card(
                        color: isNrc || sev == 'critique' ? const Color(0xFF2A0000) : const Color(0xFF1A1A1A),
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: isNrc ? Colors.red : Colors.white10)),
                        child: ListTile(
                          leading: Icon(
                            isNrc || sev == 'critique' ? Icons.report_problem : (sev == 'alerte' ? Icons.warning : Icons.info_outline),
                            color: isNrc || sev == 'critique' ? Colors.red : (sev == 'alerte' ? Colors.orange : Colors.blueGrey),
                          ),
                          title: Text(code, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13, letterSpacing: 1.1)),
                          subtitle: Text(msg, style: TextStyle(color: textColor, fontSize: 12)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
