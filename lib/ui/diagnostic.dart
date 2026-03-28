import 'package:flutter/material.dart';
import '../core/dtc_database.dart';
import '../vocal/tts_service.dart';
import '../core/obd_service.dart';

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

  @override
  void initState() {
    super.initState();
    DtcDatabase.loadCodes();
  }

  void _scanDtc() async {
    setState(() {
      _isLoading = true;
    });
    
    _ttsService.speak("Lancement du scan Mode 03 sur la Spark.");
    
    // Connect and send 03
    bool connected = await _obdService.connect();
    if (!connected) {
      _ttsService.speak("Échec du scan. Boîtier Wi-Fi inaccessible.");
      setState(() => _isLoading = false);
      return;
    }

    _obdService.sendCommand('03');
    
    // Wait for response
    _obdService.dataStream.listen((data) {
      if (data.contains('43')) {
        // Parsing basic DTC (ex: 43 01 13 03 42)
        List<String> codes = [];
        List<String> parts = data.split(' ');
        for (int i = 1; i < parts.length - 1; i += 2) {
          if (parts[i] != '00') {
             codes.add('P${parts[i]}${parts[i+1]}');
          }
        }
        
        setState(() {
          _currentErrors = codes.toSet().toList(); // Unique codes
          _isLoading = false;
        });

        if (_currentErrors.isNotEmpty) {
          _ttsService.speak("Scan terminé Mimo. J'ai trouvé ${_currentErrors.length} anomalies.");
        } else {
          _ttsService.speak("Signal propre Mimo. Aucune erreur moteur.");
        }
      }
    });

    // Timeout safety
    Future.delayed(const Duration(seconds: 4), () {
      if (_isLoading) {
        setState(() => _isLoading = false);
        _ttsService.speak("Scan terminé. Tout semble normal, aucun code reçu.");
      }
    });
  }

  void _clearDtc() async {
    bool connected = await _obdService.connect();
    if (connected) {
      _obdService.sendCommand('04');
      _ttsService.speak("Commande Clear DTC envoyée Mimo. Le voyant devrait s'éteindre.");
      setState(() => _currentErrors.clear());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analyse DTC - Mimo Spark'), backgroundColor: Colors.black),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.search),
                  label: const Text('SCAN'),
                  onPressed: _isLoading ? null : _scanDtc,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.delete),
                  label: const Text('EFFACER'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _clearDtc,
                ),
              ],
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
