import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Journalisation temporaire du cap GPS pour diagnostic P0-GPS.
///
/// Désactivée par défaut ([enabled = false]). Peut être activée/désactivée
/// dynamiquement depuis l'interface SPARK sur iPhone.
/// Ne stocke aucune coordonnée géographique absolue.
///
/// Accès sans Xcode : [GpsDebugLogPage] lit ce fichier et propose
/// le partage direct via la feuille de partage iOS (share_plus).
class GpsDebugLogger {
  GpsDebugLogger._();

  /// Désactivé par défaut. Basculable à chaud via [setEnabled]
  /// depuis l'interface sur l'iPhone.
  static bool enabled = false;

  static const String buildSha = String.fromEnvironment(
    'SPARK_BUILD_SHA', defaultValue: 'non identifiée',
  );

  static const String _filename = 'gps_debug_log.txt';
  static const int _maxLines = 2000; // ~200 Ko — borné, ne sature pas la mémoire

  // Buffer mémoire pour affichage in-app immédiat
  static final List<String> _buffer = [];
  static IOSink? _sink;
  static bool _initialized = false;

  // ------------------------------------------------------------------ toggle & init

  /// Active ou désactive la journalisation à chaud.
  static Future<void> setEnabled(bool value) async {
    enabled = value;
    if (enabled) {
      await init();
      mark('LOGGING_ACTIVE');
    } else {
      mark('LOGGING_PAUSE');
      await close();
    }
  }

  static Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_filename');
      _sink = file.openWrite(mode: FileMode.append);
      _initialized = true;
      final header = _buildHeader();
      _sink!.writeln(header);
      _buffer.add(header);
    } catch (_) {}
  }

  static String _buildHeader() {
    final now = DateTime.now();
    return '\n# GPS debug session — ${now.toIso8601String()}\n'
        '# Build: $buildSha\n'
        '# timestamp_ms | speed_kmh | heading_raw | accuracy_m '
        '| dist_prev_m | dist_anchor_m | source | smooth_deg | page';
  }

  // ------------------------------------------------------------------ log

  /// Enregistre une mesure GPS.
  ///
  /// [timestampMs]   : DateTime.now().millisecondsSinceEpoch
  /// [speedKmh]      : vitesse en km/h
  /// [headingRaw]    : pos.heading brut (-1 si invalide)
  /// [accuracyM]     : pos.accuracy en mètres
  /// [distPrevM]     : distance depuis la position précédente (m)
  /// [distAnchorM]   : distance accumulée depuis la dernière ancre fiable (m)
  /// [source]        : "ios_direct" | "anchor_bearing" | "frozen" | "frozen_slow"
  /// [smoothedDeg]   : cap final après lissage
  /// [page]          : "MapPage" | "ExpertMapPage"
  static void log({
    required int timestampMs,
    required double speedKmh,
    required double headingRaw,
    required double accuracyM,
    required double distPrevM,
    required double distAnchorM,
    required String source,
    required double smoothedDeg,
    required String page,
  }) {
    if (!enabled) return;

    final line = '$timestampMs'
        ' | ${speedKmh.toStringAsFixed(1)}'
        ' | ${headingRaw.toStringAsFixed(1)}'
        ' | ${accuracyM.toStringAsFixed(1)}'
        ' | ${distPrevM.toStringAsFixed(1)}'
        ' | ${distAnchorM.toStringAsFixed(1)}'
        ' | $source'
        ' | ${smoothedDeg.toStringAsFixed(1)}'
        ' | $page';

    _buffer.add(line);
    if (_buffer.length > _maxLines) _buffer.removeAt(0);

    _sink?.writeln(line);
  }

  // ------------------------------------------------------------------ event markers

  /// Insère un marqueur textuel dans les logs (ex: "UTURN_START", "DEMI_TOUR").
  static void mark(String label) {
    final line = '# ${DateTime.now().toIso8601String()} [$label]';
    _buffer.add(line);
    if (_buffer.length > _maxLines) _buffer.removeAt(0);
    _sink?.writeln(line);
  }

  // ------------------------------------------------------------------ access

  /// Contenu du buffer mémoire, plus récent en dernier.
  static List<String> get lines => List.unmodifiable(_buffer);

  /// Chemin absolu du fichier log sur le device.
  static Future<String> get filePath async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_filename';
  }

  /// Contenu complet du fichier log (pour partage).
  static Future<String> readAll() async {
    final path = await filePath;
    final file = File(path);
    if (!await file.exists()) return '(aucun log enregistré)';
    return file.readAsString();
  }

  /// Efface le fichier log et réinitialise le buffer.
  static Future<void> clear() async {
    _buffer.clear();
    final path = await filePath;
    final file = File(path);
    if (await file.exists()) await file.writeAsString('');
    _initialized = false;
    _sink = null;
    if (enabled) {
      await init();
    }
  }

  /// Ferme le sink proprement (appeler dans dispose).
  static Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _initialized = false;
  }
}
