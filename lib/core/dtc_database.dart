import 'dart:convert';
import 'package:flutter/services.dart';

class DtcDatabase {
  static Map<String, dynamic>? _codes;

  static Future<void> loadCodes() async {
    try {
      final String data = await rootBundle.loadString('assets/data/dtc_codes.json');
      _codes = jsonDecode(data);
    } catch (e) {
      print("Erreur chargement DTC: $e");
    }
  }

  static String getDescription(String code) {
    if (_codes == null) return "Code inconnu";
    return _codes![code] ?? "Dysfonctionnement spécifique détecté. Vérifier avec le manuel.";
  }
}
