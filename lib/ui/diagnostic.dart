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
  bool _isLoading = false;

  StreamSubscription? _dtcSubscription;

  @override
  void initState() {
    super.initState();
    DtcDatabase.loadCodes();
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

  void _scanDtc() async {
    setState(() {
      _isLoading = true;
      _currentErrors.clear();
    });
    _ttsService.speak("Lancement du scan Mode 03 sur la Spark.");
    await _obdService.scanTroubleCodes();

    // Attendre max 14 secondes (3 modes × 5 s + marge)
    Future.delayed(const Duration(seconds: 14), () async {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
        if (_currentErrors.isEmpty) {
          _ttsService.speak("Scan terminé. Aucun code détecté. Consultez le journal.");
        } else {
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

  // ── Parsing DTC ──────────────────────────────────────────────────────────
  void _parseDiagnosticData(String data) {
    // CRITIQUE : on garde les espaces — ils séparent les octets pour Daewoo KWP2000
    // NE JAMAIS faire replaceAll(' ', '') ← ce serait fatal pour le parsing
    String raw = data.trim().toUpperCase();

    // Séparer par espaces pour avoir les octets isolés
    List<String> parts = raw.split(RegExp(r'\s+'));

    // Gestion du refus ECU (NRC 7F) : le 7F doit être un octet isolé
    if (parts.contains('7F')) {
      if (mounted) {
        setState(() {
          _currentErrors.add('Refus ECU (7F) : Contact ON, moteur éteint requis !');
          _isLoading = false;
        });
      }
      return;
    }

    // Détection réponse DTC : le marqueur de mode DOIT être un token exact isolé
    // '43' = réponse Mode 03, '47' = Mode 07, '4A' = Mode 0A
    // IMPORTANT : on NE fait PAS raw.contains('43') car cela fausse des réponses
    // PID normales comme "41 0C 10 43 BA" (RPM qui contient '43' en valeur de données)
    int startIndex = parts.indexWhere((p) => p == '43' || p == '47' || p == '4A');
    if (startIndex == -1) return; // Pas de marqueur DTC → ignorer

    try {
      List<String> codesTrouves = [];

      // Parcourir les octets deux par deux après le marqueur de mode
      for (int i = startIndex + 1; i + 1 < parts.length; i += 2) {
        String highByte = parts[i];
        String lowByte = parts[i + 1];

        // Valider : exactement 2 caractères hex chacun
        if (highByte.length != 2 || lowByte.length != 2) continue;
        // 00 00 = terminateur de liste OBD2
        if (highByte == '00' && lowByte == '00') break;

        // Conversion octet → code DTC standard (P/C/B/U + 4 chiffres)
        String obdCode = _convertBytesToDtc(highByte, lowByte);
        if (obdCode.isNotEmpty) codesTrouves.add(obdCode);
      }

      if (mounted && codesTrouves.isNotEmpty) {
        setState(() {
          _currentErrors.addAll(codesTrouves);
          _currentErrors = _currentErrors.toSet().toList();
          _isLoading = false;
        });
        _ttsService.speak("Mimo, j'ai trouvé ${codesTrouves.length} panne${codesTrouves.length > 1 ? 's' : ''}.");
      }
    } catch (e) {
      print('Erreur Parsing DTC: $e');
      if (mounted) setState(() => _isLoading = false);
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
        title: const Text('Analyse DTC — Mimo Spark V4.29'),
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
            child: _currentErrors.isEmpty
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
                    itemCount: _currentErrors.length,
                    itemBuilder: (context, index) {
                      String code = _currentErrors[index];
                      bool isNrc = code.startsWith('Refus ECU');
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
                              ? const Text('ECU a refusé la commande. Voir LOG.', style: TextStyle(color: Colors.redAccent))
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
