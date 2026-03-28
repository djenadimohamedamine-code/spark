import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts flutterTts = FlutterTts();
  DateTime? _lastAlertTime;

  Future<void> init() async {
    await flutterTts.setLanguage("fr-FR");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);
  }

  Future<void> speakAlert(String text) async {
    // Si on a déjà parlé il y a moins de 30 secondes, on se tait pour le confort de Mimo
    if (_lastAlertTime != null && 
        DateTime.now().difference(_lastAlertTime!).inSeconds < 30) {
      return; 
    }
    
    _lastAlertTime = DateTime.now();
    await speak(text);
  }

  Future<void> speak(String text) async {
    // Évite le chevauchement audio pour une clarté "Elite"
    await flutterTts.stop();
    await flutterTts.speak(text);
  }
}
