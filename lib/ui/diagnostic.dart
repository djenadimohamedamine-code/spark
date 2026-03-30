import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import '../core/dtc_database.dart';
import '../vocal/tts_service.dart';
import '../core/obd_service.dart';
import 'package:share_plus/share_plus.dart';

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  final TtsService _ttsService = TtsService();
  final ObdService _obdService = ObdService();
  List<String> _currentErrors = [];
  bool _isLoading = false;

  StreamSubscription? _obdSubscription;

  @override
  void initState() {
    super.initState();
    DtcDatabase.loadCodes();
    _obdSubscription = _obdService.dataStream.listen((data) {
      if (_isLoading) _parseDiagnosticData(data);
    });
  }

  @override
  void dispose() {
    _obdSubscription?.cancel();
    super.dispose();
  }

  void _scanDtc() async {
    setState(() {
      _isLoading = true;
      _currentErrors.clear();
    });
    _ttsService.speak("Lancement du scan Mode 03 sur la Spark.");
    await _obdService.scanTroubleCodes();
    
    // Attendre max 14 secondes (3 modes x 4s + marge)
    Future.delayed(const Duration(seconds: 14), () async {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
        if (_currentErrors.isEmpty) {
          _ttsService.speak("Scan terminé. Aucun code détecté. Consultez le journal.");
        } else {
          // Afficher la boîte de dialogue de confirmation
          _showClearConfirmDialog();
        }
      }
    });
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


  void _parseDiagnosticData(String data) {
    // 1. On garde les espaces pour séparer les octets (Critique pour Daewoo)
    String raw = data.trim().toUpperCase();

    // 2. Gestion du refus (NRC 7F)
    if (raw.contains('7F')) {
      if (mounted) {
        setState(() {
          _currentErrors.add('Refus ECU (7F) : Le scan nécessite que le moteur soit éteint avec le contact sur ON !');
          _isLoading = false;
        });
      }
      return;
    }

    // 3. Détection du mode (43, 47 ou 4A)
    if (raw.contains('43') || raw.contains('47') || raw.contains('4A')) {
      try {
        List<String> codesTrouves = [];
        // On split par espace pour avoir chaque octet [43, 01, 07, 01, 13...]
        List<String> parts = raw.split(RegExp(r'\s+'));
        
        int startIndex = parts.indexWhere((p) => p == '43' || p == '47' || p == '4A');
        
        if (startIndex != -1) {
          // On parcourt les octets deux par deux après le mode
          for (int i = startIndex + 1; i + 1 < parts.length; i += 2) {
            String highByte = parts[i];
            String lowByte = parts[i+1];
            
            // On ignore 00 00 et on vérifie qu'on n'est pas sur un ">" ou autre
            if (highByte.length == 2 && lowByte.length == 2) {
              if (highByte != '00' || lowByte != '00') {
                codesTrouves.add('P$highByte$lowByte');
              }
            }
          }
        }

        if (mounted && codesTrouves.isNotEmpty) {
          setState(() {
            _currentErrors.addAll(codesTrouves);
            _currentErrors = _currentErrors.toSet().toList(); // Supprime les doublons
            _isLoading = false;
          });
          _ttsService.speak("Mimo, j'ai trouvé ${codesTrouves.length} pannes.");
        }
      } catch (e) {
        print('Erreur Parsing DTC: $e');
        if (mounted) setState(() => _isLoading = false);
      }
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
      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(logFile.path)], text: 'Journal de bord Mimo Spark OBD2');
    } else {
      _ttsService.speak('Aucun journal de bord disponible.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analyse DTC - Mimo Spark'),
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
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.search),
                    label: const Text('SCAN'),
                    onPressed: _isLoading ? null : _scanDtc,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.history),
                    label: const Text('LOG'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[800]),
                    onPressed: _lireBoiteNoire,
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.delete),
                    label: const Text('EFFACER'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[900]),
                    onPressed: _clearDtc,
                  ),
                ],
              ),
            ),
          ),
          if (_isLoading) const Padding(
            padding: EdgeInsets.all(8.0),
            child: CircularProgressIndicator(color: Colors.white),
          ),
          Expanded(
            child: _currentErrors.isEmpty
                ? const Center(
                    child: Text(
                      'Aucun code — Appuyez sur SCAN\nou consultez le LOG pour diagnostiquer.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _currentErrors.length,
                    itemBuilder: (context, index) {
                      String code = _currentErrors[index];
                      bool isNrc = code.startsWith('NRC:');
                      return Card(
                        color: isNrc ? Colors.red[900] : Colors.grey[900],
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: ListTile(
                          leading: Icon(
                            isNrc ? Icons.block : Icons.warning,
                            color: isNrc ? Colors.red[300] : Colors.orange,
                          ),
                          title: Text(code, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13)),
                          subtitle: isNrc
                              ? const Text('ECU a refusé la commande. Voir LOG pour détails.', style: TextStyle(color: Colors.red))
                              : Text(DtcDatabase.getDescription(code), style: const TextStyle(color: Colors.grey)),
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
