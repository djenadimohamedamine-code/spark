import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/source.dart';
import '../providers/switcher_provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  VideoPlayerController? _mainController;
  VideoPlayerController? _secondaryController; 
  
  int _lastSourceId = -1;
  bool _lastSplitState = false;

  bool _mainEnded = false;
  bool _secondaryEnded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final switcher = Provider.of<SwitcherProvider>(context);
    
    bool needsUpdate = false;
    
    if (_lastSourceId != switcher.currentSource.id) {
      _lastSourceId = switcher.currentSource.id;
      needsUpdate = true;
    }
    
    if (_lastSplitState != switcher.isSplitScreen) {
      _lastSplitState = switcher.isSplitScreen;
      needsUpdate = true;
    }
    
    if (needsUpdate) {
      _loadCurrentSource(switcher);
    }
  }

  Future<void> _loadCurrentSource(SwitcherProvider switcher) async {
    final source = switcher.currentSource;
    final isSplit = switcher.isSplitScreen;
    final extSource = switcher.lastExternalSource;
    
    final oldMain = _mainController;
    final oldSec = _secondaryController;
    
    _mainEnded = false;
    _secondaryEnded = false;

    Source mainSourceToPlay = source;
    Source? secondarySourceToPlay;
    
    if (isSplit) {
      mainSourceToPlay = switcher.presenterSource;
      secondarySourceToPlay = extSource;
    }
    
    _mainController = VideoPlayerController.asset(mainSourceToPlay.assetPath);
    await _mainController!.initialize();
    
    if (mainSourceToPlay.type == SourceType.presenter) {
      _mainController!.setLooping(true);
    } else {
      _mainController!.addListener(() {
        if (!mounted) return;
        if (_mainController!.value.isInitialized &&
            _mainController!.value.position >= _mainController!.value.duration) {
          
          if (mainSourceToPlay.autoReturn && !switcher.isSplitScreen) {
            switcher.returnToPresenter();
          } else if (mainSourceToPlay.type == SourceType.external) {
            // It's an external feed that just ended! Go to black.
            if (!_mainEnded) {
              setState(() {
                _mainEnded = true;
              });
            }
          }
        }
      });
    }
    _mainController!.play();

    if (secondarySourceToPlay != null) {
      _secondaryController = VideoPlayerController.asset(secondarySourceToPlay.assetPath);
      await _secondaryController!.initialize();
      
      _secondaryController!.addListener(() {
        if (!mounted) return;
        if (_secondaryController!.value.isInitialized &&
            _secondaryController!.value.position >= _secondaryController!.value.duration) {
          // The external feed in the split screen ended! Go to black.
          if (!_secondaryEnded) {
            setState(() {
              _secondaryEnded = true;
            });
          }
        }
      });
      _secondaryController!.play();
    } else {
      _secondaryController = null;
    }

    setState(() {});
    
    if (oldMain != null) {
      Future.delayed(const Duration(milliseconds: 100), () => oldMain.dispose());
    }
    if (oldSec != null) {
      Future.delayed(const Duration(milliseconds: 100), () => oldSec.dispose());
    }
  }

  @override
  void dispose() {
    _mainController?.dispose();
    _secondaryController?.dispose();
    super.dispose();
  }

  Color _getTintForSource(Source source) {
    if (source.type == SourceType.server) return Colors.transparent;
    final colors = [
      Colors.transparent,
      Colors.blue.withOpacity(0.3),
      Colors.green.withOpacity(0.3),
      Colors.red.withOpacity(0.2),
      Colors.purple.withOpacity(0.3),
      Colors.orange.withOpacity(0.3),
      Colors.teal.withOpacity(0.3),
      Colors.indigo.withOpacity(0.3),
    ];
    return colors[source.id % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final switcher = context.watch<SwitcherProvider>();
    final currentSource = switcher.currentSource;
    final isSplit = switcher.isSplitScreen;

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.video_settings, color: Colors.redAccent, size: 28),
                      SizedBox(width: 12),
                      Text(
                        'SONY MVS-7000 SIMULATOR',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      if (switcher.areVTRsLocked)
                        Container(
                          margin: const EdgeInsets.right(16),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.2),
                            border: Border.all(color: Colors.orange),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'VTR LOCKED (EXIT DIRECT)',
                            style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.2),
                          border: Border.all(color: Colors.redAccent),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'LIVE',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            
            // Main PGM View (Program)
            Expanded(
              flex: 2,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.8),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Videos
                    if (isSplit && _mainController != null && _secondaryController != null)
                      Row(
                        children: [
                          Expanded(child: _buildVideoPlayer(_mainController!, switcher.presenterSource, _mainEnded)),
                          Container(width: 2, color: Colors.white),
                          Expanded(child: _buildVideoPlayer(_secondaryController!, switcher.lastExternalSource!, _secondaryEnded)),
                        ],
                      )
                    else if (_mainController != null && _mainController!.value.isInitialized)
                      _buildVideoPlayer(_mainController!, currentSource, _mainEnded)
                    else
                      const Center(child: CircularProgressIndicator(color: Colors.redAccent)),
                      
                    // OSD (On-Screen Display) "DIRECT" indicator
                    if (currentSource.type == SourceType.external || isSplit)
                      Positioned(
                        top: 32,
                        right: 32,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.satellite_alt, color: Colors.white, size: 16),
                              SizedBox(width: 8),
                              Text(
                                'DIRECT',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 20,
                                  letterSpacing: 2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                    // Synthé (Lower-Third Graphics)
                    if (currentSource.lowerThirdTitle != null && !isSplit && !_mainEnded)
                      Positioned(
                        bottom: 40,
                        left: 40,
                        child: _buildLowerThird(
                          title: currentSource.lowerThirdTitle!,
                          subtitle: currentSource.lowerThirdSubtitle,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            
            // Dashboard Control Board (Buttons)
            Expanded(
              flex: 1,
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    // M/E 2 Button (Special Effects / Split)
                    GestureDetector(
                      onTap: () => switcher.toggleSplitScreen(),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 100,
                        decoration: BoxDecoration(
                          color: isSplit ? Colors.amber : Colors.amber.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSplit ? Colors.amberAccent : Colors.amber,
                            width: 2,
                          ),
                          boxShadow: isSplit ? [BoxShadow(color: Colors.amber.withOpacity(0.6), blurRadius: 12, spreadRadius: 2)] : [],
                        ),
                        child: const Center(
                          child: Text(
                            'M/E 2\n(SPLIT)',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Container(width: 2, color: Colors.white10),
                    const SizedBox(width: 16),
                    // Source Grid
                    Expanded(
                      child: GridView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                          childAspectRatio: 2.5,
                        ),
                        itemCount: switcher.sources.length,
                        itemBuilder: (context, index) {
                          final source = switcher.sources[index];
                          // It is live if it's the current source AND we are not in split screen (unless it's the external in split)
                          bool isLive = source.id == currentSource.id;
                          if (isSplit && source.type == SourceType.external && source.id == switcher.lastExternalSource?.id) {
                            isLive = true;
                          }
                          if (isSplit && source.type == SourceType.presenter) {
                            isLive = true;
                          }
                          
                          final isDisabled = switcher.areVTRsLocked && source.type == SourceType.xdcam;
                          
                          return _buildSwitcherButton(
                            source: source,
                            isLive: isLive,
                            isDisabled: isDisabled,
                            onTap: isDisabled ? null : () => switcher.cutToSource(source),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPlayer(VideoPlayerController controller, Source source, bool isEnded) {
    if (isEnded) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Text(
            'SIGNAL LOST',
            style: TextStyle(color: Colors.white24, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }

    if (!controller.value.isInitialized) return const SizedBox();
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(
          _getTintForSource(source),
          BlendMode.srcATop,
        ),
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildLowerThird({required String title, String? subtitle}) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: const BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
            ),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ),
          if (subtitle != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Text(
                subtitle,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSwitcherButton({
    required Source source,
    required bool isLive,
    required bool isDisabled,
    required VoidCallback? onTap,
  }) {
    Color buttonColor;
    switch (source.type) {
      case SourceType.server:
        buttonColor = Colors.blueGrey;
        break;
      case SourceType.presenter:
        buttonColor = Colors.purple;
        break;
      case SourceType.xdcam:
        buttonColor = Colors.teal;
        break;
      case SourceType.external:
        buttonColor = Colors.orange;
        break;
    }

    if (isLive) {
      buttonColor = Colors.red;
    }
    if (isDisabled) {
      buttonColor = Colors.grey;
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: isLive ? Colors.red : buttonColor.withOpacity(isDisabled ? 0.1 : 0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isLive ? Colors.redAccent : buttonColor.withOpacity(isDisabled ? 0.3 : 1.0),
            width: 2,
          ),
          boxShadow: isLive
              ? [BoxShadow(color: Colors.red.withOpacity(0.6), blurRadius: 12, spreadRadius: 2)]
              : [],
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                source.shortName,
                style: TextStyle(
                  color: isDisabled ? Colors.grey : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                source.name,
                style: TextStyle(
                  color: isDisabled ? Colors.grey.withOpacity(0.5) : Colors.white.withOpacity(0.7),
                  fontSize: 11,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
