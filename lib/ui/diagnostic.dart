import 'package:flutter/material.dart';
import 'dart:async';
import '../core/dtc_database.dart';
import '../vocal/tts_service.dart';
import '../core/obd_service.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

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
    // Écoute permanente mais filtrée pour Mimo
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
    
    // On utilise la méthode blindée du service
    await _obdService.scanTroubleCodes();
    
    // Timeout safety
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
        _ttsService.speak("Scan terminé. Tout semble normal, aucun code reçu.");
      }
    });
  }

  void _parseDiagnosticData(String data) {
    // Nettoyage radical Mimo Style (ne garde que lettres et chiffres)
    String cleanData = data.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    
    // On ignore les réponses négatives (NRC 7F)
    if (cleanData.contains('7F')) return;

    // Modes supportés : 43 (03), 47 (07), 4A (0A)
    if (cleanData.contains('43') || cleanData.contains('47') || cleanData.contains('4A')) {
      try {
        String identifier = "";
        if (cleanData.contains('43')) identifier = '43';
        else if (cleanData.contains('47')) identifier = '47';
        else if (cleanData.contains('4A')) identifier = '4A';
        
        List<String> codes = [];
        
        // On isole tout ce qui suit l'identifiant
        String payload = cleanData.substring(cleanData.indexOf(identifier) + 2);
        
        // On découpe par blocs de 4 caractères
        for (int i = 0; i + 4 <= payload.length; i += 4) {
          String codeHex = payload.substring(i, i + 4);
          if (codeHex != "0000" && codeHex.length == 4) {
            codes.add("P$codeHex");
          }
        }
        
        if (mounted) {
          setState(() {
            _currentErrors.addAll(codes);
            _currentErrors = _currentErrors.toSet().toList(); // Unique codes
            _isLoading = false;
          });

          if (_currentErrors.isNotEmpty && (identifier == '47' || identifier == '4A')) {
           _ttsService.speak("Mimo, j'ai trouvé des anomalies supplémentaires.");
          }
        }
      } catch (e) {
        print("Erreur Parsing DTC: $e");
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

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
        // On affiche les 30 dernières lignes pour le diagnostic précis (Mimo Style)
        String finDuLog = lignes.length > 30 
            ? lignes.sublist(lignes.length - 30).join('\n') 
            : contenu;

        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              title: const Text("Boîte Noire Mimo Spark", style: TextStyle(color: Colors.blueAccent, fontSize: 16)),
              content: SingleChildScrollView(
                child: Text(finDuLog, style: const TextStyle(fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace')),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context), 
                  child: const Text("FERMER", style: TextStyle(color: Colors.white))
                )
              ],
            ),
          );
        }
      } else {
        _ttsService.speak("Mimo, le journal est vide.");
      }
    } catch (e) {
      print("Erreur lecture log: $e");
    }
  }

  void _shareLog() async {
    File? logFile = await _obdService.getLogFile();
    if (logFile != null) {
      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(logFile.path)], text: 'Journal de bord Mimo Spark OBD2');
    } else {
      _ttsService.speak("Aucun journal de bord disponible.");
    }
  }

  void _clearDtc() async {
    _obdService.clearCodes();
    setState(() => _currentErrors.clear());
    _ttsService.speak("Effacement en cours Mimo. Regarde le voyant moteur.");
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
            tooltip: "Exporter le Log",
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
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
          if (_isLoading) const CircularProgressIndicator(color: Colors.white),
          Expanded(
            child: ListView.builder(
              itemCount: _currentErrors.length,
              itemBuilder: (context, index) {
                String code = _currentErrors[index];
                return Card(
                  color: Colors.grey[900],
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    leading: const Icon(Icons.warning, color: Colors.orange),
                    title: Text(code, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    subtitle: Text(DtcDatabase.getDescription(code), style: const TextStyle(color: Colors.grey)),
                  ),
                );
              },
            ),
          )
        ],
      ),
    );
  }
}
