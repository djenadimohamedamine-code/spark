import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceService {
  static final VoiceService _instance = VoiceService._internal();
  factory VoiceService() => _instance;
  VoiceService._internal();

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isAvailable = false;

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
      print("Le micro n'est pas disponible.");
      return;
    }
    
    // Si déjà en écoute, on arrête
    if (_speech.isListening) {
      await _speech.stop();
      return;
    }
    
    await _speech.listen(
      onResult: (result) {
        // On traite dès qu'on a un résultat (final ou intermédiaire suffisamment long)
        if (result.finalResult || result.recognizedWords.length > 3) {
          String text = result.recognizedWords.toLowerCase().trim();
          print("VOCAL: '$text'");
          if (text.isNotEmpty) {
            _processCommand(text, onCommand);
          }
        }
      },
      localeId: 'fr_FR',
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
    );
  }

  void stopListening() async {
    await _speech.stop();
  }

  void _processCommand(String text, Function(String command) onCommand) {
    if (text.isEmpty) return;

    // DASHBOARD
    if (text.contains('dashboard') || text.contains('tableau') || text.contains('bord') || text.contains('accueil')) {
      onCommand('DASHBOARD');
    }
    // STOP RIDE
    else if (text.contains('arrêt') || text.contains('arreter') || text.contains('terminer') || 
             text.contains('stop') || text.contains('finir') || text.contains('fin')) {
      onCommand('STOP_RIDE');
    }
    // START RIDE
    else if (text.contains('démarre') || text.contains('démarrer') || text.contains('demarr') ||
             text.contains('course') || text.contains('start') || text.contains('partir') ||
             text.contains('commenc') || text.contains('lancer') || text.contains('go')) {
      onCommand('START_RIDE');
    }
    // MAP
    else if (text.contains('carte') || text.contains('map') || text.contains('gps') || 
             text.contains('navigation') || text.contains('itinéraire')) {
      onCommand('MAP');
    }
    // EXPENSES
    else if (text.contains('dépense') || text.contains('depense') || text.contains('argent') || 
             text.contains('recharge') || text.contains('plein') || text.contains('essence')) {
      onCommand('EXPENSES');
    }
    // SATELLITE
    else if (text.contains('satellite') || text.contains('vue') || text.contains('aérien')) {
      onCommand('TOGGLE_SATELLITE');
    }
    // Pas de réponse "je n'ai pas compris" si le mot est trop court (bruit ambiant)
    else if (text.length > 4) {
      print("Commande non reconnue.");
    }
  }
}
