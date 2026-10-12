import 'package:flutter/foundation.dart';
import '../models/source.dart';

class TimelineProvider extends ChangeNotifier {
  final List<Source> _timeline = const [
    Source(id: 0, name: 'Intro', type: SourceType.generic, assetPath: 'assets/intro.mp4'),
    Source(id: 1, name: 'Présentateur', type: SourceType.presenter, assetPath: 'assets/presenter.mp4'),
    Source(id: 2, name: 'XDCAM 1', type: SourceType.xdcam, assetPath: 'assets/xdcam1.mp4'),
    Source(id: 3, name: 'Présentateur', type: SourceType.presenter, assetPath: 'assets/presenter.mp4'),
    Source(id: 4, name: 'Ext A', type: SourceType.external, assetPath: 'assets/external_a.mp4', isExternal: true),
    Source(id: 5, name: 'Présentateur', type: SourceType.presenter, assetPath: 'assets/presenter.mp4'),
    Source(id: 6, name: 'XDCAM 2', type: SourceType.xdcam, assetPath: 'assets/xdcam2.mp4'),
    Source(id: 7, name: 'Présentateur', type: SourceType.presenter, assetPath: 'assets/presenter.mp4'),
    Source(id: 8, name: 'Ext B', type: SourceType.external, assetPath: 'assets/external_b.mp4', isExternal: true),
    Source(id: 9, name: 'Présentateur', type: SourceType.presenter, assetPath: 'assets/presenter.mp4'),
    Source(id: 10, name: 'XDCAM 3', type: SourceType.xdcam, assetPath: 'assets/xdcam3.mp4'),
    Source(id: 11, name: 'Présentateur', type: SourceType.presenter, assetPath: 'assets/presenter.mp4'),
    Source(id: 12, name: 'Outro', type: SourceType.generic, assetPath: 'assets/outro.mp4'),
  ];

  int _currentIndex = 0;

  List<Source> get timeline => _timeline;
  int get currentIndex => _currentIndex;
  Source get currentSource => _timeline[_currentIndex];
  bool get isFinished => _currentIndex >= _timeline.length - 1;

  void next() {
    if (_currentIndex < _timeline.length - 1) {
      _currentIndex++;
      notifyListeners();
    }
  }

  void previous() {
    if (_currentIndex > 0) {
      _currentIndex--;
      notifyListeners();
    }
  }

  void reset() {
    _currentIndex = 0;
    notifyListeners();
  }

  // To allow manual selection (if the user clicks a card in the dashboard)
  void setIndex(int index) {
    if (index >= 0 && index < _timeline.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }
}
