import 'package:flutter/material.dart';
import '../core/dtc_database.dart';
import '../vocal/tts_service.dart';

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  final TtsService _ttsService = TtsService();
  List<String> _currentErrors = ['P0113', 'P0342', 'P0122']; // Simulated errors
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
    
    // Simulate OBD scan Mode 03
    await Future.delayed(const Duration(seconds: 2));
    
    setState(() {
      _isLoading = false;
      // We could add actual integration with ObdService here
    });

    if (_currentErrors.isNotEmpty) {
      _ttsService.speak("Mimo, l'analyse est terminée. J'ai trouvé ${_currentErrors.length} anomalies détectées. Veux-tu que j'efface les codes ?");
    } else {
      _ttsService.speak("Moteur sain, aucun nouveau code détecté.");
    }
  }

  void _clearDtc() {
    // Mode 04 clear codes
    setState(() {
      _currentErrors.clear();
    });
    _ttsService.speak("Codes effacés avec succès.");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analyse & Diagnostic')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.search),
                  label: const Text('Scan Mode 03'),
                  onPressed: _isLoading ? null : _scanDtc,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.delete),
                  label: const Text('Effacer (Clear DTC)'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _clearDtc,
                ),
              ],
            ),
          ),
          if (_isLoading) const CircularProgressIndicator(),
          Expanded(
            child: ListView.builder(
              itemCount: _currentErrors.length,
              itemBuilder: (context, index) {
                String code = _currentErrors[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    leading: const Icon(Icons.warning, color: Colors.orange),
                    title: Text(code, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(DtcDatabase.getDescription(code)),
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
