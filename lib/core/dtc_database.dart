import 'dart:convert';
import 'package:flutter/services.dart';

class DtcDatabase {
  static Map<String, dynamic>? _codes;
  static bool _loading = false;

  // ─── Chargement lazy (auto si pas encore chargé) ────────────────────────
  static Future<void> _ensureLoaded() async {
    if (_codes != null) return;
    if (_loading) {
      while (_loading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return;
    }
    await loadCodes();
  }

  static Future<void> loadCodes() async {
    if (_loading) return;
    _loading = true;
    try {
      final String data = await rootBundle.loadString('assets/data/dtc_codes.json');
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) {
        _codes = decoded;
      }
    } catch (e) {
      print("Erreur chargement DTC: $e");
      _codes = {};
    } finally {
      _loading = false;
    }
  }

  static Future<String> getDescription(String code) async {
    await _ensureLoaded();
    final entry = _codes?[code.toUpperCase()];
    if (entry == null) return "Code inconnu ($code)";
    if (entry is String) return entry;
    return entry['msg'] ?? "Dysfonctionnement spécifique.";
  }

  static Future<String> getSeverity(String code) async {
    await _ensureLoaded();
    final entry = _codes?[code.toUpperCase()];
    if (entry is Map) return entry['sev'] ?? 'info';
    return 'info';
  }

  static Future<List<Map<String, String>>> resolveAll(List<String> codes) async {
    await _ensureLoaded();
    return codes.map((code) {
      final entry = _codes?[code.toUpperCase()];
      String msg = "Code non répertorié ($code)";
      String sev = 'info';
      if (entry is String) {
        msg = entry;
      } else if (entry is Map) {
        msg = entry['msg'] ?? msg;
        sev = entry['sev'] ?? sev;
      }
      return {'code': code, 'msg': msg, 'sev': sev};
    }).toList();
  }
}

