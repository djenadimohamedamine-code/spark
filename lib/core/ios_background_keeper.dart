import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service de maintien d'activité en arrière-plan pour iOS & Android.
///
/// Utilise une session audio silencieuse en boucle (mixWithOthers + category playback)
/// pour empêcher iOS de suspendre l'application lorsque l'utilisateur bascule
/// vers Messenger, YouTube, les réglages ou verrouille l'écran.
///
/// Ainsi :
/// 1. La liaison TCP avec le boîtier OBD2 reste ouverte en continu.
/// 2. Le calcul de consommation de carburant s'exécute en temps réel sans interruption.
/// 3. Au retour dans l'application, l'utilisateur retrouve instantanément ses jauges connectées.
class IosBackgroundKeeper {
  static final IosBackgroundKeeper _instance = IosBackgroundKeeper._internal();
  factory IosBackgroundKeeper() => _instance;
  IosBackgroundKeeper._internal();

  AudioPlayer? _player;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  static const String prefKey = 'pref_background_obd_enabled';

  Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefKey) ?? true; // Actif par défaut
    } catch (_) {
      return true;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, enabled);
    } catch (_) {}
    if (!enabled) {
      await stop();
    } else {
      await start();
    }
  }

  Future<void> start() async {
    if (_isRunning) return;
    final enabled = await isEnabled();
    if (!enabled) return;

    try {
      _player ??= AudioPlayer(playerId: 'mimo_background_keeper');
      
      // Configuration de la session audio :
      // - category: playback (indique à iOS que l'application doit continuer à tourner)
      // - mixWithOthers (ne coupe jamais la musique, les vidéos YouTube ou les appels)
      await _player!.setAudioContext(AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const [
            AVAudioSessionOptions.mixWithOthers,
          ],
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.none,
        ),
      ));

      await _player!.setVolume(0.0); // 100% silencieux
      await _player!.setReleaseMode(ReleaseMode.loop);
      await _player!.play(AssetSource('sounds/silence.wav'));
      _isRunning = true;
      debugPrint("MIMO_KEEPER: Mode arrière-plan activé (audio playback silencieux actif)");
    } catch (e) {
      debugPrint("MIMO_KEEPER: Erreur activation background keeper: $e");
    }
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    try {
      await _player?.stop();
      _isRunning = false;
      debugPrint("MIMO_KEEPER: Mode arrière-plan arrêté");
    } catch (e) {
      debugPrint("MIMO_KEEPER: Erreur arrêt background keeper: $e");
    }
  }

  void dispose() {
    stop();
    _player?.dispose();
    _player = null;
  }
}
