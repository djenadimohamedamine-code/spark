import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Live clock
  late Timer _clockTimer;
  String _currentTime = '';
  
  // Elapsed time since JT start
  final Stopwatch _jtStopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    // Force landscape mode for broadcast feel
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Hide system UI for immersive experience
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    
    // Start live clock
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _jtStopwatch.start();
  }

  void _updateClock() {
    final now = DateTime.now();
    setState(() {
      _currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    });
  }

  String _getElapsedTime() {
    final elapsed = _jtStopwatch.elapsed;
    return '${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
  }

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
      _mainController!.addListener(_createVideoEndListener(
        controller: _mainController!,
        source: mainSourceToPlay,
        switcher: switcher,
        isMain: true,
      ));
    }
    _mainController!.play();

    if (secondarySourceToPlay != null) {
      _secondaryController = VideoPlayerController.asset(secondarySourceToPlay.assetPath);
      await _secondaryController!.initialize();
      
      _secondaryController!.addListener(_createVideoEndListener(
        controller: _secondaryController!,
        source: secondarySourceToPlay,
        switcher: switcher,
        isMain: false,
      ));
      _secondaryController!.play();
    } else {
      _secondaryController = null;
    }

    if (mounted) setState(() {});
    
    // Dispose old controllers safely
    Future.delayed(const Duration(milliseconds: 200), () {
      oldMain?.dispose();
      oldSec?.dispose();
    });
  }

  VoidCallback _createVideoEndListener({
    required VideoPlayerController controller,
    required Source source,
    required SwitcherProvider switcher,
    required bool isMain,
  }) {
    return () {
      if (!mounted) return;
      if (!controller.value.isInitialized) return;
      
      final position = controller.value.position;
      final duration = controller.value.duration;
      
      // Use a small threshold to avoid missing the end
      if (position.inMilliseconds >= duration.inMilliseconds - 200 && duration.inMilliseconds > 0) {
        if (isMain) {
          if (source.autoReturn && !switcher.isSplitScreen) {
            switcher.returnToPresenter();
          } else if (source.type == SourceType.external && !_mainEnded) {
            setState(() => _mainEnded = true);
          }
        } else {
          if (!_secondaryEnded) {
            setState(() => _secondaryEnded = true);
          }
        }
      }
    };
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _jtStopwatch.stop();
    _mainController?.dispose();
    _secondaryController?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final switcher = context.watch<SwitcherProvider>();
    final currentSource = switcher.currentSource;
    final isSplit = switcher.isSplitScreen;
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 700;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // ─── TOP BAR ───
            _buildTopBar(switcher, isSplit, isSmallScreen),
            
            // ─── MAIN PGM VIEW ───
            Expanded(
              flex: 3,
              child: _buildProgramMonitor(switcher, currentSource, isSplit),
            ),
            
            // ─── CONTROL BOARD ───
            _buildControlBoard(switcher, currentSource, isSplit, isSmallScreen),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(SwitcherProvider switcher, bool isSplit, bool isSmallScreen) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        border: Border(bottom: BorderSide(color: Color(0xFF333333))),
      ),
      child: Row(
        children: [
          // Left: Logo + Title
          const Icon(Icons.video_settings, color: Colors.redAccent, size: 22),
          const SizedBox(width: 8),
          Text(
            isSmallScreen ? 'MVS-7000' : 'SONY MVS-7000 SIMULATOR',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          const Spacer(),
          
          // Center: Clock + Elapsed Time
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0D0D0D),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF333333)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _currentTime,
                  style: const TextStyle(
                    color: Color(0xFF00FF88),
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(width: 16),
                Container(width: 1, height: 20, color: const Color(0xFF333333)),
                const SizedBox(width: 16),
                const Text('JT ', style: TextStyle(color: Colors.white38, fontSize: 12)),
                Text(
                  _getElapsedTime(),
                  style: const TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          
          // Right: Status indicators
          if (switcher.areVTRsLocked)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.2),
                border: Border.all(color: Colors.orange),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock, color: Colors.orange, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    isSmallScreen ? 'LOCKED' : 'VTR LOCKED',
                    style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ],
              ),
            ),
          // LIVE indicator with blinking animation
          _buildLiveIndicator(),
        ],
      ),
    );
  }

  Widget _buildLiveIndicator() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1.0),
      duration: const Duration(milliseconds: 800),
      builder: (context, value, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(value * 0.3),
            border: Border.all(color: Colors.red.withOpacity(value)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(value),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'ON AIR',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        );
      },
      onEnd: () {
        // Restart animation for continuous blink effect
        if (mounted) setState(() {});
      },
    );
  }

  Widget _buildProgramMonitor(SwitcherProvider switcher, Source currentSource, bool isSplit) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A2A), width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.8),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Video Layer ──
            if (isSplit && _mainController != null && _secondaryController != null)
              Row(
                children: [
                  Expanded(child: _buildVideoPlayer(_mainController!, switcher.presenterSource, _mainEnded)),
                  Container(width: 3, color: Colors.white),
                  Expanded(child: _buildVideoPlayer(_secondaryController!, switcher.lastExternalSource!, _secondaryEnded)),
                ],
              )
            else if (_mainController != null && _mainController!.value.isInitialized)
              _buildVideoPlayer(_mainController!, currentSource, _mainEnded)
            else
              const Center(child: CircularProgressIndicator(color: Colors.redAccent)),
              
            // ── OSD: DIRECT indicator ──
            if (currentSource.type == SourceType.external || isSplit)
              Positioned(
                top: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withOpacity(0.5),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.satellite_alt, color: Colors.white, size: 14),
                      SizedBox(width: 6),
                      Text(
                        'DIRECT',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            
            // ── OSD: Source name tag (top-left) ──
            Positioned(
              top: 16,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  isSplit ? 'M/E 2 SPLIT' : currentSource.shortName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
              
            // ── Synthé (Lower-Third) ──
            if (currentSource.lowerThirdTitle != null && !isSplit && !_mainEnded)
              Positioned(
                bottom: 30,
                left: 30,
                child: _buildLowerThird(
                  title: currentSource.lowerThirdTitle!,
                  subtitle: currentSource.lowerThirdSubtitle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlBoard(SwitcherProvider switcher, Source currentSource, bool isSplit, bool isSmallScreen) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1E1E1E), Color(0xFF151515)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Row(
        children: [
          // ── M/E 2 Button ──
          GestureDetector(
            onTap: () => switcher.toggleSplitScreen(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: isSmallScreen ? 70 : 90,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isSplit 
                  ? Colors.amber 
                  : Colors.amber.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSplit ? Colors.amberAccent : Colors.amber.withOpacity(0.5),
                  width: 2,
                ),
                boxShadow: isSplit 
                  ? [BoxShadow(color: Colors.amber.withOpacity(0.5), blurRadius: 12, spreadRadius: 2)] 
                  : [],
              ),
              child: Center(
                child: Text(
                  'M/E 2\nSPLIT',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isSplit ? Colors.black : Colors.amber,
                    fontWeight: FontWeight.w900,
                    fontSize: isSmallScreen ? 12 : 14,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: double.infinity, color: const Color(0xFF333333)),
          const SizedBox(width: 12),
          // ── Source Buttons Grid ──
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: isSmallScreen ? 8 : 12,
                mainAxisSpacing: isSmallScreen ? 8 : 12,
                childAspectRatio: isSmallScreen ? 2.0 : 2.5,
              ),
              itemCount: switcher.sources.length,
              itemBuilder: (context, index) {
                final source = switcher.sources[index];
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
                  isSmallScreen: isSmallScreen,
                  onTap: isDisabled ? null : () => switcher.cutToSource(source),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPlayer(VideoPlayerController controller, Source source, bool isEnded) {
    if (isEnded) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.signal_wifi_off, color: Colors.red.withOpacity(0.3), size: 40),
              const SizedBox(height: 8),
              const Text(
                'SIGNAL PERDU',
                style: TextStyle(color: Colors.white24, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 3),
              ),
            ],
          ),
        ),
      );
    }

    if (!controller.value.isInitialized) return const SizedBox();
    
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildLowerThird({required String title, String? subtitle}) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 12,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFCC0000), Color(0xFFEE1111)],
              ),
              borderRadius: subtitle != null 
                ? const BorderRadius.only(topLeft: Radius.circular(6), topRight: Radius.circular(6))
                : BorderRadius.circular(6),
            ),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ),
          if (subtitle != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(6),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF222222),
                  fontSize: 15,
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
    required bool isSmallScreen,
    required VoidCallback? onTap,
  }) {
    Color buttonColor;
    IconData? typeIcon;
    switch (source.type) {
      case SourceType.server:
        buttonColor = const Color(0xFF5C6BC0); // Indigo
        typeIcon = Icons.dns;
        break;
      case SourceType.presenter:
        buttonColor = const Color(0xFF7E57C2); // Purple
        typeIcon = Icons.person;
        break;
      case SourceType.xdcam:
        buttonColor = const Color(0xFF26A69A); // Teal
        typeIcon = Icons.play_circle_outline;
        break;
      case SourceType.external:
        buttonColor = const Color(0xFFFF7043); // Deep Orange
        typeIcon = Icons.satellite_alt;
        break;
    }

    if (isDisabled) {
      buttonColor = Colors.grey;
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isLive 
            ? Colors.red 
            : buttonColor.withOpacity(isDisabled ? 0.08 : 0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isLive 
              ? Colors.redAccent 
              : buttonColor.withOpacity(isDisabled ? 0.2 : 0.7),
            width: isLive ? 2 : 1.5,
          ),
          boxShadow: isLive
              ? [BoxShadow(color: Colors.red.withOpacity(0.5), blurRadius: 10, spreadRadius: 1)]
              : [],
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!isSmallScreen) ...[
                Icon(typeIcon, size: 14, color: isDisabled ? Colors.grey.withOpacity(0.3) : (isLive ? Colors.white : buttonColor)),
                const SizedBox(height: 2),
              ],
              Text(
                source.shortName,
                style: TextStyle(
                  color: isDisabled ? Colors.grey.withOpacity(0.4) : Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: isSmallScreen ? 11 : 13,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                source.name,
                style: TextStyle(
                  color: isDisabled 
                    ? Colors.grey.withOpacity(0.2) 
                    : Colors.white.withOpacity(0.5),
                  fontSize: isSmallScreen ? 8 : 10,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
