import 'package:flutter/foundation.dart';
import '../models/source.dart';

class SwitcherProvider extends ChangeNotifier {
  // The available buttons on our MVS-7000 mock board
  final List<Source> sources = const [
    Source(
      id: 1, 
      name: 'Générique Début', 
      shortName: 'SERVER 1', 
      type: SourceType.server, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4',
      autoReturn: true
    ),
    Source(
      id: 2, 
      name: 'Générique Fin', 
      shortName: 'SERVER 2', 
      type: SourceType.server, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4',
      autoReturn: false
    ),
    Source(
      id: 3, 
      name: 'Présentateur', 
      shortName: 'STUDIO', 
      type: SourceType.presenter, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/WeAreGoingOnBullrun.mp4',
      autoReturn: false,
      lowerThirdTitle: 'MOHAMED AMINE',
      lowerThirdSubtitle: 'Édition Spéciale - JT 20H',
    ),
    Source(
      id: 4, 
      name: 'VTR 1 (Économie)', 
      shortName: 'VTR 1', 
      type: SourceType.xdcam, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
      autoReturn: true,
      lowerThirdTitle: 'ÉCONOMIE: HAUSSE DES EXPORTATIONS',
      lowerThirdSubtitle: 'Sujet: Impact sur le marché local',
    ),
    Source(
      id: 5, 
      name: 'VTR 2 (Sport)', 
      shortName: 'VTR 2', 
      type: SourceType.xdcam, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
      autoReturn: true,
      lowerThirdTitle: 'SPORT: RÉSULTATS DU WEEK-END',
      lowerThirdSubtitle: 'Ligue 1: La course au titre relancée',
    ),
    Source(
      id: 6, 
      name: 'VTR 3 (Météo)', 
      shortName: 'VTR 3', 
      type: SourceType.xdcam, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
      autoReturn: true,
      lowerThirdTitle: 'MÉTÉO: VAGUE DE CHALEUR',
      lowerThirdSubtitle: 'Prévisions pour les prochains jours',
    ),
    Source(
      id: 7, 
      name: 'Direct Paris', 
      shortName: 'EXT A', 
      type: SourceType.external, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
      autoReturn: false, // NO AUTO RETURN! It will go black if the operator misses it.
      lowerThirdTitle: 'EN DIRECT DE PARIS',
      lowerThirdSubtitle: 'Notre correspondant sur place',
    ),
    Source(
      id: 8, 
      name: 'Direct Alger', 
      shortName: 'EXT B', 
      type: SourceType.external, 
      networkUrl: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
      autoReturn: false, // NO AUTO RETURN!
      lowerThirdTitle: 'EN DIRECT D\'ALGER',
      lowerThirdSubtitle: 'Intervention spéciale',
    ),
  ];

  late Source _currentSource;
  bool _isSplitScreen = false;
  Source? _lastExternalSource;

  SwitcherProvider() {
    _currentSource = sources.firstWhere((s) => s.type == SourceType.server);
  }

  Source get currentSource => _currentSource;
  bool get isSplitScreen => _isSplitScreen;
  Source? get lastExternalSource => _lastExternalSource;
  
  Source get presenterSource => sources.firstWhere((s) => s.type == SourceType.presenter);

  bool get areVTRsLocked {
    return _currentSource.type == SourceType.external && !_isSplitScreen;
  }

  void cutToSource(Source source) {
    if (source.type == SourceType.external) {
      _lastExternalSource = source;
    }
    
    if (_isSplitScreen && (source.type == SourceType.xdcam || source.type == SourceType.server)) {
      _isSplitScreen = false;
    }

    if (_currentSource.id != source.id) {
      _currentSource = source;
      notifyListeners();
    }
  }

  void toggleSplitScreen() {
    _isSplitScreen = !_isSplitScreen;
    
    if (_isSplitScreen) {
      if (_currentSource.type != SourceType.presenter && _currentSource.type != SourceType.external) {
         _currentSource = presenterSource;
      }
      _lastExternalSource ??= sources.firstWhere((s) => s.type == SourceType.external);
    }
    
    notifyListeners();
  }

  void returnToPresenter() {
    _isSplitScreen = false;
    cutToSource(presenterSource);
  }
}
