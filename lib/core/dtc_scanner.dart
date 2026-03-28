import '../vocal/tts_service.dart';

class DtcScanner {
  static final Map<String, String> dtcMap = {
    'P0113': 'Mimo, vérifie le capteur d\'air.',
    'P0342': 'Mimo, le signal du capteur d\'arbre à cames est faible.',
    'P0122': 'Mimo, vérifie le capteur de position du papillon.',
  };

  final TtsService _ttsService = TtsService();

  void scanDtc(String dtcCode) {
    if (dtcMap.containsKey(dtcCode)) {
      _ttsService.speak(dtcMap[dtcCode]!);
    } else {
      _ttsService.speak('Mimo, j\'ai détecté une nouvelle erreur : $dtcCode');
    }
  }
}
