import 'package:flutter/material.dart';
import 'dart:async';
import '../vocal/tts_service.dart';
import '../core/obd_service.dart';

class MileagePage extends StatefulWidget {
  final ObdService obdService;
  const MileagePage({super.key, required this.obdService});

  @override
  State<MileagePage> createState() => _MileagePageState();
}

class _MileagePageState extends State<MileagePage> {
  final TtsService _ttsService = TtsService();
  final List<String> _results = [];
  bool _isLoading = false;
  StreamSubscription? _mileageSub;

  @override
  void initState() {
    super.initState();
    _mileageSub = widget.obdService.mileageStream.listen((data) {
      if (_isLoading) _parseCommand(data);
    });
  }

  @override
  void dispose() {
    _mileageSub?.cancel();
    super.dispose();
  }

  void _scanMileage() async {
    setState(() {
      _isLoading = true;
      _results.clear();
      _results.add("Début de l'audit kilométrage (Mode 22)...");
    });
    _ttsService.speak("Lancement de l'audit kilométrage approfondi.");
    
    await widget.obdService.scanMileage();

    if (mounted) {
      setState(() {
        _isLoading = false;
        _results.add("▶ Audit terminé.");
      });
      _ttsService.speak("Audit terminé. Vérifiez l'écran pour les résultats.");
    }
  }

  void _parseCommand(String data) {
    String raw = data.trim().toUpperCase();
    
    // Ignore NRC 7F for now
    if (raw.contains('7F')) return; 

    // Look for positive response 62 (response to 22)
    if (raw.contains('62 F1') || raw.contains('62 01') || raw.contains('62F1') || raw.contains('6201')) {
      // Nettoyage et formatage
      String hexPayload = raw.replaceAll(RegExp(r'[^0-9A-F]'), '');
      
      String decodedAscii = _decodeHexToAscii(hexPayload);
      int? decodedInt = _decodeHexToInt(hexPayload);

      String displayStr = "Réponse brute : $raw";
      if (decodedAscii.isNotEmpty && decodedAscii.length > 2) {
         displayStr += "\n▶ ASCII trouvé : $decodedAscii";
      }
      if (decodedInt != null && decodedInt > 0 && decodedInt < 1500000) {
         displayStr += "\n▶ Valeur numérique (km) probable : $decodedInt";
      }
      
      if (mounted) {
        setState(() {
          _results.add(displayStr);
        });
      }
    }
  }

  String _decodeHexToAscii(String hex) {
    try {
      String ascii = '';
      for (int i = 0; i < hex.length; i += 2) {
        if (i + 2 <= hex.length) {
          int charCode = int.parse(hex.substring(i, i + 2), radix: 16);
          if (charCode >= 32 && charCode <= 126) { // Printable ASCII
            ascii += String.fromCharCode(charCode);
          }
        }
      }
      return ascii;
    } catch (_) { return ''; }
  }

  int? _decodeHexToInt(String hex) {
    try {
      // Les réponses "62 F1 90 xx xx xx" (par ex. pour tester la conversion hex native)
      // 62F190 prend 6 caractères. On vérifie le payload derrière.
      int offset = hex.startsWith('62') ? 6 : 0;
      if (hex.length >= offset + 2) {
        String payload = hex.substring(offset);
        if (payload.isNotEmpty) {
          return int.parse(payload, radix: 16);
        }
      }
      return null;
    } catch (_) { return null; }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Mileage Analyzer PRO', style: TextStyle(color: Colors.greenAccent)),
        backgroundColor: Colors.transparent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
              child: const Text(
                'CET OUTIL TESTE PLUSIEURS REQUÊTES CONSTRUCTEURS POUR TENTER DE LIRE LE KILOMÉTRAGE CACHÉ DANS L\'ECU MOTEUR.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: _isLoading 
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.radar),
              label: Text(_isLoading ? 'SCAN EN COURS...' : 'LANCER L\'AUDIT KILOMÉTRAGE'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange[800], padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              onPressed: _isLoading ? null : _scanMileage,
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _results.isEmpty
                  ? const Center(child: Text("Appuyez sur LANCER pour débuter la recherche.\nLe processus testera différentes entêtes (7E0, 7E1...) pendant environ une minute.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, height: 1.5)))
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        return Card(
                          color: Colors.grey[900],
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _results[index],
                              style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontFamily: 'monospace'),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
