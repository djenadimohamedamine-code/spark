import 'dart:async';
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
  StreamSubscription<PlayerState>? _stateSubscription;

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
      // Configuration de la session audio avec mixWithOthers :
      // - category: playback (indique à iOS que l'application doit continuer à tourner)
      // - mixWithOthers (ne coupe jamais la musique, VLC, les vidéos YouTube ou les appels)
      final audioContext = AudioContext(
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
      );

      // 1. Appliquer le contexte audio globalement avant tout appel à play()
      try {
        await AudioPlayer.global.setAudioContext(audioContext);
      } catch (e) {
        debugPrint("MIMO_KEEPER: Note setAudioContext global: $e");
      }

      _player ??= AudioPlayer(playerId: 'mimo_background_keeper');
      await _player!.setAudioContext(audioContext);
      await _player!.setVolume(0.0); // 100% silencieux
      await _player!.setReleaseMode(ReleaseMode.loop);

      // 2. Écouter les changements d'état du lecteur pour relance automatique si interruption (YouTube, Messenger vocal)
      _stateSubscription?.cancel();
      _stateSubscription = _player!.onPlayerStateChanged.listen((PlayerState state) {
        if (_isRunning && state != PlayerState.playing && state != PlayerState.disposed) {
          debugPrint("MIMO_KEEPER: Interruption audio détectée ($state) -> relance automatique...");
          Future.delayed(const Duration(milliseconds: 500), () {
            if (_isRunning && _player?.state != PlayerState.playing) {
              _player?.play(AssetSource('sounds/silence.wav')).catchError((_) {});
            }
          });
        }
      });

      await _player!.play(AssetSource('sounds/silence.wav'));
      _isRunning = true;
      debugPrint("MIMO_KEEPER: Mode arrière-plan activé (mixWithOthers actif, musique préservée)");
    } catch (e) {
      debugPrint("MIMO_KEEPER: Erreur activation background keeper: $e");
    }
  }

  /// Relance le lecteur silencieux s'il a été mis en pause ou interrompu par iOS
  /// (par exemple après une vidéo YouTube ou un message vocal Messenger).
  Future<void> ensureRunning() async {
    final enabled = await isEnabled();
    if (!enabled) return;
    if (!_isRunning || _player == null || _player?.state != PlayerState.playing) {
      debugPrint("MIMO_KEEPER: ensureRunning() -> réactivation du lecteur silencieux...");
      _isRunning = false;
      await start();
    }
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    try {
      _stateSubscription?.cancel();
      _stateSubscription = null;
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
