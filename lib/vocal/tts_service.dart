import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  final Map<String, DateTime> _cooldowns = {};

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      await _flutterTts.setLanguage("fr-FR");
      await _flutterTts.setSpeechRate(0.5); // Vitesse normale
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);
      _isInitialized = true;
      print("TTS: Service de synthèse vocale prêt (fr-FR)");
    } catch (e) {
      print("TTS: Erreur d'initialisation: $e");
    }
  }

  /// Dit un message si le temps d'attente (cooldown) pour la clé spécifiée est expiré.
  /// Le cooldown par défaut est de 3 minutes (180 secondes).
  void speak(String text, {required String key, int cooldownSeconds = 180}) async {
    final now = DateTime.now();
    final lastSpoke = _cooldowns[key];

    if (lastSpoke != null && now.difference(lastSpoke).inSeconds < cooldownSeconds) {
      // Encore sous cooldown, on ne dit rien
      return;
    }

    // Mettre à jour le timestamp de l'alerte
    _cooldowns[key] = now;

    try {
      await init();
      if (_isInitialized) {
        print("TTS: Parole active pour la clé '$key' -> '$text'");
        await _flutterTts.speak(text);
      }
    } catch (e) {
      print("TTS: Erreur de parole: $e");
    }
  }
}
