import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class PresenterOverlay extends StatelessWidget {
  final VideoPlayerController? controller;
  final bool isVisible;

  const PresenterOverlay({
    super.key,
    required this.controller,
    required this.isVisible,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: isVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: isVisible && controller != null && controller!.value.isInitialized
          ? Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.greenAccent, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipOval(
                child: AspectRatio(
                  aspectRatio: controller!.value.aspectRatio,
                  child: VideoPlayer(controller!),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
