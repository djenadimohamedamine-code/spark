enum SourceType {
  server,     // For Intro/Outro
  presenter,  // Studio Camera
  xdcam,      // VTR (Clips)
  external,   // Live external feeds
}

class Source {
  final int id;
  final String name;
  final String shortName; // For the button text
  final SourceType type;
  final String assetPath;
  final bool autoReturn;  // If true, returns to presenter when video ends
  final String? lowerThirdTitle; // Title for the news lower-third graphics
  final String? lowerThirdSubtitle;

  const Source({
    required this.id,
    required this.name,
    required this.shortName,
    required this.type,
    required this.assetPath,
    this.autoReturn = true, 
    this.lowerThirdTitle,
    this.lowerThirdSubtitle,
  });
}
