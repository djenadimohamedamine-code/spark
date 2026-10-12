import 'package:flutter/material.dart';
import '../models/source.dart';

class SourceCard extends StatelessWidget {
  final Source source;
  final bool isLive;
  final VoidCallback onTap;

  const SourceCard({
    super.key,
    required this.source,
    required this.isLive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isLive ? Colors.redAccent : Colors.transparent,
            width: 3,
          ),
          boxShadow: [
            if (isLive)
              BoxShadow(
                color: Colors.redAccent.withOpacity(0.5),
                blurRadius: 15,
                spreadRadius: 2,
              ),
          ],
        ),
        child: Column(
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: const BoxDecoration(
                color: Color(0xFF2C2C2C),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(9),
                  topRight: Radius.circular(9),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    source.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  if (isLive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'ON AIR',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Body - representing a screen thumbnail
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: Colors.black,
                    child: Center(
                      child: Icon(
                        _getIconForType(source.type),
                        color: Colors.white38,
                        size: 40,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIconForType(SourceType type) {
    switch (type) {
      case SourceType.xdcam:
        return Icons.videocam;
      case SourceType.presenter:
        return Icons.person;
      case SourceType.external:
        return Icons.satellite_alt;
      case SourceType.generic:
      default:
        return Icons.movie;
    }
  }
}
