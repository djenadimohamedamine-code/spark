import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../core/gps_debug_logger.dart';

/// Écran de diagnostic GPS — accessible sans Xcode.
///
/// Accès depuis le drawer MIMO SPARK.
///
/// Fonctions :
///   • Bascule marche/arrêt de l'enregistrement (désactivé par défaut).
///   • Insertion rapide de marqueurs terrain (Demi-tour, Virage, Départ, Arrêt).
///   • Affiche le log en temps réel (ScrollView auto-scroll vers le bas).
///   • Bouton Partager : feuille de partage iOS native (Notes, Mail, AirDrop, etc.).
///   • Bouton Copier : copie l'intégralité du log dans le presse-papier.
///   • Bouton Effacer : vide le fichier log et le buffer mémoire.
class GpsDebugLogPage extends StatefulWidget {
  const GpsDebugLogPage({super.key});

  @override
  State<GpsDebugLogPage> createState() => _GpsDebugLogPageState();
}

class _GpsDebugLogPageState extends State<GpsDebugLogPage> {
  final ScrollController _scroll = ScrollController();
  List<String> _lines = [];
  bool _autoScroll = true;
  bool _isLogging = GpsDebugLogger.enabled;
  StreamSubscription<void>? _pollSubscription;

  @override
  void initState() {
    super.initState();
    _refresh();
    _startPolling();
  }

  late final Stream<void> _poll = Stream.periodic(
    const Duration(seconds: 2),
  );

  void _startPolling() {
    _pollSubscription = _poll.listen((_) {
      if (mounted) _refresh();
    });
  }

  void _refresh() {
    setState(() {
      _lines = GpsDebugLogger.lines.toList();
      _isLogging = GpsDebugLogger.enabled;
    });
    if (_autoScroll && _scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _toggleLogging(bool value) async {
    await GpsDebugLogger.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _isLogging = value;
    });
    _refresh();
  }

  Future<void> _share() async {
    final path = await GpsDebugLogger.filePath;
    final xFile = XFile(path, mimeType: 'text/plain', name: 'gps_debug_log.txt');
    await Share.shareXFiles(
      [xFile],
      subject: 'MIMO SPARK — Log GPS diagnostic',
      text: 'Log GPS SPARK (${_lines.length} entrées)',
    );
  }

  Future<void> _copy() async {
    final content = _lines.join('\n');
    await Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Log copié dans le presse-papier'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1C24),
        title: const Text('Effacer le log ?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Le fichier de log GPS sera effacé. Cette action est irréversible.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Effacer', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await GpsDebugLogger.clear();
      _refresh();
    }
  }

  void _addMarker(String label) {
    GpsDebugLogger.mark(label);
    _refresh();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Marqueur ajouté : $label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _showMarkerPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF151820),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Insérer un marqueur terrain',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.u_turn_left, color: Colors.amberAccent),
                title: const Text('DEMI_TOUR (U-turn Baïnem / Bab El Oued)', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _addMarker('DEMI_TOUR');
                },
              ),
              ListTile(
                leading: const Icon(Icons.turn_right, color: Colors.cyanAccent),
                title: const Text('VIRAGE_SERRE', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _addMarker('VIRAGE_SERRE');
                },
              ),
              ListTile(
                leading: const Icon(Icons.play_arrow, color: Colors.greenAccent),
                title: const Text('DEPART_ROUTE', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _addMarker('DEPART_ROUTE');
                },
              ),
              ListTile(
                leading: const Icon(Icons.stop, color: Colors.redAccent),
                title: const Text('ARRET_FEU_ROUGE', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _addMarker('ARRET_FEU_ROUGE');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pollSubscription?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0C10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151820),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Log GPS — Diagnostic',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              '${_lines.length} entrées · auto-scroll: $_autoScroll',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
        actions: [
          // Auto-scroll toggle
          IconButton(
            tooltip: 'Auto-scroll',
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
              color: _autoScroll ? Colors.greenAccent : Colors.white54,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          // Copier
          IconButton(
            tooltip: 'Copier',
            icon: const Icon(Icons.copy, color: Colors.white70),
            onPressed: _copy,
          ),
          // Partager (iOS share sheet)
          IconButton(
            tooltip: 'Partager',
            icon: const Icon(Icons.share, color: Colors.white),
            onPressed: _share,
          ),
          // Effacer
          IconButton(
            tooltip: 'Effacer',
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: _clear,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.amberAccent[700],
        icon: const Icon(Icons.flag, color: Colors.black),
        label: const Text('Marqueur', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
        onPressed: _showMarkerPicker,
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              'Version source : ${GpsDebugLogger.buildSha}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          // Barre de contrôle d'activation à chaud
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF12151D),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _isLogging ? Icons.fiber_manual_record : Icons.pause_circle_outline,
                      color: _isLogging ? Colors.redAccent : Colors.grey,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isLogging ? 'ENREGISTREMENT ACTIF' : 'ENREGISTREMENT EN PAUSE',
                      style: TextStyle(
                        color: _isLogging ? Colors.redAccent : Colors.grey,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: _isLogging,
                  activeColor: Colors.redAccent,
                  onChanged: _toggleLogging,
                ),
              ],
            ),
          ),
          // En-tête des colonnes (rappel du format)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0xFF1E2030),
            child: const SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                'timestamp_ms | speed | h_raw | acc_m | dist_prev | dist_anchor | src | smooth | page',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          // Log scroll view
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text(
                        _isLogging
                            ? 'Enregistrement actif.\nOuvrez "Navigation GPS" pour enregistrer les mesures.'
                            : 'Enregistrement en pause.\nBasculez le bouton ci-dessus pour activer l\'enregistrement.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38, fontSize: 14),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: _lines.length,
                    itemBuilder: (_, i) {
                      final line = _lines[i];
                      final isMarker = line.startsWith('#');
                      final isFrozen = line.contains('frozen');
                      final isBearing = line.contains('anchor_bearing');

                      Color textColor;
                      if (isMarker) {
                        textColor = Colors.amberAccent;
                      } else if (isFrozen) {
                        textColor = const Color(0xFFFF6B6B);
                      } else if (isBearing) {
                        textColor = const Color(0xFF6BCB77);
                      } else {
                        textColor = Colors.white70;
                      }

                      return SelectableText(
                        line,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          height: 1.4,
                        ),
                      );
                    },
                  ),
          ),
          // Légende des couleurs
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: const Color(0xFF151820),
            child: const Wrap(
              spacing: 16,
              children: [
                _LegendItem(color: Colors.white70, label: 'ios_direct'),
                _LegendItem(color: Color(0xFF6BCB77), label: 'anchor_bearing'),
                _LegendItem(color: Color(0xFFFF6B6B), label: 'frozen (cap gelé)'),
                _LegendItem(color: Colors.amberAccent, label: 'marqueur terrain'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 10)),
      ],
    );
  }
}
