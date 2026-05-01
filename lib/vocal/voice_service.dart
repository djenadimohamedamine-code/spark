import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'tts_service.dart';

class VoiceService {
  static final VoiceService _instance = VoiceService._internal();
  factory VoiceService() => _instance;
  VoiceService._internal();

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isAvailable = false;
  final TtsService _tts = TtsService();

  Future<bool> init() async {
    if (_isAvailable) return true;
    _isAvailable = await _speech.initialize(
      onStatus: (status) => print('Speech status: $status'),
      onError: (error) => print('Speech error: $error'),
    );
    return _isAvailable;
  }

  bool get isListening => _speech.isListening;

  void startListening(Function(String command) onCommand) async {
    bool ready = await init();
    if (!ready) {
      _tts.speak("Le micro n'est pas disponible.");
      return;
    }
    
    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          String text = result.recognizedWords.toLowerCase();
          print("VOCAL: $text");
          _processCommand(text, onCommand);
        }
      },
      localeId: 'fr_FR',
      listenFor: const Duration(seconds: 5),
    );
  }

  void stopListening() async {
    await _speech.stop();
  }

  void _processCommand(String text, Function(String command) onCommand) {
    if (text.isEmpty) return;

    if (text.contains('dashboard') || text.contains('tableau de bord')) {
      onCommand('DASHBOARD');
    } else if (text.contains('démarrer') || text.contains('course')) {
      // "Démarrer la course" ou "Démarrer"
      if (text.contains('arrêter') || text.contains('terminer')) {
         onCommand('STOP_RIDE');
      } else {
         onCommand('START_RIDE');
      }
    } else if (text.contains('arrêter') || text.contains('terminer') || text.contains('stop')) {
      onCommand('STOP_RIDE');
    } else if (text.contains('carte') || text.contains('map')) {
      onCommand('MAP');
    } else if (text.contains('dépense') || text.contains('argent')) {
      onCommand('EXPENSES');
    } else if (text.contains('satellite')) {
      onCommand('TOGGLE_SATELLITE');
    } else {
      _tts.speak("Je n'ai pas compris, redis s'il te plaît.");
    }
  }
}
