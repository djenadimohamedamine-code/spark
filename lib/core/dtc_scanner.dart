import '../vocal/tts_service.dart';

import 'dtc_database.dart';

class DtcScanner {
  final TtsService _ttsService = TtsService();

  // ─── Décodage trame brute OBD Mode 03 ───────────────────────────────────
  // Exemple : "43 01 33 00 00 00 00" -> P0133
  List<String> parseRawDtcFrame(String rawFrame) {
    List<String> codes = [];
    try {
      List<String> bytes = rawFrame
          .trim()
          .toUpperCase()
          .replaceAll(RegExp(r'[^0-9A-F\s]'), '')
          .split(RegExp(r'\s+'))
          .where((b) => b.length == 2)
          .toList();

      int startIdx = bytes.indexOf('43');
      if (startIdx == -1) return [];

      int idx = startIdx + 1; // On passe le '43'
      if (idx < bytes.length && bytes[idx].length == 2 && int.tryParse(bytes[idx], radix: 16) != null) {
          // Sur certains ELM327, le 2ème octet est le nombre de codes.
          // On commence après.
          idx++; 
      }

      while (idx + 1 < bytes.length) {
        String high = bytes[idx];
        String low = bytes[idx + 1];
        idx += 2;

        if (high == '00' && low == '00') continue;

        int highVal = int.parse(high, radix: 16);
        String prefix;
        int prefixBits = (highVal & 0xC0) >> 6;
        switch (prefixBits) {
          case 0: prefix = 'P'; break;
          case 1: prefix = 'C'; break;
          case 2: prefix = 'B'; break;
          case 3: prefix = 'U'; break;
          default: prefix = 'P';
        }

        String codeNum = ((highVal & 0x3F).toRadixString(16).padLeft(2, '0') + low).toUpperCase();
        codes.add('$prefix$codeNum');
      }
    } catch (_) {}
    return codes;
  }

  // ─── Lecture et annonce vocale par sévérité ─────────────────────────────
  Future<void> announceCodes(List<String> codes) async {
    if (codes.isEmpty) {
      _ttsService.speak('Mimo, aucun code erreur détecté. Tout est propre.');
      return;
    }

    List<Map<String, String>> resolved = await DtcDatabase.resolveAll(codes);
    
    // Trier : Critique -> Alerte -> Info
    resolved.sort((a, b) {
      int weight(String? s) => s == 'critique' ? 3 : (s == 'alerte' ? 2 : 1);
      return weight(b['sev']).compareTo(weight(a['sev']));
    });

    for (var item in resolved) {
      String prefix = item['sev'] == 'critique' ? 'Alerte critique Mimo ! ' : 'Mimo, ';
      _ttsService.speak('$prefix${item['msg']}');
      await Future.delayed(const Duration(seconds: 4)); // Attendre que TTS parle
    }
  }

  // API Legacy
  void scanDtc(String dtcCode) async {
    String msg = await DtcDatabase.getDescription(dtcCode);
    _ttsService.speak(msg);
  }
}

